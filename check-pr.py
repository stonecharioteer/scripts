#!/usr/bin/env python3
"""Summarize PR readiness for the current branch."""

from __future__ import annotations

import argparse
import concurrent.futures
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import UTC, datetime
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.live import Live
from rich.table import Table
from rich.text import Text

console = Console()


@dataclass
class CheckRow:
    name: str
    state: str
    details: str
    runner: str = ""
    duration: str = ""
    previous_duration: str = ""


@dataclass
class ActionInfo:
    runner: str = ""
    duration: str = ""
    previous_duration: str = ""
    name: str = ""
    workflow: str = ""
    run_id: int | None = None


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


def job_duration(job: dict[str, Any]) -> str:
    started = parse_time(job.get("started_at") or job.get("startedAt"))
    if not started:
        return ""
    completed = parse_time(job.get("completed_at") or job.get("completedAt")) or datetime.now(UTC)
    return format_duration((completed - started).total_seconds())


def action_info(link: str, owner: str, repo_name: str, cwd: Path) -> ActionInfo:
    match = re.search(r"/job/(\d+)(?:\D|$)", link or "")
    if not match:
        return ActionInfo()
    job = run_json(["gh", "api", f"repos/{owner}/{repo_name}/actions/jobs/{match.group(1)}"], cwd, check=False)
    if not isinstance(job, dict):
        return ActionInfo()
    runner = str(job.get("runner_name") or "")
    labels = job.get("labels") or []
    if not runner and isinstance(labels, list) and labels:
        runner = "labels: " + ", ".join(str(label) for label in labels)
    run_id = job.get("run_id")
    return ActionInfo(
        runner=runner,
        duration=job_duration(job),
        name=str(job.get("name") or ""),
        workflow=str(job.get("workflow_name") or ""),
        run_id=int(run_id) if isinstance(run_id, int) else None,
    )


def previous_durations(infos: dict[str, ActionInfo], owner: str, repo_name: str, branch: str, cwd: Path) -> dict[tuple[str, str], str]:
    wanted = {(info.workflow, info.name) for info in infos.values() if info.workflow and info.name}
    current_runs = {info.run_id for info in infos.values() if info.run_id}
    if not wanted:
        return {}
    runs = run_json([
        "gh", "api", "--method", "GET", f"repos/{owner}/{repo_name}/actions/runs",
        "-f", f"branch={branch}", "-f", "event=pull_request", "-f", "per_page=30",
    ], cwd, check=False)
    candidates = [
        run for run in (runs or {}).get("workflow_runs", [])
        if run.get("id") not in current_runs and (run.get("name"), "") not in wanted
    ]
    candidates = [run for run in candidates if run.get("name") in {workflow for workflow, _ in wanted}]
    found: dict[tuple[str, str], str] = {}

    def run_jobs(run_id: int) -> list[dict[str, Any]]:
        data = run_json(["gh", "api", "--method", "GET", f"repos/{owner}/{repo_name}/actions/runs/{run_id}/jobs", "-f", "per_page=100"], cwd, check=False)
        return data.get("jobs", []) if isinstance(data, dict) else []

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(6, len(candidates) or 1)) as executor:
        future_to_run = {executor.submit(run_jobs, int(run["id"])): run for run in candidates[:12] if run.get("id")}
        for future in concurrent.futures.as_completed(future_to_run):
            workflow = str(future_to_run[future].get("name") or "")
            for job in future.result():
                key = (workflow, str(job.get("name") or ""))
                if key in wanted and key not in found:
                    duration = job_duration(job)
                    if duration:
                        found[key] = duration
    return found


def action_infos(links: list[str], owner: str, repo_name: str, branch: str, cwd: Path) -> dict[str, ActionInfo]:
    unique_links = sorted({link for link in links if link})
    if not unique_links:
        return {}
    max_workers = min(8, len(unique_links))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        infos = dict(zip(
            unique_links,
            executor.map(lambda link: action_info(link, owner, repo_name, cwd), unique_links),
            strict=True,
        ))
    previous = previous_durations(infos, owner, repo_name, branch, cwd)
    for info in infos.values():
        info.previous_duration = previous.get((info.workflow, info.name), "")
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
            }.get(state, "running" if state in {"PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED"} else "")
            link = item.get("link") or ""
            info = infos.get(link, ActionInfo())
            rows.append(CheckRow(item.get("name") or "unknown", state, detail or state.lower(), info.runner, info.duration, info.previous_duration))
        return rows

    rollup = pr.get("statusCheckRollup") or []
    infos = action_infos([item.get("detailsUrl") or "" for item in rollup], owner, repo_name, branch, cwd)
    for item in rollup:
        name = item.get("name") or item.get("context") or "unknown"
        state = check_effective_state(item)
        detail = "completed" if item.get("conclusion") else "running"
        link = item.get("detailsUrl") or ""
        info = infos.get(link, ActionInfo())
        rows.append(CheckRow(name, state, detail, info.runner, info.duration, info.previous_duration))
    if not rows:
        rows.append(CheckRow("(no checks reported)", "-", ""))
    return rows


def check_summary(checks: list[CheckRow]) -> tuple[str, str]:
    if not checks or checks[0].name == "(no checks reported)":
        return "NONE", "no checks reported"
    failing = sum(1 for c in checks if c.state in {"FAILURE", "FAILED", "FAILING", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED", "CANCELED"})
    pending = sum(1 for c in checks if c.state in {"PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED"})
    passing = sum(1 for c in checks if c.state in {"SUCCESS", "PASSED", "PASSING"})
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
        bot_check_running = bot_check_state in {"PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED"}
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
            if any(name.startswith(key) and state == "SUCCESS" for name, state in check_names.items()):
                details += ", check success"
        rows.append((bot, state, details))
    return rows, coderabbit_skipped


def render(args: argparse.Namespace, out: Console = console, footer: str | None = None) -> int:
    cwd = Path(args.directory or os.getcwd()).expanduser().resolve()
    if not cwd.exists():
        out.print(f"[red]Directory does not exist:[/] {cwd}")
        return 1
    for cmd in ("git", "gh"):
        if not shutil.which(cmd):
            out.print(f"[red]{cmd} is required[/]")
            return 1

    if run(["git", "rev-parse", "--is-inside-work-tree"], cwd, check=False).strip() != "true":
        out.print(f"[red]Directory is not inside a git repository:[/] {cwd}")
        return 1

    branch = run(["git", "branch", "--show-current"], cwd).strip()
    if not branch:
        out.print("[red]Could not determine current git branch[/]")
        return 1

    repo = run_json(["gh", "repo", "view", "--json", "owner,name"], cwd)
    owner = repo["owner"]["login"]
    repo_name = repo["name"]

    pr_list = run_json([
        "gh", "pr", "list", "--head", branch, "--state", "open",
        "--json", "number,title,url,headRefName,baseRefName,isDraft,reviewDecision,mergeStateStatus,mergeable,statusCheckRollup",
        "--limit", "1",
    ], cwd)
    if not pr_list:
        out.print(f"[yellow]No open PR found for {owner}/{repo_name} branch: {branch}[/]")
        return 1

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

    latest_by_user: dict[str, str] = {}
    for review in reviews:
        user = ((review.get("user") or {}).get("login")) or "unknown"
        latest_by_user[user] = review.get("state") or ""
    states = set(latest_by_user.values())
    review_decision = pr.get("reviewDecision") or "REVIEW_REQUIRED"
    if "CHANGES_REQUESTED" in states:
        effective_review = "CHANGES_REQUESTED"
    elif "APPROVED" in states:
        effective_review = "APPROVED"
    else:
        effective_review = review_decision
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
    if check_state == "FAILING":
        attention.append(("Checks", check_state, check_details + "."))
    elif check_state == "PENDING":
        attention.append(("Checks", check_state, check_details + "."))

    status_state, status_detail = merge_status_line(
        draft=draft,
        base_state=base_state,
        base=base,
        check_state=check_state,
        check_details=check_details,
        effective_review=effective_review,
    )

    out.rule(f"[bold magenta]{owner}/{repo_name} PR #{number} · {pr.get('title')}[/]", characters="─")
    out.print(f"branch  {shorten(head, 42)} → {base}")
    if not args.concise:
        out.print(f"path    {cwd}")
        out.print(f"url     {pr.get('url')}")
    out.print("status  ", styled(status_state), f" {status_detail}", sep="")

    if attention:
        needs = table("Needs attention", ["Item", "State", "Why it matters"])
        for item, state, why in attention:
            needs.add_row(item, styled(state), why)
        out.print(needs)

    visible_checks = [c for c in checks if not args.concise or c.state not in {"SUCCESS", "PASSED", "PASSING"}]
    if visible_checks:
        check_columns = ["Check", "State"]
        show_runners = any(c.runner for c in visible_checks)
        show_durations = any(c.duration or c.previous_duration for c in visible_checks)
        if show_runners:
            check_columns.append("Runner")
        if show_durations:
            check_columns.append("Time")
        checks_table = table("Checks", check_columns)
        for c in visible_checks:
            row = [c.name, styled(c.state)]
            if show_runners:
                row.append(c.runner or "-")
            if show_durations:
                duration = c.duration or "-"
                if c.previous_duration:
                    duration += f" (prev {c.previous_duration})"
                row.append(duration)
            checks_table.add_row(*row)
        out.print(checks_table)

    visible_bots = [
        b
        for b in bots
        if not args.concise
        or b[1] in {"SKIPPED", "WARNING", "BLOCKED", "RATE_LIMITED", "PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED"}
        or "review comments posted" in b[2]
    ]
    if visible_bots:
        bot_table = table("Bot activity", ["Bot", "State", "Details"])
        for bot, state, details in visible_bots:
            bot_table.add_row(bot, styled(state), details)
        out.print(bot_table)
    if footer:
        out.print(f"\n[grey62]{footer}[/]")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize PR readiness for a git repository.")
    parser.add_argument("directory", nargs="?", help="Repository directory. Defaults to current working directory.")
    parser.add_argument("-C", "--directory", dest="directory_option", help="Repository directory.")
    parser.add_argument("-w", "--watch", action="store_true", help="Refresh every 30 seconds.")
    parser.add_argument("--concise", action="store_true", help="Hide URL/path and passing checks; show only what needs attention.")
    args = parser.parse_args()
    if args.directory and args.directory_option:
        parser.error("specify only one directory")
    args.directory = args.directory_option or args.directory
    return args


def render_text(args: argparse.Namespace, footer: str | None = None) -> tuple[Text, int]:
    buffer = io.StringIO()
    capture_console = Console(
        file=buffer,
        force_terminal=True,
        color_system=console.color_system,
        width=console.width,
        legacy_windows=False,
    )
    try:
        code = render(args, capture_console, footer)
    except Exception as exc:  # noqa: BLE001 - CLI should render errors cleanly
        capture_console.print(f"[red]{friendly_error(exc)}[/]")
        code = 1
    return Text.from_ansi(buffer.getvalue()), code


def with_watch_footer(body: Text, last_updated: datetime | None, next_refresh: float, warning: str = "") -> Text:
    remaining = max(0, int(next_refresh - time.monotonic()))
    updated = last_updated.strftime("%Y-%m-%d %H:%M:%S") if last_updated else "never"
    footer = f"\nLast updated at {updated} · next update in {remaining}s"
    if warning:
        footer += f" · last refresh failed: {warning}"
    output = body.copy()
    output.append(footer, style="grey62")
    return output


def watch(args: argparse.Namespace) -> int:
    interval = 30
    last_updated: datetime | None = None
    next_refresh = time.monotonic()
    body: Text | None = None
    warning = ""
    code = 0

    with Live(console=console, refresh_per_second=4, transient=False) as live:
        try:
            while True:
                now = time.monotonic()
                if body is None or now >= next_refresh:
                    next_refresh = now + interval
                    new_body, new_code = render_text(args)
                    if new_code == 0 or body is None:
                        body = new_body
                        code = new_code
                        warning = "" if new_code == 0 else new_body.plain.strip().splitlines()[-1]
                        if new_code == 0:
                            last_updated = datetime.now()
                    else:
                        warning = new_body.plain.strip().splitlines()[-1]
                        code = new_code

                live.update(with_watch_footer(body, last_updated, next_refresh, warning))
                time.sleep(1)
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
