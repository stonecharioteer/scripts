#!/usr/bin/env python3
"""Summarize PR readiness for the current branch."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.table import Table
from rich.text import Text

console = Console()


@dataclass
class CheckRow:
    name: str
    state: str
    details: str


def run(cmd: list[str], cwd: Path, *, check: bool = True) -> str:
    result = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, check=False)
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or f"command failed: {' '.join(cmd)}"
        raise RuntimeError(message)
    return result.stdout


def run_json(cmd: list[str], cwd: Path, *, check: bool = True) -> Any:
    output = run(cmd, cwd, check=check)
    if not output.strip():
        return None
    return json.loads(output)


def style_for(value: str) -> str:
    value = (value or "-").upper()
    if value in {"READY", "SUCCESS", "PASSING", "PASSED", "CLEAN", "HAS_HOOKS", "MERGEABLE", "APPROVED"}:
        return "green"
    if value in {"DRAFT", "TRUE", "FALSE", "SKIPPED", "NEUTRAL", "-"}:
        return "grey62"
    if value in {"PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED", "BEHIND", "COMMENTED", "WARNING", "NONE"}:
        return "yellow"
    if value in {"NOT_READY", "FAILURE", "FAILED", "FAILING", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "BLOCKED", "DIRTY", "CHANGES_REQUESTED", "CANCELLED", "CANCELED"}:
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


def build_checks(pr: dict[str, Any], number: int, cwd: Path) -> list[CheckRow]:
    checks_json = run_json(["gh", "pr", "checks", str(number), "--json", "name,state,bucket"], cwd, check=False)
    rows: list[CheckRow] = []
    if isinstance(checks_json, list) and checks_json:
        for item in checks_json:
            state = check_effective_state(item)
            detail = {
                "SUCCESS": "passed",
                "FAILURE": "failed",
                "SKIPPED": "skipped",
                "CANCELLED": "cancelled",
            }.get(state, "running" if state in {"PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED"} else "")
            rows.append(CheckRow(item.get("name") or "unknown", state, detail or state.lower()))
        return rows

    for item in pr.get("statusCheckRollup") or []:
        name = item.get("name") or item.get("context") or "unknown"
        state = check_effective_state(item)
        detail = "completed" if item.get("conclusion") else "running"
        rows.append(CheckRow(name, state, detail))
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
    return state, f"{failing} failing, {pending} pending, {passing} passing"


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


def render(args: argparse.Namespace) -> int:
    cwd = Path(args.directory or os.getcwd()).expanduser().resolve()
    if not cwd.exists():
        console.print(f"[red]Directory does not exist:[/] {cwd}")
        return 1
    for cmd in ("git", "gh"):
        if not shutil.which(cmd):
            console.print(f"[red]{cmd} is required[/]")
            return 1

    if run(["git", "rev-parse", "--is-inside-work-tree"], cwd, check=False).strip() != "true":
        console.print(f"[red]Directory is not inside a git repository:[/] {cwd}")
        return 1

    branch = run(["git", "branch", "--show-current"], cwd).strip()
    if not branch:
        console.print("[red]Could not determine current git branch[/]")
        return 1

    repo = run_json(["gh", "repo", "view", "--json", "owner,name"], cwd)
    owner = repo["owner"]["login"]
    repo_name = repo["name"]

    pr_list = run_json([
        "gh", "pr", "list", "--head", branch, "--state", "open",
        "--json", "number,title,url,headRefName,baseRefName,isDraft,reviewDecision,mergeStateStatus,statusCheckRollup",
        "--limit", "1",
    ], cwd)
    if not pr_list:
        console.print(f"[yellow]No open PR found for {owner}/{repo_name} branch: {branch}[/]")
        return 1

    pr = pr_list[0]
    number = int(pr["number"])
    comments = run_json(["gh", "api", f"repos/{owner}/{repo_name}/issues/{number}/comments"], cwd) or []
    reviews = run_json(["gh", "api", f"repos/{owner}/{repo_name}/pulls/{number}/reviews"], cwd) or []
    checks = build_checks(pr, number, cwd)
    bots, coderabbit_skipped = bot_activity(comments, checks)
    if coderabbit_skipped:
        for check in checks:
            if check.name.lower() == "coderabbit":
                check.state = "SKIPPED"
                check.details = "review skipped"

    check_state, check_details = check_summary(checks)
    draft = bool(pr.get("isDraft"))
    merge = pr.get("mergeStateStatus") or "UNKNOWN"
    base = pr.get("baseRefName") or "base"
    head = pr.get("headRefName") or branch

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
    commented_count = sum(1 for review in reviews if review.get("state") == "COMMENTED")

    attention: list[tuple[str, str, str]] = []
    if draft:
        attention.append(("Draft", "DRAFT", "Mark ready for review; draft PRs can suppress actions/checks."))
    if merge not in {"CLEAN", "HAS_HOOKS"}:
        attention.append(("Base branch", merge, f"Update branch with {base} before merging."))
    if effective_review == "CHANGES_REQUESTED":
        attention.append(("Review", effective_review, "Resolve requested changes."))
    if check_state == "FAILING":
        attention.append(("Checks", check_state, check_details + "."))
    elif check_state == "PENDING":
        attention.append(("Checks", check_state, check_details + "."))

    if attention:
        ready_state = "NOT_READY" if any(s not in {"PENDING"} for _, s, _ in attention) else "WAITING"
        ready_detail = f"{len([a for a in attention if a[1] != 'PENDING']) or len(attention)} blocker(s)" if ready_state == "NOT_READY" else f"{len(attention)} pending item(s)"
    else:
        ready_state = "READY"
        ready_detail = "no blockers detected"

    console.rule(f"[bold magenta]{owner}/{repo_name} PR #{number} · {pr.get('title')}[/]", characters="─")
    console.print(f"branch  {shorten(head, 42)} → {base}")
    if not args.concise:
        console.print(f"path    {cwd}")
        console.print(f"url     {pr.get('url')}")

    if args.concise:
        console.print("ready   ", styled(ready_state), f" {ready_detail}", sep="")
    else:
        summary = table(None, ["Area", "State", "Details"])
        summary.add_row("Ready", styled(ready_state), ready_detail)
        summary.add_row("Draft", styled(str(draft).lower()), "actions may be disabled" if draft else "-")
        summary.add_row("Base", styled(merge), f"update from {base}")
        summary.add_row("Checks", styled(check_state), check_details)
        review_details = f"{commented_count} non-blocking comment review(s)" if commented_count else "-"
        summary.add_row("Reviews", styled(effective_review), review_details)
        console.print(summary)

    if attention:
        needs = table("Needs attention", ["Item", "State", "Why it matters"])
        for item, state, why in attention:
            needs.add_row(item, styled(state), why)
        console.print(needs)

    visible_checks = [c for c in checks if not args.concise or c.state not in {"SUCCESS", "PASSED", "PASSING"}]
    if visible_checks:
        checks_table = table("Checks", ["Check", "State", "Details"])
        for c in visible_checks:
            checks_table.add_row(c.name, styled(c.state), c.details)
        console.print(checks_table)

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
        console.print(bot_table)
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


def main() -> int:
    args = parse_args()
    try:
        while True:
            try:
                code = render(args)
            except Exception as exc:  # noqa: BLE001 - CLI should render errors cleanly
                console.print(f"[red]{exc}[/]")
                code = 1
            if not args.watch:
                return code
            time.sleep(30)
            console.clear()
    except KeyboardInterrupt:
        console.print("\n[grey62]Interrupted.[/]")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
