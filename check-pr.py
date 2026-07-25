#!/usr/bin/env python3
"""Summarize PR readiness for the current branch."""

from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import io
import json
import os
import re
import select
import shutil
import subprocess
import sys
import termios
import time
import tty
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.live import Live
from rich.table import Table
from rich.text import Text

console = Console()

FAILING_STATES = {
    "FAILURE",
    "FAILED",
    "FAILING",
    "ERROR",
    "TIMED_OUT",
    "ACTION_REQUIRED",
    "CANCELLED",
    "CANCELED",
}
PENDING_STATES = {"PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED"}
PASSING_STATES = {"SUCCESS", "PASSED", "PASSING"}
QUIET_STATES = {"SKIPPED", "NEUTRAL"}

# Check links look like .../actions/runs/<run_id>/job/<job_id>, which lets us
# fetch every job of a run in one API call instead of one call per job.
RUN_JOB_LINK_RE = re.compile(r"/actions/runs/(\d+)/job/(\d+)")
JOB_LINK_RE = re.compile(r"/job/(\d+)(?:\D|$)")


class CheckPRError(RuntimeError):
    """A problem worth reporting to the user without a traceback."""

    style = "red"


class NoPullRequest(CheckPRError):
    style = "yellow"


@dataclass
class CheckRow:
    name: str
    state: str
    details: str
    runner: str = ""
    duration: str = ""
    previous_duration: str = ""
    previous_state: str = ""
    seconds: float | None = None
    previous_seconds: float | None = None


@dataclass
class ActionInfo:
    runner: str = ""
    duration: str = ""
    previous_duration: str = ""
    previous_state: str = ""
    name: str = ""
    workflow: str = ""
    run_id: int | None = None
    seconds: float | None = None
    previous_seconds: float | None = None


@dataclass
class PRState:
    """Everything needed to render, so rendering never re-hits the network."""

    owner: str
    repo_name: str
    number: int
    title: str
    url: str
    head: str
    base: str
    path: Path
    draft: bool
    status_state: str
    status_detail: str
    checks: list[CheckRow] = field(default_factory=list)
    bots: list[tuple[str, str, str]] = field(default_factory=list)
    attention: list[tuple[str, str, str]] = field(default_factory=list)


def run(cmd: list[str], cwd: Path, *, check: bool = True) -> str:
    result = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, check=False)
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or f"command failed: {' '.join(cmd)}"
        raise RuntimeError(message)
    return result.stdout


def friendly_error(exc: Exception) -> str:
    message = str(exc).strip()
    lower = message.lower()
    if "error connecting to api.github.com" in lower or "check your internet connection" in lower:
        return "GitHub API is unavailable or unreachable; keeping the last successful watch result if available."
    if "http 5" in lower or "githubstatus.com" in lower:
        return "GitHub appears to be having problems; try again shortly."
    if "rate limit" in lower:
        return "GitHub API rate limit reached; try again later."
    if "gh auth login" in lower or "authentication token" in lower or "http 401" in lower:
        return "Not authenticated with GitHub; run 'gh auth login'."
    return message


def run_json(cmd: list[str], cwd: Path, *, check: bool = True) -> Any:
    output = run(cmd, cwd, check=check)
    if not output.strip():
        return None
    return json.loads(output)


def style_for(value: str) -> str:
    value = (value or "-").upper()
    if value in {"READY", "MERGEABLE", "SUCCESS", "PASSING", "PASSED", "CLEAN", "CURRENT", "HAS_HOOKS", "APPROVED"}:
        return "green"
    if value in {"TRUE", "FALSE", "SKIPPED", "NEUTRAL", "-"}:
        return "grey62"
    if value in {"DRAFT", "PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED", "BEHIND", "COMMENTED", "WARNING", "NONE"}:
        return "yellow"
    if value in {"NOT_READY", "NOT_MERGEABLE", "FAILURE", "FAILED", "FAILING", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "BLOCKED", "DIRTY", "CONFLICTS", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "CANCELLED", "CANCELED"}:
        return "red"
    return "white"


def styled(value: str) -> Text:
    return Text(value or "-", style=style_for(value))


def shorten(value: str, max_len: int) -> str:
    return value if len(value) <= max_len else value[: max_len - 1] + "…"


def table(title: str | None, columns: list[str]) -> Table:
    t = Table(title=title, show_lines=False, expand=False)
    for col in columns:
        t.add_column(col, overflow="fold")
    return t


def check_effective_state(raw: dict[str, Any]) -> str:
    bucket = str(raw.get("bucket") or "").lower()
    state = str(raw.get("state") or raw.get("conclusion") or "-").upper()
    if bucket == "pass":
        return "SUCCESS"
    if bucket == "fail":
        return "FAILURE"
    if bucket == "pending":
        return state if state not in {"", "-"} else "PENDING"
    if bucket == "skipping":
        return "SKIPPED"
    if bucket == "cancel":
        return "CANCELLED"
    conclusion = str(raw.get("conclusion") or "").upper()
    status = str(raw.get("status") or "").upper()
    rollup_state = str(raw.get("state") or "").upper()
    return conclusion or rollup_state or status or "-"


def check_sort_key(row: CheckRow) -> tuple[int, str]:
    """Blockers first, then anything running, then quiet/passing results.

    Within one state the order is alphabetical so a check keeps its position
    between refreshes instead of shuffling with whatever order gh returned.
    """
    state = (row.state or "").upper()
    if state in FAILING_STATES:
        rank = 0
    elif state in PENDING_STATES:
        rank = 1
    elif state in PASSING_STATES:
        rank = 4
    elif state in QUIET_STATES:
        rank = 3
    else:
        rank = 2
    return rank, row.name.casefold()


TREND_STYLES = {
    "regressed": "bold red",
    "still": "red",
    "fixed": "bold green",
    "running": "bold yellow",
    "slower": "yellow",
    "faster": "green",
}

# A check has to be both proportionally and absolutely slower before it is worth
# mentioning, otherwise short jobs flap between "slower" and "faster" on noise.
SLOWER_RATIO = 1.5
FASTER_RATIO = 0.67
DURATION_NOISE_SECONDS = 20
OVERRUN_RATIO = 1.25
OVERRUN_NOISE_SECONDS = 15

# Cooldown between manual refreshes in watch mode, so holding 'r' cannot turn
# into a burst of GitHub API calls
MIN_MANUAL_REFRESH_SECONDS = 3.0


def check_trend(row: CheckRow) -> str:
    """How this check compares with the previous run of the same job.

    A verdict change outranks a timing change: 'regressed' is the one worth
    interrupting someone for, since it passed last time and fails now. When the
    verdict is unchanged, report a materially different runtime instead.
    """
    state = (row.state or "").upper()
    previous = (row.previous_state or "").upper()
    if not previous:
        return ""

    now_failing = state in FAILING_STATES
    now_passing = state in PASSING_STATES
    was_failing = previous in FAILING_STATES
    was_passing = previous in PASSING_STATES
    if now_failing and was_passing:
        return "regressed"
    if now_failing and was_failing:
        return "still failing"
    if now_passing and was_failing:
        return "fixed"

    current, before = row.seconds, row.previous_seconds
    if current is None or before is None or before <= 0:
        return ""
    ratio = current / before

    # Still running past its usual time: often a hang rather than slow work
    if state in PENDING_STATES:
        if ratio >= OVERRUN_RATIO and current - before >= OVERRUN_NOISE_SECONDS:
            return f"running long {ratio:.1f}×"
        return ""

    if not now_passing:
        return ""
    if ratio >= SLOWER_RATIO and current - before >= DURATION_NOISE_SECONDS:
        return f"slower {ratio:.1f}×"
    if ratio <= FASTER_RATIO and before - current >= DURATION_NOISE_SECONDS:
        return f"faster {ratio:.1f}×"
    return ""


def name_list(names: list[str], limit: int = 3) -> str:
    listed = ", ".join(names[:limit])
    if len(names) > limit:
        listed += f" and {len(names) - limit} more"
    return listed


def previous_cell(row: CheckRow) -> Text:
    """Previous run's verdict, with its duration alongside for comparison."""
    if not row.previous_state:
        return Text("-", style="grey62")
    cell = styled(row.previous_state)
    if row.previous_duration:
        cell.append(f" {row.previous_duration}", style="grey62")
    return cell


def parse_time(value: str | None) -> datetime | None:
    if not value or value.startswith("0001-"):
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def format_duration(seconds: float) -> str:
    seconds = max(0, int(seconds))
    minutes, secs = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h{minutes:02d}m"
    if minutes:
        return f"{minutes}m{secs:02d}s"
    return f"{secs}s"


def job_elapsed(job: dict[str, Any]) -> float | None:
    """Seconds the job has taken, counting to now while it is still running."""
    started = parse_time(job.get("started_at") or job.get("startedAt"))
    if not started:
        return None
    completed = parse_time(job.get("completed_at") or job.get("completedAt")) or datetime.now(UTC)
    return max(0.0, (completed - started).total_seconds())


def job_duration(job: dict[str, Any]) -> str:
    seconds = job_elapsed(job)
    return "" if seconds is None else format_duration(seconds)


def job_to_info(job: dict[str, Any]) -> ActionInfo:
    runner = str(job.get("runner_name") or "")
    labels = job.get("labels") or []
    if not runner and isinstance(labels, list) and labels:
        runner = "labels: " + ", ".join(str(label) for label in labels)
    run_id = job.get("run_id")
    return ActionInfo(
        runner=runner,
        duration=job_duration(job),
        seconds=job_elapsed(job),
        name=str(job.get("name") or ""),
        workflow=str(job.get("workflow_name") or ""),
        run_id=int(run_id) if isinstance(run_id, int) else None,
    )


def run_jobs(owner: str, repo_name: str, run_id: int, cwd: Path) -> list[dict[str, Any]]:
    data = run_json(
        [
            "gh", "api", "--method", "GET",
            f"repos/{owner}/{repo_name}/actions/runs/{run_id}/jobs",
            "-f", "per_page=100",
        ],
        cwd,
        check=False,
    )
    return data.get("jobs", []) if isinstance(data, dict) else []


def action_info(link: str, owner: str, repo_name: str, cwd: Path) -> ActionInfo:
    """Single-job lookup, used only for links without a run id."""
    match = JOB_LINK_RE.search(link or "")
    if not match:
        return ActionInfo()
    job = run_json(["gh", "api", f"repos/{owner}/{repo_name}/actions/jobs/{match.group(1)}"], cwd, check=False)
    if not isinstance(job, dict):
        return ActionInfo()
    return job_to_info(job)


def branch_runs(owner: str, repo_name: str, branch: str, cwd: Path) -> Any:
    """Recent PR workflow runs for a branch. Independent of the job listings, so
    callers fetch it concurrently with them."""
    return run_json([
        "gh", "api", "--method", "GET", f"repos/{owner}/{repo_name}/actions/runs",
        "-f", f"branch={branch}", "-f", "event=pull_request", "-f", "per_page=30",
    ], cwd, check=False)


def previous_results(infos: dict[str, ActionInfo], runs: Any, owner: str, repo_name: str, cwd: Path) -> dict[tuple[str, str], tuple[str, str, float | None]]:
    """How each job ended, and how long it took, in the previous run.

    Returns {(workflow, job): (conclusion, duration, seconds)}. Runs that were cancelled
    (typically superseded by a newer push) are skipped: their jobs stop at an
    arbitrary point, so they say nothing about whether a check used to pass.
    """
    wanted = {(info.workflow, info.name) for info in infos.values() if info.workflow and info.name}
    if not wanted:
        return {}
    current_runs = {info.run_id for info in infos.values() if info.run_id}
    workflows = {workflow for workflow, _ in wanted}

    # The API returns newest first, so the first match per workflow wins. One
    # job listing per workflow beats one per candidate run.
    newest: dict[str, int] = {}
    for workflow_run in (runs or {}).get("workflow_runs", []):
        name = str(workflow_run.get("name") or "")
        run_id = workflow_run.get("id")
        if name not in workflows or name in newest:
            continue
        if run_id in current_runs or not isinstance(run_id, int):
            continue
        if str(workflow_run.get("status") or "") != "completed":
            continue
        if str(workflow_run.get("conclusion") or "") not in {"success", "failure"}:
            continue
        newest[name] = run_id

    if not newest:
        return {}

    found: dict[tuple[str, str], tuple[str, str, float | None]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(6, len(newest))) as executor:
        results = executor.map(
            lambda item: (item[0], run_jobs(owner, repo_name, item[1], cwd)),
            newest.items(),
        )
        for workflow, jobs in results:
            for job in jobs:
                key = (workflow, str(job.get("name") or ""))
                if key not in wanted or key in found:
                    continue
                conclusion = str(job.get("conclusion") or "").upper()
                if not job.get("completed_at") or not conclusion:
                    continue
                # Only a job that ran to a verdict has a comparable duration
                comparable = conclusion in {"SUCCESS", "FAILURE", "TIMED_OUT"}
                duration = job_duration(job) if comparable else ""
                seconds = job_elapsed(job) if comparable else None
                found[key] = (conclusion, duration, seconds)
    return found


def action_infos(links: list[str], owner: str, repo_name: str, branch: str, cwd: Path) -> dict[str, ActionInfo]:
    unique_links = sorted({link for link in links if link})
    if not unique_links:
        return {}

    # Group by workflow run so each run costs one API call, no matter how many
    # of its jobs appear as checks on the PR.
    by_run: dict[int, list[str]] = {}
    loose_links: list[str] = []
    for link in unique_links:
        match = RUN_JOB_LINK_RE.search(link)
        if match:
            by_run.setdefault(int(match.group(1)), []).append(link)
        else:
            loose_links.append(link)

    infos: dict[str, ActionInfo] = {}
    runs: Any = None

    if by_run:
        # The branch's run history does not depend on the job listings, so it
        # rides along instead of costing an extra round trip afterwards
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(by_run) + 1)) as executor:
            runs_future = executor.submit(branch_runs, owner, repo_name, branch, cwd)
            fetched = list(executor.map(
                lambda run_id: (run_id, run_jobs(owner, repo_name, run_id, cwd)),
                list(by_run),
            ))
            runs = runs_future.result()

        for run_id, jobs in fetched:
            index = {int(job["id"]): job for job in jobs if isinstance(job.get("id"), int)}
            for link in by_run[run_id]:
                match = RUN_JOB_LINK_RE.search(link)
                job = index.get(int(match.group(2))) if match else None
                if job:
                    infos[link] = job_to_info(job)

    if loose_links:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(loose_links))) as executor:
            for link, info in zip(
                loose_links,
                executor.map(lambda link: action_info(link, owner, repo_name, cwd), loose_links),
                strict=True,
            ):
                infos[link] = info

    if runs is None:
        runs = branch_runs(owner, repo_name, branch, cwd)
    previous = previous_results(infos, runs, owner, repo_name, cwd)
    for info in infos.values():
        info.previous_state, info.previous_duration, info.previous_seconds = previous.get(
            (info.workflow, info.name), ("", "", None)
        )
    return infos


def build_checks(pr: dict[str, Any], number: int, owner: str, repo_name: str, branch: str, cwd: Path) -> list[CheckRow]:
    checks_json = run_json(["gh", "pr", "checks", str(number), "--json", "name,state,bucket,link"], cwd, check=False)
    rows: list[CheckRow] = []
    if isinstance(checks_json, list) and checks_json:
        infos = action_infos([item.get("link") or "" for item in checks_json], owner, repo_name, branch, cwd)
        for item in checks_json:
            state = check_effective_state(item)
            detail = {
                "SUCCESS": "passed",
                "FAILURE": "failed",
                "SKIPPED": "skipped",
                "CANCELLED": "cancelled",
            }.get(state, "running" if state in PENDING_STATES else "")
            link = item.get("link") or ""
            info = infos.get(link, ActionInfo())
            rows.append(CheckRow(
                name=item.get("name") or "unknown",
                state=state,
                details=detail or state.lower(),
                runner=info.runner,
                duration=info.duration,
                previous_duration=info.previous_duration,
                previous_state=info.previous_state,
                seconds=info.seconds,
                previous_seconds=info.previous_seconds,
            ))
        return rows

    rollup = pr.get("statusCheckRollup") or []
    infos = action_infos([item.get("detailsUrl") or "" for item in rollup], owner, repo_name, branch, cwd)
    for item in rollup:
        name = item.get("name") or item.get("context") or "unknown"
        state = check_effective_state(item)
        detail = "completed" if item.get("conclusion") else "running"
        link = item.get("detailsUrl") or ""
        info = infos.get(link, ActionInfo())
        rows.append(CheckRow(
            name=name,
            state=state,
            details=detail,
            runner=info.runner,
            duration=info.duration,
            previous_duration=info.previous_duration,
            previous_state=info.previous_state,
            seconds=info.seconds,
            previous_seconds=info.previous_seconds,
        ))
    if not rows:
        rows.append(CheckRow("(no checks reported)", "-", ""))
    return rows


def check_summary(checks: list[CheckRow]) -> tuple[str, str]:
    if not checks or checks[0].name == "(no checks reported)":
        return "NONE", "no checks reported"
    failing = sum(1 for c in checks if c.state in FAILING_STATES)
    pending = sum(1 for c in checks if c.state in PENDING_STATES)
    if failing:
        state = "FAILING"
    elif pending:
        state = "PENDING"
    else:
        state = "PASSING"
    return state, f"{failing} fail, {pending} pending"


def merge_status_line(
    *,
    draft: bool,
    base_state: str,
    base: str,
    check_state: str,
    check_details: str,
    effective_review: str,
) -> tuple[str, str]:
    blockers: list[str] = []
    pending: list[str] = []

    if base_state == "CONFLICTS":
        blockers.append(f"conflicts with {base}")
    elif base_state == "BEHIND":
        blockers.append(f"branch behind {base}")

    if effective_review == "CHANGES_REQUESTED":
        blockers.append("changes requested")
    elif effective_review == "REVIEW_REQUIRED":
        blockers.append("review required")

    if check_state == "FAILING":
        blockers.append(f"checks failing ({check_details})")
    elif check_state == "PENDING":
        pending.append(f"checks running ({check_details})")

    details = "; ".join(blockers + pending)
    if draft:
        return "DRAFT", details or "mark ready for review before merging"
    if blockers:
        return "NOT_MERGEABLE", details
    if pending:
        return "WAITING", details
    return "MERGEABLE", "all detected blockers are clear"


def bot_activity(comments: list[dict[str, Any]], checks: list[CheckRow]) -> tuple[list[tuple[str, str, str]], bool]:
    by_bot: dict[str, list[dict[str, Any]]] = {}
    for comment in comments:
        user = comment.get("user") or {}
        if user.get("type") != "Bot":
            continue
        name = str(user.get("login") or "bot").removesuffix("[bot]")
        by_bot.setdefault(name, []).append(comment)

    rows: list[tuple[str, str, str]] = []
    coderabbit_skipped = False
    check_names = {c.name.lower(): c.state for c in checks}
    for bot, bot_comments in sorted(by_bot.items()):
        bot_comments.sort(key=lambda c: c.get("updated_at") or c.get("created_at") or "")
        bodies = [c.get("body") or "" for c in bot_comments]
        latest = (bodies[-1] if bodies else "").lower()
        joined = "\n".join(bodies).lower()
        key = bot.lower().removesuffix("ai")
        bot_check_state = next((state for name, state in check_names.items() if name.startswith(key)), "")
        bot_check_running = bot_check_state in PENDING_STATES
        latest_is_skip = "review skipped" in latest or "skip review" in latest
        latest_is_review = any(marker in latest for marker in ("review_stack_entry_start", "walkthrough", "out of diff", "review details", "summary by coderabbit"))
        skipped = latest_is_skip and not latest_is_review and not bot_check_running
        draft_skipped = skipped and "draft detected" in latest
        warning = "[!warning]" in joined or "[!caution]" in joined
        if bot_check_running:
            state = bot_check_state
            if latest_is_review:
                details = f"new review running; {len(bodies)} previous issue comment(s) may be stale"
            else:
                details = f"{len(bodies)} issue comment(s), review running"
        elif skipped:
            state = "SKIPPED"
            details = f"{len(bodies)} issue comment(s), review skipped"
            if draft_skipped:
                details += ": draft"
            if bot == "coderabbitai":
                coderabbit_skipped = True
        elif latest_is_review:
            state = "COMMENTED"
            details = f"{len(bodies)} issue comment(s), review comments posted"
        elif warning:
            state = "WARNING"
            details = f"{len(bodies)} issue comment(s), warning/caution"
        else:
            state = "COMMENTED"
            details = f"{len(bodies)} issue comment(s)"
            if any(name.startswith(key) and check_state in PASSING_STATES for name, check_state in check_names.items()):
                details += ", check success"
        rows.append((bot, state, details))
    return rows, coderabbit_skipped


def effective_review_state(reviews: list[dict[str, Any]], review_decision: str) -> str:
    """Latest decisive review per user; COMMENTED never overrides an approval."""
    latest_by_user: dict[str, str] = {}
    for review in reviews:
        state = str(review.get("state") or "").upper()
        if state not in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
            continue
        user = ((review.get("user") or {}).get("login")) or "unknown"
        if state == "DISMISSED":
            latest_by_user.pop(user, None)
            continue
        latest_by_user[user] = state

    states = set(latest_by_user.values())
    if "CHANGES_REQUESTED" in states:
        return "CHANGES_REQUESTED"
    if "APPROVED" in states:
        return "APPROVED"
    return review_decision


def collect_state(args: argparse.Namespace) -> PRState:
    """Gather everything from git/gh. Raises CheckPRError for user problems."""
    cwd = Path(args.directory or os.getcwd()).expanduser().resolve()
    if not cwd.exists():
        raise CheckPRError(f"Directory does not exist: {cwd}")
    for cmd in ("git", "gh"):
        if not shutil.which(cmd):
            raise CheckPRError(f"{cmd} is required")

    if run(["git", "rev-parse", "--is-inside-work-tree"], cwd, check=False).strip() != "true":
        raise CheckPRError(f"Directory is not inside a git repository: {cwd}")

    branch = run(["git", "branch", "--show-current"], cwd).strip()
    if not branch:
        raise CheckPRError("Could not determine current git branch")

    # The repo lookup and the PR lookup are independent, so overlap them
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        repo_future = executor.submit(run_json, ["gh", "repo", "view", "--json", "owner,name"], cwd)
        pr_future = executor.submit(run_json, [
            "gh", "pr", "list", "--head", branch, "--state", "open",
            "--json", "number,title,url,headRefName,baseRefName,isDraft,reviewDecision,mergeStateStatus,mergeable,statusCheckRollup",
            "--limit", "1",
        ], cwd)
        repo = repo_future.result()
        pr_list = pr_future.result()

    if not isinstance(repo, dict) or not repo.get("owner"):
        raise CheckPRError("Could not determine the GitHub repository for this directory")
    owner = repo["owner"]["login"]
    repo_name = repo["name"]

    if not pr_list:
        raise NoPullRequest(f"No open PR found for {owner}/{repo_name} branch: {branch}")

    pr = pr_list[0]
    number = int(pr["number"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        comments_future = executor.submit(run_json, ["gh", "api", f"repos/{owner}/{repo_name}/issues/{number}/comments"], cwd)
        reviews_future = executor.submit(run_json, ["gh", "api", f"repos/{owner}/{repo_name}/pulls/{number}/reviews"], cwd)
        checks_future = executor.submit(build_checks, pr, number, owner, repo_name, branch, cwd)
        comments = comments_future.result() or []
        reviews = reviews_future.result() or []
        checks = checks_future.result()

    bots, coderabbit_skipped = bot_activity(comments, checks)
    if coderabbit_skipped:
        for check in checks:
            if check.name.lower() == "coderabbit":
                check.state = "SKIPPED"
                check.details = "review skipped"

    checks.sort(key=check_sort_key)

    check_state, check_details = check_summary(checks)
    draft = bool(pr.get("isDraft"))
    merge = pr.get("mergeStateStatus") or "UNKNOWN"
    mergeable = pr.get("mergeable") or "UNKNOWN"
    base = pr.get("baseRefName") or "base"
    head = pr.get("headRefName") or branch

    if merge == "BEHIND":
        base_state = "BEHIND"
    elif merge == "DIRTY" or mergeable == "CONFLICTING":
        base_state = "CONFLICTS"
    elif merge in {"CLEAN", "HAS_HOOKS"}:
        base_state = "CURRENT"
    elif merge == "BLOCKED" and mergeable == "MERGEABLE":
        base_state = "CURRENT"
    else:
        base_state = merge

    effective_review = effective_review_state(reviews, pr.get("reviewDecision") or "REVIEW_REQUIRED")

    attention: list[tuple[str, str, str]] = []
    if draft:
        attention.append(("Draft", "DRAFT", "Mark ready for review; draft PRs can suppress actions/checks."))
    if base_state == "BEHIND":
        attention.append(("Base branch", base_state, f"Update branch with {base} before merging."))
    elif base_state == "CONFLICTS":
        attention.append(("Base branch", base_state, f"Resolve conflicts with {base} before merging."))
    if effective_review == "CHANGES_REQUESTED":
        attention.append(("Review", effective_review, "Resolve requested changes."))
    elif effective_review == "REVIEW_REQUIRED":
        attention.append(("Review", effective_review, "Get an approving review."))
    if check_state in {"FAILING", "PENDING"}:
        attention.append(("Checks", check_state, check_details + "."))

    # A check that passed last run and fails now points at the latest push
    regressed = [c.name for c in checks if check_trend(c) == "regressed"]
    if regressed:
        attention.append(("Regressions", "FAILURE", f"{name_list(regressed)}: passed in the previous run."))

    overrunning = [c.name for c in checks if check_trend(c).startswith("running long")]
    if overrunning:
        attention.append(("Slow checks", "PENDING", f"{name_list(overrunning)}: running longer than the previous run."))

    status_state, status_detail = merge_status_line(
        draft=draft,
        base_state=base_state,
        base=base,
        check_state=check_state,
        check_details=check_details,
        effective_review=effective_review,
    )

    return PRState(
        owner=owner,
        repo_name=repo_name,
        number=number,
        title=str(pr.get("title") or ""),
        url=str(pr.get("url") or ""),
        head=head,
        base=base,
        path=cwd,
        draft=draft,
        status_state=status_state,
        status_detail=status_detail,
        checks=checks,
        bots=bots,
        attention=attention,
    )


def render_state(state: PRState, out: Console, *, concise: bool, footer: str | None = None) -> None:
    out.rule(f"[bold magenta]{state.owner}/{state.repo_name} PR #{state.number} · {state.title}[/]", characters="─")
    out.print(f"branch  {shorten(state.head, 42)} → {state.base}")
    if not concise:
        out.print(f"path    {state.path}")
        out.print(f"url     {state.url}")
    out.print("status  ", styled(state.status_state), f" {state.status_detail}", sep="")

    if state.attention:
        needs = table("Needs attention", ["Item", "State", "Why it matters"])
        for item, item_state, why in state.attention:
            needs.add_row(item, styled(item_state), why)
        out.print(needs)

    visible_checks = [c for c in state.checks if not concise or c.state not in PASSING_STATES]
    if visible_checks:
        check_columns = ["Check", "State"]
        show_runners = any(c.runner for c in visible_checks)
        show_durations = any(c.duration for c in visible_checks)
        show_previous = any(c.previous_state for c in visible_checks)
        show_trend = any(check_trend(c) for c in visible_checks)
        if show_trend:
            check_columns.append("Trend")
        if show_runners:
            check_columns.append("Runner")
        if show_durations:
            check_columns.append("Time")
        if show_previous:
            check_columns.append("Previous")
        checks_table = table("Checks", check_columns)
        for c in visible_checks:
            row: list[str | Text] = [c.name, styled(c.state)]
            if show_trend:
                trend = check_trend(c)
                # Trends carry a ratio suffix ("slower 2.1×"), so key on the verb
                row.append(Text(trend, style=TREND_STYLES.get(trend.split(" ")[0], "grey62")))
            if show_runners:
                row.append(c.runner or "-")
            if show_durations:
                row.append(c.duration or "-")
            if show_previous:
                row.append(previous_cell(c))
            checks_table.add_row(*row)
        out.print(checks_table)

    visible_bots = [
        b
        for b in state.bots
        if not concise
        or b[1] in {"SKIPPED", "WARNING", "BLOCKED", "RATE_LIMITED", *PENDING_STATES}
        or "review comments posted" in b[2]
    ]
    if visible_bots:
        bot_table = table("Bot activity", ["Bot", "State", "Details"])
        for bot, bot_state, details in visible_bots:
            bot_table.add_row(bot, styled(bot_state), details)
        out.print(bot_table)
    if footer:
        out.print(f"\n[grey62]{footer}[/]")


def render(args: argparse.Namespace, out: Console = console, footer: str | None = None) -> int:
    try:
        state = collect_state(args)
    except CheckPRError as exc:
        out.print(f"[{exc.style}]{exc}[/]")
        return 1
    render_state(state, out, concise=args.concise, footer=footer)
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize PR readiness for a git repository.")
    parser.add_argument("directory", nargs="?", help="Repository directory. Defaults to current working directory.")
    parser.add_argument("-C", "--directory", dest="directory_option", help="Repository directory.")
    parser.add_argument("-w", "--watch", action="store_true", help="Refresh on an interval; press 'r' to refresh now, 'q' to quit.")
    parser.add_argument("-i", "--interval", type=int, default=30, metavar="SECONDS", help="Watch refresh interval in seconds (default: 30).")
    parser.add_argument("--concise", action="store_true", help="Hide URL/path and passing checks; show only what needs attention.")
    args = parser.parse_args()
    if args.directory and args.directory_option:
        parser.error("specify only one directory")
    if args.interval < 5:
        parser.error("--interval must be at least 5 seconds")
    args.directory = args.directory_option or args.directory
    return args


def capture(width: int, render_fn) -> Text:
    """Render into a Text so watch mode can measure and trim the output."""
    buffer = io.StringIO()
    capture_console = Console(
        file=buffer,
        force_terminal=True,
        color_system=console.color_system,
        width=width,
        legacy_windows=False,
    )
    render_fn(capture_console)
    return Text.from_ansi(buffer.getvalue().rstrip("\n"))


def fit_to_height(body: Text, max_lines: int) -> Text:
    """Trim from the bottom, leaving a marker, so the footer stays visible."""
    if max_lines <= 1:
        return body
    lines = body.split("\n")
    if len(lines) <= max_lines:
        return body
    hidden = len(lines) - (max_lines - 1)
    trimmed = Text("\n").join(lines[: max_lines - 1])
    trimmed.append(f"\n… {hidden} more line(s) hidden; use --concise or a taller terminal", style="grey62")
    return trimmed


def watch_body(state: PRState | None, message: str | None, *, concise: bool, width: int, height: int) -> Text:
    """Render state to fit the terminal, dropping detail before truncating."""
    if state is None:
        return Text.from_ansi(message or "Waiting for data...")

    body = capture(width, lambda out: render_state(state, out, concise=concise))
    if len(body.split("\n")) <= height and not message:
        return body

    # Too tall: try the compact view before resorting to hard truncation
    if not concise:
        compact = capture(width, lambda out: render_state(state, out, concise=True))
        if len(compact.split("\n")) <= height:
            return compact
        body = compact
    return fit_to_height(body, height)


@contextlib.contextmanager
def key_reader():
    """Read single keypresses without waiting for Enter.

    Yields a file descriptor to poll, or None when stdin is not a terminal (a
    pipe or cron), in which case watch mode simply has no keybindings.
    """
    if not sys.stdin.isatty():
        yield None
        return
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    try:
        # cbreak rather than raw: Ctrl-C still raises KeyboardInterrupt
        tty.setcbreak(fd)
        yield fd
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def wait_for_key(fd: int | None, timeout: float) -> str:
    """Wait up to timeout seconds for a keypress, returning it (or "")."""
    if fd is None:
        time.sleep(timeout)
        return ""
    if not select.select([fd], [], [], timeout)[0]:
        return ""
    return os.read(fd, 1).decode(errors="ignore")


def drain_input(fd: int | None) -> bool:
    """Discard keys typed while a refresh was running.

    Keys pressed during a fetch are almost always someone impatiently mashing
    'r'; replaying them would queue a fetch per keypress. Quit is the exception
    worth honouring, since a refresh can take several seconds.
    """
    if fd is None:
        return False
    buffered = ""
    while select.select([fd], [], [], 0)[0]:
        chunk = os.read(fd, 1024).decode(errors="ignore")
        if not chunk:
            break
        buffered += chunk
    return "q" in buffered.lower()


def with_watch_footer(
    body: Text,
    last_updated: datetime | None,
    next_refresh: float,
    warning: str = "",
    *,
    refreshing: bool = False,
    keys: bool = False,
    note: str = "",
) -> Text:
    updated = last_updated.strftime("%Y-%m-%d %H:%M:%S") if last_updated else "never"
    footer = f"\nLast updated at {updated}"
    if refreshing:
        footer += " · refreshing now..."
    else:
        remaining = max(0, int(next_refresh - time.monotonic()))
        footer += f" · next update in {remaining}s"
    if note:
        footer += f" · {note}"
    if warning:
        footer += f" · last refresh failed: {warning}"
    if keys:
        footer += " · [r] refresh  [q] quit"
    output = body.copy()
    output.append(footer, style="grey62")
    return output


def watch(args: argparse.Namespace) -> int:
    last_updated: datetime | None = None
    next_refresh = time.monotonic()
    state: PRState | None = None
    message: str | None = None
    warning = ""
    code = 0
    fetched = False
    last_fetch_at = 0.0
    note = ""
    note_until = 0.0

    body: Text | None = None

    with key_reader() as key_fd, Live(console=console, refresh_per_second=4, transient=False) as live:
        try:
            while True:
                now = time.monotonic()
                if not fetched or now >= next_refresh:
                    # Say so before blocking on the network, so a manual refresh
                    # gives immediate feedback instead of a frozen countdown
                    if body is not None:
                        live.update(with_watch_footer(
                            body, last_updated, next_refresh, warning,
                            refreshing=True, keys=key_fd is not None,
                        ))
                    # Push the next automatic refresh out before fetching, so a
                    # slow fetch cannot re-enter this branch
                    next_refresh = now + args.interval
                    fetched = True
                    try:
                        state = collect_state(args)
                        message = None
                        warning = ""
                        code = 0
                        last_updated = datetime.now()
                    except CheckPRError as exc:
                        # Expected condition (no PR yet, wrong directory): show
                        # it as the body rather than as a refresh failure
                        code = 1
                        if state is None:
                            message = f"[{exc.style}]{exc}[/]"
                            warning = ""
                        else:
                            warning = friendly_error(exc)
                    except Exception as exc:  # noqa: BLE001 - keep watching
                        code = 1
                        warning = friendly_error(exc)
                        if state is None:
                            message = f"[red]{warning}[/]"

                    # Time the interval from the end of the fetch, so a slow
                    # fetch does not immediately trigger the next one
                    last_fetch_at = time.monotonic()
                    next_refresh = last_fetch_at + args.interval
                    note = ""
                    if drain_input(key_fd):
                        break

                if note and time.monotonic() >= note_until:
                    note = ""

                # Re-render every tick so a resize is picked up without refetching.
                # Reserve two lines for the footer plus one for the prompt.
                width, height = console.size
                body = watch_body(
                    state,
                    message,
                    concise=args.concise,
                    width=width,
                    height=max(1, height - 3),
                )
                live.update(with_watch_footer(
                    body, last_updated, next_refresh, warning,
                    keys=key_fd is not None, note=note,
                ))

                # Sleep in one-second ticks so the countdown stays live, but wake
                # early on a keypress
                key = wait_for_key(key_fd, 1.0)
                if key in {"r", "R"}:
                    since = time.monotonic() - last_fetch_at
                    if since < MIN_MANUAL_REFRESH_SECONDS:
                        # Refusing here is what keeps a held-down 'r' from
                        # turning into a burst of API calls
                        note = f"refreshed {since:.0f}s ago, ignoring"
                        note_until = time.monotonic() + 2
                    else:
                        next_refresh = time.monotonic()
                elif key in {"q", "Q"}:
                    break
        except KeyboardInterrupt:
            console.print("\n[grey62]Interrupted.[/]")
            return 130
    return code


def main() -> int:
    args = parse_args()
    if args.watch:
        return watch(args)
    try:
        return render(args)
    except Exception as exc:  # noqa: BLE001 - CLI should render errors cleanly
        console.print(f"[red]{friendly_error(exc)}[/]")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
