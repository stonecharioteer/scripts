#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["matplotlib"]
# ///
"""Collect local and remote AI coding-agent usage into JSON and CSV.

The collector intentionally records usage metadata only. It does not copy prompts,
responses, tool arguments, auth files, or raw transcripts into the output.

Run via uv (resolves matplotlib for the infographic) or plain python3 (everything
except the infographic works; matplotlib is imported lazily). Remote hosts always
receive the script over SSH and run it with plain python3.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import datetime as dt
import html
import json
import os
import platform
import re
import shlex
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2
DEFAULT_CACHE_DIR = ".ai-usage-cache"
DEFAULT_INVENTORY = "ai-usage.hosts"
DEFAULT_JSON = "ai-usage.json"
DEFAULT_CSV = "ai-usage.csv"
DEFAULT_DAILY_JSON = "ai-usage-daily.json"
DEFAULT_DAILY_CSV = "ai-usage-daily.csv"
DEFAULT_HTML = "ai-usage.html"
DEFAULT_INFOGRAPHIC = "ai-usage-infographic.png"
DEFAULT_CCUSAGE_PACKAGE = "ccusage@latest"
D3_VERSION = "7.9.0"
D3_URL = f"https://cdn.jsdelivr.net/npm/d3@{D3_VERSION}/dist/d3.min.js"


@dataclass
class HostSpec:
    label: str
    target: str = "local"
    account_label: str = ""
    options: dict[str, str] = field(default_factory=dict)

    @property
    def is_local(self) -> bool:
        return self.target in {"", "local", "localhost", "127.0.0.1", "::1"}


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def iso_date(timestamp: str) -> str:
    if not timestamp:
        return ""
    return timestamp[:10]


def as_int(value: Any) -> int:
    if value is None or value == "":
        return 0
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0


def as_float(value: Any) -> float:
    if value is None or value == "":
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def clean_ccusage_model_name(model: str) -> str:
    return re.sub(r"^\[[^\]]+\]\s*", "", model).strip()


def infer_service(source: str, provider: str, model: str) -> str:
    normalized_model = clean_ccusage_model_name(model).lower()
    haystack = f"{source} {provider} {normalized_model}".lower()
    if "grok" in haystack or "xai" in haystack or "x.ai" in haystack:
        return "grok"
    if "claude" in haystack or "anthropic" in haystack:
        return "claude"
    if "codex" in haystack:
        return "codex"
    if "gemini" in haystack:
        return "gemini"
    if "openai" in haystack or normalized_model.startswith("gpt-") or re.match(r"o\d", normalized_model):
        return "openai"
    if "kimi" in haystack:
        return "kimi"
    if "qwen" in haystack:
        return "qwen"
    return source


def new_record(
    *,
    source: str,
    timestamp: str,
    session_id: str = "",
    project: str = "",
    account: str = "",
    provider: str = "",
    model: str = "",
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_creation_tokens: int = 0,
    cache_read_tokens: int = 0,
    reasoning_tokens: int = 0,
    total_tokens: int = 0,
    cost_usd: float = 0.0,
    source_path: str = "",
) -> dict[str, Any]:
    if not total_tokens:
        total_tokens = input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens
    service = infer_service(source, provider, model)
    return {
        "date": iso_date(timestamp),
        "timestamp": timestamp,
        "source": source,
        "service": service,
        "account": account,
        "provider": provider,
        "model": model,
        "session_id": session_id,
        "project": project,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_creation_tokens": cache_creation_tokens,
        "cache_read_tokens": cache_read_tokens,
        "reasoning_tokens": reasoning_tokens,
        "total_tokens": total_tokens,
        "cost_usd": round(cost_usd, 10),
        "source_path": source_path,
    }


def run_ccusage(
    mode: str, home: Path, extra_args: list[str] | None = None, package: str = DEFAULT_CCUSAGE_PACKAGE
) -> dict[str, Any] | None:
    extra_args = extra_args or []
    command: list[str] | None = None
    if mode in {"auto", "npx"} and shutil.which("npx"):
        command = ["npx", "--yes", package, "daily", "--json", *extra_args]
    elif mode in {"auto", "ccusage"} and shutil.which("ccusage"):
        command = ["ccusage", "daily", "--json", *extra_args]
    if command is None:
        return None

    env = os.environ.copy()
    env.setdefault("HOME", str(home))
    try:
        completed = subprocess.run(
            command,
            text=True,
            capture_output=True,
            timeout=120,
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        eprint(f"Warning: ccusage failed: {exc}")
        return None
    if completed.returncode != 0:
        stderr = completed.stderr.strip().splitlines()
        detail = stderr[-1] if stderr else f"exit {completed.returncode}"
        eprint(f"Warning: ccusage failed: {detail}")
        return None
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        eprint(f"Warning: ccusage returned invalid JSON: {exc}")
        return None
    return payload if isinstance(payload, dict) else None


def ccusage_day(day: dict[str, Any]) -> str:
    return str(day.get("date") or day.get("period") or "")


def normalize_ccusage_agent(agent: str) -> str:
    aliases = {
        "claude": "claude_code",
        "opencode": "opencode",
        "codex": "codex",
        "pi": "pi",
    }
    return aliases.get(agent, agent or "ccusage")


def collect_ccusage_unified(
    home: Path, mode: str = "auto", timezone: str = "", package: str = DEFAULT_CCUSAGE_PACKAGE
) -> list[dict[str, Any]]:
    extra_args = ["--by-agent"]
    if timezone:
        extra_args.extend(["--timezone", timezone])
    payload = run_ccusage(mode, home, extra_args, package)
    if payload is None:
        return []
    daily = payload.get("daily")
    if not isinstance(daily, list):
        return []

    records: list[dict[str, Any]] = []
    for day in daily:
        if not isinstance(day, dict):
            continue
        date = ccusage_day(day)
        if not date:
            continue
        timestamp = f"{date}T00:00:00Z"
        agents = day.get("agents")
        if not isinstance(agents, list):
            agents = [day]
        for agent_row in agents:
            if not isinstance(agent_row, dict):
                continue
            agent = str(agent_row.get("agent") or day.get("agent") or "ccusage")
            source = normalize_ccusage_agent(agent)
            breakdowns = agent_row.get("modelBreakdowns")
            if isinstance(breakdowns, list) and breakdowns:
                for breakdown in breakdowns:
                    if not isinstance(breakdown, dict):
                        continue
                    model = clean_ccusage_model_name(str(breakdown.get("modelName") or ""))
                    records.append(
                        new_record(
                            source=source,
                            timestamp=timestamp,
                            session_id=f"ccusage:{agent}:{date}:{model}",
                            provider=agent,
                            model=model,
                            input_tokens=as_int(breakdown.get("inputTokens")),
                            output_tokens=as_int(breakdown.get("outputTokens")),
                            cache_creation_tokens=as_int(breakdown.get("cacheCreationTokens")),
                            cache_read_tokens=as_int(breakdown.get("cacheReadTokens")),
                            reasoning_tokens=as_int(breakdown.get("reasoningTokens")),
                            total_tokens=as_int(breakdown.get("totalTokens")),
                            cost_usd=as_float(breakdown.get("cost")),
                            source_path="ccusage daily --json --by-agent",
                        )
                    )
            else:
                records.append(
                    new_record(
                        source=source,
                        timestamp=timestamp,
                        session_id=f"ccusage:{agent}:{date}",
                        provider=agent,
                        model=", ".join(str(model) for model in agent_row.get("modelsUsed", []) if model),
                        input_tokens=as_int(agent_row.get("inputTokens")),
                        output_tokens=as_int(agent_row.get("outputTokens")),
                        cache_creation_tokens=as_int(agent_row.get("cacheCreationTokens")),
                        cache_read_tokens=as_int(agent_row.get("cacheReadTokens")),
                        reasoning_tokens=as_int(agent_row.get("reasoningTokens")),
                        total_tokens=as_int(agent_row.get("totalTokens")),
                        cost_usd=as_float(agent_row.get("totalCost")),
                        source_path="ccusage daily --json --by-agent",
                    )
                )
    return records


def machine_id() -> str:
    """Best-effort stable hardware identifier, used to catch the same machine listed under two labels."""
    for candidate in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            value = Path(candidate).read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if value:
            return value
    if platform.system() == "Darwin":
        try:
            completed = subprocess.run(
                ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return ""
        match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', completed.stdout)
        if match:
            return match.group(1)
    return ""


def collect_local(
    host_label: str = "",
    ccusage_runner: str = "auto",
    timezone: str = "",
    ccusage_package: str = DEFAULT_CCUSAGE_PACKAGE,
) -> dict[str, Any]:
    home = Path.home()
    label = host_label or socket.gethostname().split(".", 1)[0]
    records: list[dict[str, Any]] = []
    try:
        records = collect_ccusage_unified(home, ccusage_runner, timezone, ccusage_package)
    except Exception as exc:  # noqa: BLE001 - one host should not block cached/offline behavior elsewhere.
        eprint(f"Warning: collect_ccusage_unified failed: {exc}")

    records.sort(key=lambda item: (item.get("timestamp") or "", item.get("source") or "", item.get("session_id") or ""))
    return {
        "schema_version": SCHEMA_VERSION,
        "host": label,
        "machine_id": machine_id(),
        "collected_at": utc_now(),
        "platform": {
            "hostname": socket.gethostname(),
            "system": platform.system(),
            "release": platform.release(),
        },
        "records": records,
        "summary": summarize_records(records),
    }


def summarize_records(records: list[dict[str, Any]]) -> dict[str, Any]:
    by_source: dict[str, dict[str, Any]] = {}
    by_service: dict[str, dict[str, Any]] = {}
    for record in records:
        source = str(record.get("source") or "unknown")
        service = str(record.get("service") or source)
        for groups, key in ((by_source, source), (by_service, service)):
            bucket = groups.setdefault(key, {"records": 0, "total_tokens": 0, "cost_usd": 0.0})
            bucket["records"] += 1
            bucket["total_tokens"] += as_int(record.get("total_tokens"))
            bucket["cost_usd"] += as_float(record.get("cost_usd"))
    for groups in (by_source, by_service):
        for bucket in groups.values():
            bucket["cost_usd"] = round(bucket["cost_usd"], 6)
    return {"records": len(records), "by_source": by_source, "by_service": by_service}


def safe_label(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return cleaned.strip("._-") or "host"


def cache_path(cache_dir: Path, label: str) -> Path:
    return cache_dir / f"{safe_label(label)}.json"


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def record_key(record: dict[str, Any]) -> tuple[str, str, str, str]:
    return (
        str(record.get("date") or ""),
        str(record.get("source") or ""),
        str(record.get("provider") or ""),
        str(record.get("model") or ""),
    )


def merge_payload(cached: dict[str, Any] | None, fresh: dict[str, Any]) -> dict[str, Any]:
    """Merge a fresh collection into the cached ledger.

    The cache is an append-only ledger: records that disappear from a host's local
    logs (pruned transcripts, reinstalls, a broken ccusage) are retained from the
    cache. When both sides have a record for the same (date, source, provider,
    model), the one with more total tokens wins — daily counts only ever grow.
    """
    fresh_records = [r for r in fresh.get("records", []) if isinstance(r, dict)]
    if cached is None:
        return fresh
    ledger: dict[tuple[str, str, str, str], dict[str, Any]] = {}
    for record in cached.get("records", []):
        if isinstance(record, dict):
            ledger[record_key(record)] = record
    for record in fresh_records:
        key = record_key(record)
        previous = ledger.get(key)
        if previous is None or as_int(record.get("total_tokens")) >= as_int(previous.get("total_tokens")):
            ledger[key] = record
    records = sorted(
        ledger.values(),
        key=lambda item: (item.get("timestamp") or "", item.get("source") or "", item.get("session_id") or ""),
    )
    merged = dict(fresh)
    merged["records"] = records
    merged["summary"] = summarize_records(records)
    if not merged.get("machine_id"):
        merged["machine_id"] = str(cached.get("machine_id") or "")
    return merged


def parse_inventory(path: Path) -> list[HostSpec]:
    specs: list[HostSpec] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise SystemExit(f"Unable to read inventory {path}: {exc}") from exc

    for line_no, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            parts = shlex.split(line, comments=True)
        except ValueError as exc:
            raise SystemExit(f"Invalid inventory line {line_no}: {exc}") from exc
        if not parts:
            continue
        values: list[str] = []
        options: dict[str, str] = {}
        for part in parts:
            if "=" in part:
                key, value = part.split("=", 1)
                options[key] = value
            else:
                values.append(part)
        if len(values) == 1:
            label = values[0]
            target = values[0]
        else:
            label = values[0]
            target = values[1]
        specs.append(HostSpec(label=label, target=target, account_label=options.get("account", ""), options=options))
    return specs


def parse_host_arg(value: str) -> HostSpec:
    if "=" in value:
        label, target = value.split("=", 1)
        return HostSpec(label=label, target=target)
    return HostSpec(label=value, target=value)


def run_remote_collect(
    spec: HostSpec,
    timeout: int,
    ccusage_runner: str,
    timezone: str = "",
    ccusage_package: str = DEFAULT_CCUSAGE_PACKAGE,
) -> tuple[dict[str, Any] | None, str]:
    script = Path(__file__).read_text(encoding="utf-8")
    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={timeout}",
        spec.target,
        "python3",
        "-",
        "--collect-local",
        "--host-label",
        spec.label,
        "--ccusage-runner",
        ccusage_runner,
        "--ccusage-package",
        ccusage_package,
    ]
    if timezone:
        command.extend(["--timezone", timezone])
    try:
        completed = subprocess.run(
            command,
            input=script,
            text=True,
            capture_output=True,
            timeout=max(timeout + 20, 30),
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    if completed.returncode != 0:
        stderr = completed.stderr.strip().splitlines()
        return None, stderr[-1] if stderr else f"ssh exited {completed.returncode}"
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        return None, f"invalid JSON from host: {exc}"
    return payload if isinstance(payload, dict) else None, ""


def collect_host(
    spec: HostSpec,
    cache_dir: Path,
    timeout: int,
    ccusage_runner: str,
    timezone: str = "",
    ccusage_package: str = DEFAULT_CCUSAGE_PACKAGE,
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    path = cache_path(cache_dir, spec.label)
    status = {
        "host": spec.label,
        "target": spec.target,
        "status": "unknown",
        "cache": str(path),
        "collected_at": "",
        "message": "",
    }

    if spec.is_local:
        fresh: dict[str, Any] | None = collect_local(spec.label, ccusage_runner, timezone, ccusage_package)
        error = ""
    else:
        fresh, error = run_remote_collect(spec, timeout, ccusage_runner, timezone, ccusage_package)

    cached = load_json(path)
    if fresh is not None:
        fresh_count = len(fresh.get("records", []))
        payload = merge_payload(cached, fresh)
        status["status"] = "updated"
        status["collected_at"] = str(payload.get("collected_at") or "")
        if not fresh_count and cached is not None:
            status["message"] = "no fresh records; kept ledger"
        atomic_write_json(path, payload)
        return payload, status

    if cached is not None:
        status["status"] = "cached"
        status["collected_at"] = str(cached.get("collected_at") or "")
        status["message"] = error
        return cached, status

    status["status"] = "missing"
    status["message"] = error
    return None, status


def add_host_context(payload: dict[str, Any], spec: HostSpec, cached: bool) -> list[dict[str, Any]]:
    host = str(payload.get("host") or spec.label)
    collected_at = str(payload.get("collected_at") or "")
    records = payload.get("records") if isinstance(payload.get("records"), list) else []
    output = []
    for item in records:
        if not isinstance(item, dict):
            continue
        record = dict(item)
        record["host"] = host
        record["host_label"] = spec.label
        record["account_label"] = spec.account_label
        if spec.account_label and not record.get("account"):
            record["account"] = spec.account_label
        record["cache_collected_at"] = collected_at
        record["from_cache"] = cached
        output.append(record)
    return output


def aggregate_daily(
    records: list[dict[str, Any]], *, split_hosts: bool = False, split_accounts: bool = False
) -> list[dict[str, Any]]:
    buckets: dict[tuple[str, ...], dict[str, Any]] = {}
    for record in records:
        host_value = str(record.get("host") or "") if split_hosts else "all"
        account_label_value = str(record.get("account_label") or "") if split_accounts else "all"
        account_value = str(record.get("account") or "") if split_accounts else "all"
        key = (
            str(record.get("date") or ""),
            host_value,
            account_label_value,
            str(record.get("source") or ""),
            str(record.get("service") or ""),
            str(record.get("provider") or ""),
            str(record.get("model") or ""),
            account_value,
        )
        bucket = buckets.setdefault(
            key,
            {
                "date": key[0],
                "host": key[1],
                "account_label": key[2],
                "source": key[3],
                "service": key[4],
                "provider": key[5],
                "model": key[6],
                "account": key[7],
                "records": 0,
                "hosts": set(),
                "accounts": set(),
                "input_tokens": 0,
                "output_tokens": 0,
                "cache_creation_tokens": 0,
                "cache_read_tokens": 0,
                "reasoning_tokens": 0,
                "total_tokens": 0,
                "cost_usd": 0.0,
            },
        )
        bucket["records"] += 1
        if record.get("host"):
            bucket["hosts"].add(str(record.get("host")))
        account_bits = [str(record.get("account_label") or ""), str(record.get("account") or "")]
        account_text = ":".join(bit for bit in account_bits if bit)
        if account_text:
            bucket["accounts"].add(account_text)
        for field in (
            "input_tokens",
            "output_tokens",
            "cache_creation_tokens",
            "cache_read_tokens",
            "reasoning_tokens",
            "total_tokens",
        ):
            bucket[field] += as_int(record.get(field))
        bucket["cost_usd"] += as_float(record.get("cost_usd"))

    daily = []
    for bucket in buckets.values():
        row = dict(bucket)
        row["hosts"] = ",".join(sorted(bucket["hosts"]))
        row["accounts"] = ",".join(sorted(bucket["accounts"]))
        row["cost_usd"] = round(row["cost_usd"], 10)
        daily.append(row)
    daily.sort(key=lambda item: (item["date"], item["host"], item["source"], item["service"], item["model"]))
    return daily


def write_csv(path: Path, records: list[dict[str, Any]]) -> None:
    columns = [
        "date",
        "timestamp",
        "host",
        "host_label",
        "account_label",
        "source",
        "service",
        "account",
        "provider",
        "model",
        "session_id",
        "project",
        "input_tokens",
        "output_tokens",
        "cache_creation_tokens",
        "cache_read_tokens",
        "reasoning_tokens",
        "total_tokens",
        "cost_usd",
        "from_cache",
        "cache_collected_at",
        "source_path",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for record in records:
            writer.writerow(record)


def write_daily_csv(path: Path, records: list[dict[str, Any]]) -> None:
    columns = [
        "date",
        "host",
        "account_label",
        "source",
        "service",
        "provider",
        "model",
        "account",
        "hosts",
        "accounts",
        "records",
        "input_tokens",
        "output_tokens",
        "cache_creation_tokens",
        "cache_read_tokens",
        "reasoning_tokens",
        "total_tokens",
        "cost_usd",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for record in records:
            writer.writerow(record)


def json_for_script(payload: Any) -> str:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).replace("</", "<\\/")


def html_escape(value: Any) -> str:
    return html.escape(str(value), quote=True)


def fmt_tokens(value: Any) -> str:
    number = as_float(value)
    if number >= 1e9:
        return f"{number / 1e9:.1f}B"
    if number >= 1e6:
        return f"{number / 1e6:.1f}M"
    if number >= 1e3:
        return f"{number / 1e3:.0f}k"
    return str(int(round(number)))


def fmt_usd(value: Any) -> str:
    number = as_float(value)
    if number >= 1000:
        return f"${number:,.0f}"
    return f"${number:.2f}"


def static_dashboard_html(rows: list[dict[str, Any]]) -> tuple[str, str]:
    """Prerender the stat tiles and model table so the page shows data even where
    JavaScript is blocked (mail/chat/drive previews). JS re-renders on load."""
    totals = {key: 0 for key in ("input_tokens", "output_tokens", "cache_creation_tokens", "cache_read_tokens", "total_tokens")}
    cost = 0.0
    latest = ""
    models: dict[tuple[str, str, str], dict[str, Any]] = {}
    for row in rows:
        for key in totals:
            totals[key] += as_int(row.get(key))
        cost += as_float(row.get("cost_usd"))
        latest = max(latest, str(row.get("date") or ""))
        model_key = (str(row.get("service") or ""), str(row.get("provider") or ""), str(row.get("model") or ""))
        bucket = models.setdefault(
            model_key,
            {"model": model_key[2], "service": model_key[0], "days": set(), "sources": set(),
             "input_tokens": 0, "output_tokens": 0, "cache_tokens": 0, "total_tokens": 0, "cost_usd": 0.0},
        )
        for key in ("input_tokens", "output_tokens", "total_tokens"):
            bucket[key] += as_int(row.get(key))
        bucket["cache_tokens"] += as_int(row.get("cache_creation_tokens")) + as_int(row.get("cache_read_tokens"))
        bucket["cost_usd"] += as_float(row.get("cost_usd"))
        if row.get("date"):
            bucket["days"].add(str(row.get("date")))
        if row.get("source"):
            bucket["sources"].add(str(row.get("source")))

    stats = [
        ("est. cost", fmt_usd(cost)),
        ("output", fmt_tokens(totals["output_tokens"])),
        ("input", fmt_tokens(totals["input_tokens"])),
        ("cache read", fmt_tokens(totals["cache_read_tokens"])),
        ("cache write", fmt_tokens(totals["cache_creation_tokens"])),
        ("total", fmt_tokens(totals["total_tokens"])),
        ("models", str(len(models))),
        ("latest", latest or "n/a"),
    ]
    stats_html = "".join(
        f'<div class="stat"><div class="label">{html_escape(label)}</div><div class="value">{html_escape(value)}</div></div>'
        for label, value in stats
    )

    ranked = sorted(models.values(), key=lambda item: (item["cost_usd"], item["total_tokens"]), reverse=True)
    model_rows = []
    for bucket in ranked:
        meta = " · ".join(part for part in (bucket["service"], "via " + ", ".join(sorted(bucket["sources"])) if bucket["sources"] else "") if part)
        model_rows.append(
            "<tr><td>"
            f'<div class="model-name">{html_escape(bucket["model"] or "unknown")}</div>'
            f'<div class="meta">{html_escape(meta)}</div></td>'
            f'<td class="num">{len(bucket["days"])}</td>'
            f'<td class="num">{fmt_tokens(bucket["input_tokens"])}</td>'
            f'<td class="num">{fmt_tokens(bucket["output_tokens"])}</td>'
            f'<td class="num">{fmt_tokens(bucket["cache_tokens"])}</td>'
            f'<td class="num">{fmt_tokens(bucket["total_tokens"])}</td>'
            f'<td class="num">{fmt_usd(bucket["cost_usd"])}</td></tr>'
        )
    return stats_html, "".join(model_rows)


def dashboard_payload(combined: dict[str, Any], daily: list[dict[str, Any]]) -> dict[str, Any]:
    # The dashboard recomputes every aggregate client-side from `rows` (the date
    # range and host filters need that anyway), so only rows and host statuses
    # are embedded.
    rows = []
    for record in sorted(daily, key=lambda item: (item.get("date") or "", item.get("source") or "", item.get("model") or "")):
        rows.append(
            {
                "date": str(record.get("date") or ""),
                "source": str(record.get("source") or ""),
                "service": str(record.get("service") or ""),
                "provider": str(record.get("provider") or ""),
                "model": str(record.get("model") or ""),
                "host": str(record.get("host") or ""),
                "hosts": str(record.get("hosts") or record.get("host") or ""),
                "accounts": str(record.get("accounts") or ""),
                "records": as_int(record.get("records")),
                "input_tokens": as_int(record.get("input_tokens")),
                "output_tokens": as_int(record.get("output_tokens")),
                "cache_creation_tokens": as_int(record.get("cache_creation_tokens")),
                "cache_read_tokens": as_int(record.get("cache_read_tokens")),
                "reasoning_tokens": as_int(record.get("reasoning_tokens")),
                "total_tokens": as_int(record.get("total_tokens")),
                "cost_usd": round(as_float(record.get("cost_usd")), 10),
            }
        )

    return {
        "generated_at": combined.get("generated_at") or utc_now(),
        "rows": rows,
        "hosts": combined.get("statuses", []),
    }


HTML_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI Usage Ledger</title>
<style>
:root {
  --paper: #15130f;
  --ink: #ede4d1;
  --muted: #9d927f;
  --rule: #343025;
  --rule-strong: #5a4d35;
  --gold: #d8a33d;
  --green: #77b77a;
  --red: #d66b55;
  --in: #d7e7e0;
  --out: #8fb8b6;
  --cw: #577f86;
  --cr: #314f62;
  --rz: #7d6c9f;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  color: var(--ink);
  background:
    radial-gradient(circle at 12% 8%, rgba(216, 163, 61, .11), transparent 28rem),
    linear-gradient(90deg, rgba(255,255,255,.025) 1px, transparent 1px),
    var(--paper);
  background-size: auto, 44px 44px, auto;
  font-family: Georgia, "Times New Roman", serif;
}
main { width: min(1220px, calc(100vw - 32px)); margin: 0 auto; padding: 34px 0 44px; }
.mast { border-bottom: 1px solid var(--rule-strong); padding-bottom: 18px; display: flex; justify-content: space-between; gap: 20px; }
h1 { margin: 0; font-size: clamp(38px, 7vw, 92px); line-height: .88; letter-spacing: -.05em; font-weight: 500; }
.kicker, .label, th { color: var(--muted); font: 11px/1.2 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; letter-spacing: .14em; text-transform: uppercase; }
.generated { text-align: right; align-self: end; max-width: 360px; }
.stats { display: grid; grid-template-columns: repeat(8, minmax(0, 1fr)); border-bottom: 1px solid var(--rule); }
.stat { padding: 18px 14px 16px; border-right: 1px solid var(--rule); min-width: 0; }
.stat:last-child { border-right: 0; }
.value { font: 29px/.95 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; letter-spacing: -.05em; white-space: nowrap; }
.rangebar { display: flex; flex-wrap: wrap; align-items: center; gap: 14px 26px; padding: 16px 0; border-bottom: 1px solid var(--rule); }
.filter-group { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
.presets, .chips { display: flex; flex-wrap: wrap; gap: 8px; }
.rangebar button, .rangebar input { color: var(--muted); background: var(--paper); border: 1px solid var(--rule); padding: 8px 12px; font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; border-radius: 999px; }
.rangebar input { color: var(--ink); }
.rangebar button { cursor: pointer; text-transform: uppercase; letter-spacing: .08em; }
.rangebar button.active { border-color: var(--gold); color: var(--ink); }
.rangebar button:hover, .rangebar input:focus { border-color: var(--gold); outline: 0; }
.range-readout { color: var(--muted); font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.grid { display: grid; grid-template-columns: minmax(0, 1.35fr) minmax(320px, .65fr); gap: 28px; margin-top: 30px; align-items: start; }
.panel { border-top: 1px solid var(--rule-strong); padding-top: 14px; min-width: 0; }
.flow-panel { overflow: hidden; padding-bottom: 8px; }
.panel h2 { margin: 0 0 14px; font-size: 22px; font-weight: 500; letter-spacing: -.02em; }
.chart-head { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
.chart-head h2 { margin: 0; }
.scale-control { display: flex; align-items: center; gap: 8px; color: var(--muted); font: 11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; text-transform: uppercase; letter-spacing: .12em; }
.scale-control select { color: var(--ink); background: var(--paper); border: 1px solid var(--rule); padding: 6px 8px; font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.chart-body { min-width: 0; }
.chart { height: 320px; border-bottom: 1px solid var(--rule); }
.chart svg { display: block; width: 100%; height: 100%; overflow: visible; }
.chart .axis path, .chart .axis line { stroke: var(--rule-strong); }
.chart .axis text { fill: var(--muted); font: 10px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.chart .cost-axis text { fill: var(--gold); }
.chart .grid line { stroke: rgba(237,228,209,.08); }
.chart .grid path { display: none; }
.chart .cost-line { fill: none; stroke: var(--gold); stroke-width: 3; vector-effect: non-scaling-stroke; }
.chart .cost-dot { fill: var(--paper); stroke: var(--gold); stroke-width: 2; vector-effect: non-scaling-stroke; }
.legend { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 10px; color: var(--muted); font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.swatch { display: inline-block; width: 10px; height: 10px; margin-right: 5px; vertical-align: -1px; }
.swatch.line { height: 2px; width: 18px; vertical-align: 3px; }
.heatmaps { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 24px; margin-top: 30px; }
.heatmap-wrap { border-top: 1px solid var(--rule); padding-top: 12px; min-width: 0; }
.heatmap-head { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; margin-bottom: 10px; }
.heatmap-title { font-size: 18px; letter-spacing: -.02em; }
.heatmap-max { color: var(--muted); font: 11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.heatmap-scroll { overflow-x: auto; padding-bottom: 4px; }
.heat-months { display: grid; gap: 3px; margin: 0 0 5px; color: var(--muted); font: 10px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; min-height: 12px; }
.heat-month { width: 11px; white-space: nowrap; overflow: visible; }
.heatmap { display: grid; grid-template-rows: repeat(7, 11px); grid-auto-flow: column; grid-auto-columns: 11px; gap: 3px; min-height: 95px; align-items: center; }
.cell { width: 11px; height: 11px; border: 1px solid rgba(237,228,209,.07); background: #211e18; }
.cell.empty { opacity: 0; border-color: transparent; }
.cell.l1 { background: #2f3f39; } .cell.l2 { background: #476a5c; } .cell.l3 { background: #6da077; } .cell.l4 { background: #b5cf73; }
.cell.cost.l1 { background: #46351d; } .cell.cost.l2 { background: #765426; } .cell.cost.l3 { background: #ad7830; } .cell.cost.l4 { background: var(--gold); }
.heatmap-legend { display: flex; justify-content: flex-end; align-items: center; gap: 5px; color: var(--muted); font: 11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; margin-top: 8px; }
.hovercard { position: fixed; z-index: 20; pointer-events: none; transform: translate(12px, 12px); border: 1px solid var(--rule-strong); background: #211d16; color: var(--ink); padding: 8px 10px; font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; box-shadow: 0 10px 30px rgba(0,0,0,.35); display: none; max-width: 280px; }
.servicebar { display: flex; height: 32px; border: 1px solid var(--rule); margin-bottom: 12px; }
.servicebit { min-width: 2px; }
.service-list { display: grid; gap: 8px; }
.service-row { display: grid; grid-template-columns: 1fr auto; gap: 12px; font: 13px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: var(--muted); }
.tokenmax { margin-top: 20px; border-top: 1px solid var(--rule); padding-top: 14px; }
.tokenmax-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.tokenmax-metric { border-left: 1px solid var(--rule); padding-left: 10px; }
.tokenmax-metric strong { display: block; font: 22px/.95 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; letter-spacing: -.04em; }
.tokenmax-line { margin-top: 12px; color: var(--gold); font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.table-tools { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 12px; }
.table-tools input { color: var(--ink); background: var(--paper); border: 1px solid var(--rule); padding: 8px 14px; font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; border-radius: 999px; flex: 1 1 240px; max-width: 380px; }
.table-tools input:focus { border-color: var(--gold); outline: 0; }
.table-scroll { overflow-x: auto; -webkit-overflow-scrolling: touch; }
table { width: 100%; min-width: 640px; border-collapse: collapse; font: 13px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
th, td { padding: 10px 8px; border-bottom: 1px solid var(--rule); vertical-align: top; }
th { text-align: left; }
th.sortable { cursor: pointer; user-select: none; white-space: nowrap; }
th.sortable:hover { color: var(--ink); }
th.sortable.asc::after { content: " \\2191"; } th.sortable.desc::after { content: " \\2193"; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.model-name { color: var(--ink); font-family: Georgia, "Times New Roman", serif; font-size: 15px; }
.meta { color: var(--muted); font-size: 11px; margin-top: 3px; }
.hosts { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 12px; }
.host { border: 1px solid var(--rule); padding: 7px 9px; font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: var(--muted); }
.host.updated .dot { color: var(--green); } .host.cached .dot { color: var(--gold); } .host.missing .dot { color: var(--red); }
.note { color: var(--muted); font-size: 13px; line-height: 1.45; margin-top: 12px; }
.coverage { display: none; border: 1px solid var(--gold); color: var(--gold); padding: 10px 12px; margin-top: 14px; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.coverage.visible { display: block; }
@media (max-width: 900px) {
  .mast, .grid, .heatmaps { display: block; }
  .generated { text-align: left; margin-top: 14px; max-width: none; }
  .heatmap-wrap { margin-top: 20px; }
  aside.panel { margin-top: 26px; }
  .stats { grid-template-columns: repeat(2, 1fr); }
  .stat:nth-child(2n) { border-right: 0; }
}
@media (max-width: 600px) {
  main { padding-top: 20px; }
  .stat { padding: 14px 10px 12px; }
  .value { font-size: 21px; }
  .chart { height: 240px; }
  th, td { padding: 8px 6px; }
  .rangebar button, .rangebar input, .table-tools input { padding: 10px 14px; }
  .hovercard { max-width: 220px; }
}
</style>
</head>
<body>
<main>
  <header class="mast">
    <div><div class="kicker">Personal instrument panel</div><h1>AI Usage<br>Ledger</h1></div>
    <div class="generated"><div class="label">Generated</div><div id="generated">__GENERATED_AT__</div><p class="note">Accounts are merged by default. Cost is an API-equivalent estimate from ccusage pricing, not billed spend.</p></div>
  </header>
  <section class="stats" id="stats" aria-label="Summary statistics">__STATIC_STATS__</section>
  <noscript><div class="coverage visible">This viewer has JavaScript disabled, so the charts and filters are unavailable — the numbers above and the model table below are all-time totals. Download the file and open it in a browser for the interactive version.</div></noscript>
  <div id="coverage" class="coverage" role="alert"></div>
  <section class="rangebar" aria-label="Filters">
    <div class="filter-group" aria-label="Date range presets">
      <span class="label">Range</span>
      <div class="presets" id="presets">
        <button type="button" data-range="all" class="active">All</button>
        <button type="button" data-range="7">7D</button>
        <button type="button" data-range="30">30D</button>
        <button type="button" data-range="90">90D</button>
        <button type="button" data-range="365">1Y</button>
      </div>
    </div>
    <div class="filter-group" aria-label="Custom date range">
      <span class="label">From</span><input id="fromDate" type="date">
      <span class="label">To</span><input id="toDate" type="date">
    </div>
    <div class="filter-group" aria-label="Host filter">
      <span class="label">Hosts</span>
      <div class="chips" id="hostFilter"></div>
    </div>
    <span class="range-readout" id="rangeReadout"></span>
  </section>
  <section class="grid">
    <div class="panel flow-panel">
      <div class="chart-head">
        <h2>Daily Token Flow</h2>
        <label class="scale-control">Y scale <select id="tokenScale"><option value="log" selected>Log</option><option value="linear">Linear</option></select></label>
      </div>
      <div class="chart-body">
        <div id="chart" class="chart" aria-label="Daily token bars and estimated cost curve"></div>
      </div>
      <div class="legend">
        <span><i class="swatch" style="background:var(--in)"></i>input</span>
        <span><i class="swatch" style="background:var(--out)"></i>output</span>
        <span><i class="swatch" style="background:var(--cw)"></i>cache write</span>
        <span><i class="swatch" style="background:var(--cr)"></i>cache read</span>
        <span><i class="swatch" style="background:var(--rz)"></i>reasoning</span>
        <span><i class="swatch line" style="background:var(--gold)"></i>est. cost</span>
      </div>
    </div>
    <aside class="panel">
      <h2>Provider Mix</h2>
      <div id="servicebar" class="servicebar"></div>
      <div id="services" class="service-list"></div>
      <div class="tokenmax">
        <h2>Tokenmaxxing</h2>
        <div id="tokenmax" class="tokenmax-grid"></div>
        <div id="tokenmaxLine" class="tokenmax-line"></div>
      </div>
      <p class="note">Provider mix groups usage by the inferred model family (Claude, OpenAI, Gemini, Grok, …) regardless of which agent routed it; hover a segment to see the routing agents.</p>
    </aside>
  </section>
  <section class="heatmaps" aria-label="Daily heatmaps">
    <div class="heatmap-wrap">
      <div class="heatmap-head"><div class="heatmap-title">Daily Token Measure</div><div id="tokenHeatMax" class="heatmap-max"></div></div>
      <div class="heatmap-scroll"><div id="tokenHeatMonths" class="heat-months"></div><div id="tokenHeatmap" class="heatmap"></div></div>
      <div class="heatmap-legend"><span>less</span><i class="cell"></i><i class="cell l1"></i><i class="cell l2"></i><i class="cell l3"></i><i class="cell l4"></i><span>more</span></div>
    </div>
    <div class="heatmap-wrap">
      <div class="heatmap-head"><div class="heatmap-title">Daily Estimated Cost</div><div id="costHeatMax" class="heatmap-max"></div></div>
      <div class="heatmap-scroll"><div id="costHeatMonths" class="heat-months"></div><div id="costHeatmap" class="heatmap"></div></div>
      <div class="heatmap-legend"><span>less</span><i class="cell cost"></i><i class="cell cost l1"></i><i class="cell cost l2"></i><i class="cell cost l3"></i><i class="cell cost l4"></i><span>more</span></div>
    </div>
  </section>
  <section class="panel" style="margin-top:42px">
    <h2>Top Models</h2>
    <div class="table-tools">
      <input id="modelSearch" type="search" placeholder="Filter by model, provider, agent, or host…" aria-label="Filter models">
      <span class="range-readout" id="modelCount"></span>
    </div>
    <div class="table-scroll">
      <table>
        <thead><tr>
          <th class="sortable" data-key="model">Model</th>
          <th class="num sortable" data-key="days">Days</th>
          <th class="num sortable" data-key="input_tokens">Input</th>
          <th class="num sortable" data-key="output_tokens">Output</th>
          <th class="num sortable" data-key="cache">Cache</th>
          <th class="num sortable" data-key="total_tokens">Total</th>
          <th class="num sortable desc" data-key="cost_usd">Est. Cost</th>
        </tr></thead>
        <tbody id="models">__STATIC_MODELS__</tbody>
      </table>
    </div>
  </section>
  <section class="panel" style="margin-top:30px">
    <h2>Host Cache Status</h2>
    <div id="hosts" class="hosts"></div>
  </section>
</main>
<div id="hovercard" class="hovercard"></div>
__D3_SCRIPT__
<script id="usage-data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('usage-data').textContent);
const fields = ['input_tokens','output_tokens','cache_creation_tokens','cache_read_tokens','reasoning_tokens'];
const segClass = ['in','out','cw','cr','rz'];
let state = { from: null, to: null, preset: 'all', hosts: ['all'], tokenScale: 'log' };
function fmt(n) { n = Number(n || 0); if (n >= 1e9) return (n/1e9).toFixed(1)+'B'; if (n >= 1e6) return (n/1e6).toFixed(1)+'M'; if (n >= 1e3) return (n/1e3).toFixed(0)+'k'; return String(Math.round(n)); }
function usd(n) { return '$' + Number(n || 0).toFixed(2); }
function pct(n) { return Number(n || 0).toFixed(1) + '%'; }
function providerCostLines(day) {
  const costs = Object.entries(day.provider_costs || {}).filter(([, value]) => Number(value || 0) > 0).sort((a, b) => Number(b[1]) - Number(a[1]));
  if (!costs.length) return ['provider cost: none reported'];
  return ['provider cost', ...costs.map(([provider, value]) => `${provider}: ${usd(value)}`)];
}
function node(tag, cls, text) { const el = document.createElement(tag); if (cls) el.className = cls; if (text !== undefined) el.textContent = text; return el; }
function clear(id) { const el = document.getElementById(id); while (el.firstChild) el.removeChild(el.firstChild); return el; }
function addTotals(target, row) { fields.concat(['total_tokens']).forEach(f => target[f] = Number(target[f] || 0) + Number(row[f] || 0)); target.cost_usd = Number(target.cost_usd || 0) + Number(row.cost_usd || 0); target.records = Number(target.records || 0) + Number(row.records || 0); }
function dateAdd(date, delta) { const d = new Date(date + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + delta); return d.toISOString().slice(0,10); }
function availableDates() { return [...new Set((D.rows || []).map(r => r.date).filter(Boolean))].sort(); }
function rowHosts(row) { return (row.host || row.hosts || '').split(',').map(v => v.trim()).filter(Boolean); }
function selectedRows() { return (D.rows || []).filter(r => {
  const hostOk = state.hosts.includes('all') || state.hosts.length === 0 || rowHosts(r).some(host => state.hosts.includes(host));
  return (!state.from || r.date >= state.from) && (!state.to || r.date <= state.to) && hostOk;
}); }
function providerGroup(row) {
  if (row.service === 'codex') return 'openai';
  return row.service || row.provider || row.source || 'unknown';
}
function derive(rows) {
  const daysMap = new Map(), modelsMap = new Map(), servicesMap = new Map();
  rows.forEach(row => {
    if (!row.date) return;
    const provider = providerGroup(row);
    if (!daysMap.has(row.date)) daysMap.set(row.date, {date: row.date, records:0, input_tokens:0, output_tokens:0, cache_creation_tokens:0, cache_read_tokens:0, reasoning_tokens:0, total_tokens:0, cost_usd:0, provider_costs:{}});
    const dayBucket = daysMap.get(row.date);
    addTotals(dayBucket, row);
    dayBucket.provider_costs[provider] = Number(dayBucket.provider_costs[provider] || 0) + Number(row.cost_usd || 0);
    const modelKey = [row.service, row.provider, row.model].join('\u0000');
    if (!modelsMap.has(modelKey)) modelsMap.set(modelKey, {service: row.service, provider: row.provider, model: row.model, days: new Set(), sources: new Set(), hosts: new Set(), accounts: new Set(), records:0, input_tokens:0, output_tokens:0, cache_creation_tokens:0, cache_read_tokens:0, reasoning_tokens:0, total_tokens:0, cost_usd:0});
    const model = modelsMap.get(modelKey); addTotals(model, row); model.days.add(row.date); model.sources.add(row.source); (row.hosts || '').split(',').filter(Boolean).forEach(v => model.hosts.add(v)); (row.accounts || '').split(',').filter(Boolean).forEach(v => model.accounts.add(v));
    if (!servicesMap.has(provider)) servicesMap.set(provider, {provider, sources: new Set(), records:0, input_tokens:0, output_tokens:0, cache_creation_tokens:0, cache_read_tokens:0, reasoning_tokens:0, total_tokens:0, cost_usd:0});
    const serviceBucket = servicesMap.get(provider);
    serviceBucket.sources.add(row.source);
    addTotals(serviceBucket, row);
  });
  const days = [...daysMap.values()].sort((a,b) => a.date.localeCompare(b.date));
  const models = [...modelsMap.values()].map(m => ({...m, days: m.days.size, sources: [...m.sources].sort(), hosts: [...m.hosts].sort(), accounts: [...m.accounts].sort()})).sort((a,b) => (b.cost_usd - a.cost_usd) || (b.total_tokens - a.total_tokens));
  const services = [...servicesMap.values()].map(s => ({...s, sources: [...s.sources].sort()})).sort((a,b) => (b.cost_usd - a.cost_usd) || (b.total_tokens - a.total_tokens));
  const summary = {records:0, input_tokens:0, output_tokens:0, cache_creation_tokens:0, cache_read_tokens:0, reasoning_tokens:0, total_tokens:0, cost_usd:0, active_models: models.length, first_date: days[0]?.date || '', latest_date: days.at(-1)?.date || ''};
  days.forEach(day => addTotals(summary, day));
  return {days, models, services, summary};
}
function renderStats(summary) {
  document.getElementById('generated').textContent = D.generated_at || 'unknown';
  const stats = [
    ['est. cost', usd(summary.cost_usd)], ['output', fmt(summary.output_tokens)], ['input', fmt(summary.input_tokens)],
    ['cache read', fmt(summary.cache_read_tokens)], ['cache write', fmt(summary.cache_creation_tokens)], ['total', fmt(summary.total_tokens)],
    ['models', fmt(summary.active_models)], ['latest', summary.latest_date || 'n/a']
  ];
  const root = clear('stats');
  stats.forEach(([label, value]) => { const box = node('div','stat'); box.append(node('div','label',label)); box.append(node('div','value',value)); root.append(box); });
}
function dateLabel(date) {
  const parsed = new Date(date + 'T00:00:00Z');
  return parsed.toLocaleDateString('en', {month: 'short', day: 'numeric', timeZone: 'UTC'});
}
function d3TokenScale(max, height) {
  if (state.tokenScale === 'log') return d3.scaleLog().domain([1, Math.max(1, max)]).range([height, 0]).clamp(true);
  return d3.scaleLinear().domain([0, Math.max(1, max)]).nice().range([height, 0]);
}
function d3Value(scale, value, height) {
  value = Number(value || 0);
  if (!value) return height;
  if (state.tokenScale === 'log') return scale(Math.max(1, value));
  return scale(value);
}
function d3Ticks(max) {
  max = Number(max || 0);
  if (!max) return [0];
  if (state.tokenScale !== 'log') return null;
  const ticks = [];
  let value = 1;
  while (value < max) { ticks.push(value); value *= 10; }
  ticks.push(max);
  return ticks.filter((value, index, arr) => index === arr.length - 1 || value >= max / 100000).slice(-7);
}
function renderChart(days) {
  const rootNode = clear('chart');
  if (!window.d3) {
    rootNode.append(node('div', 'note', 'D3 failed to load; chart unavailable.'));
    return;
  }
  const root = d3.select(rootNode);
  const width = Math.max(420, rootNode.clientWidth || 900);
  const height = 320;
  const margin = {top: 18, right: 72, bottom: 38, left: 70};
  const innerWidth = width - margin.left - margin.right;
  const innerHeight = height - margin.top - margin.bottom;
  const maxTokens = d3.max(days, d => Number(d.total_tokens || 0)) || 1;
  const maxCost = d3.max(days, d => Number(d.cost_usd || 0)) || 0;
  const x = d3.scaleBand().domain(days.map(d => d.date)).range([margin.left, margin.left + innerWidth]).paddingInner(0.18).paddingOuter(0.05);
  const yTokens = d3TokenScale(maxTokens, innerHeight);
  const yCost = d3TokenScale(maxCost || 1, innerHeight);
  const tokenValue = value => margin.top + d3Value(yTokens, value, innerHeight);
  const costValue = value => margin.top + d3Value(yCost, value, innerHeight);
  const barBase = margin.top + innerHeight;
  const svg = root.append('svg').attr('viewBox', `0 0 ${width} ${height}`).attr('role', 'img').attr('aria-label', 'Daily token bars with reported cost curve');
  const tokenTicks = d3Ticks(maxTokens);
  const costTicks = d3Ticks(maxCost || 1);
  const xTickCount = Math.min(7, days.length);
  const xTickValues = [];
  for (let i = 0; i < xTickCount; i += 1) {
    const index = xTickCount === 1 ? 0 : Math.round(i * (days.length - 1) / (xTickCount - 1));
    if (days[index] && !xTickValues.includes(days[index].date)) xTickValues.push(days[index].date);
  }
  svg.append('g')
    .attr('class', 'grid')
    .attr('transform', `translate(${margin.left},${margin.top})`)
    .call(d3.axisLeft(yTokens).tickValues(tokenTicks).ticks(5, '~s').tickSize(-innerWidth).tickFormat(''));
  svg.append('g')
    .attr('class', 'axis token-axis')
    .attr('transform', `translate(${margin.left},${margin.top})`)
    .call(d3.axisLeft(yTokens).tickValues(tokenTicks).ticks(5, '~s').tickFormat(d => fmt(d)));
  svg.append('g')
    .attr('class', 'axis cost-axis')
    .attr('transform', `translate(${margin.left + innerWidth},${margin.top})`)
    .call(d3.axisRight(yCost).tickValues(costTicks).ticks(5, '~s').tickFormat(d => usd(d)));
  svg.append('g')
    .attr('class', 'axis x-axis')
    .attr('transform', `translate(0,${barBase})`)
    .call(d3.axisBottom(x).tickValues(xTickValues).tickFormat(dateLabel));
  const bars = svg.append('g').attr('class', 'token-bars');
  days.forEach(day => {
    const total = Number(day.total_tokens || 0);
    let cursor = barBase;
    fields.forEach((field, idx) => {
      const value = Number(day[field] || 0);
      const share = total ? value / total : 0;
      const totalHeight = barBase - tokenValue(total);
      const segmentHeight = totalHeight * share;
      cursor -= segmentHeight;
      bars.append('rect')
        .attr('x', x(day.date))
        .attr('y', cursor)
        .attr('width', Math.max(1, x.bandwidth()))
        .attr('height', Math.max(0, segmentHeight))
        .attr('fill', `var(--${segClass[idx]})`)
        .append('title').text(`${day.date} · ${fmt(value)} ${field.replaceAll('_', ' ')} · ${fmt(total)} total · ${usd(day.cost_usd)}`);
    });
  });
  const line = d3.line()
    .defined(d => Number(d.cost_usd || 0) > 0)
    .x(d => (x(d.date) || margin.left) + x.bandwidth() / 2)
    .y(d => costValue(Number(d.cost_usd || 0)));
  svg.append('path').datum(days).attr('class', 'cost-line').attr('d', line);
  const dotEvery = days.length > 120 ? Math.ceil(days.length / 60) : 1;
  svg.append('g').selectAll('circle')
    .data(days.filter((d, i) => Number(d.cost_usd || 0) > 0 && i % dotEvery === 0))
    .join('circle')
    .attr('class', 'cost-dot')
    .attr('cx', d => (x(d.date) || margin.left) + x.bandwidth() / 2)
    .attr('cy', d => costValue(Number(d.cost_usd || 0)))
    .attr('r', 2.4)
    .append('title').text(d => `${d.date} · ${usd(d.cost_usd)} est. cost · ${fmt(d.total_tokens)} tokens`);
  const focus = svg.append('g').attr('class', 'chart-focus').style('display', 'none');
  focus.append('line').attr('y1', margin.top).attr('y2', barBase).attr('stroke', 'var(--gold)').attr('stroke-width', 1).attr('stroke-dasharray', '3 3');
  focus.append('circle').attr('r', 4).attr('fill', 'var(--paper)').attr('stroke', 'var(--gold)').attr('stroke-width', 2);
  svg.append('rect')
    .attr('x', margin.left)
    .attr('y', margin.top)
    .attr('width', innerWidth)
    .attr('height', innerHeight)
    .attr('fill', 'transparent')
    .on('mouseenter', () => focus.style('display', null))
    .on('mouseleave', () => { focus.style('display', 'none'); hideHover(); })
    .on('mousemove', event => {
      if (!days.length) return;
      const [mx] = d3.pointer(event);
      const step = innerWidth / Math.max(1, days.length);
      const index = Math.max(0, Math.min(days.length - 1, Math.floor((mx - margin.left) / step)));
      const day = days[index];
      const cx = (x(day.date) || margin.left) + x.bandwidth() / 2;
      const cy = Number(day.cost_usd || 0) ? costValue(Number(day.cost_usd || 0)) : tokenValue(Number(day.total_tokens || 0));
      focus.select('line').attr('x1', cx).attr('x2', cx);
      focus.select('circle').attr('cx', cx).attr('cy', cy);
      showHover(event, [
        day.date,
        `${fmt(day.total_tokens)} total tokens`,
        `${fmt(day.input_tokens)} in · ${fmt(day.output_tokens)} out`,
        `${fmt((day.cache_creation_tokens || 0) + (day.cache_read_tokens || 0))} cache`,
        `${usd(day.cost_usd)} est. cost`,
        ...providerCostLines(day),
        `${state.tokenScale} scale`,
      ]);
    });
}
function renderServices(services) {
  const palette = ['#d8a33d','#8fb8b6','#577f86','#7d6c9f','#d66b55','#77b77a','#ede4d1'];
  const total = Math.max(1, services.reduce((sum, row) => sum + Number(row.total_tokens || 0), 0));
  const bar = clear('servicebar');
  const list = clear('services');
  services.forEach((row, idx) => {
    const color = palette[idx % palette.length];
    const bit = node('div','servicebit'); bit.style.width = (Number(row.total_tokens || 0) / total * 100) + '%'; bit.style.background = color; bit.title = `${row.provider} · ${fmt(row.total_tokens)} · via ${(row.sources || []).join(', ')}`; bar.append(bit);
    const item = node('div','service-row'); const left = node('span','',row.provider || 'unknown'); left.style.color = color; item.append(left); item.append(node('span','',`${fmt(row.total_tokens)} · ${usd(row.cost_usd)}`)); list.append(item);
  });
}
function renderTokenmax(days, summary) {
  const root = clear('tokenmax');
  const peak = days.reduce((best, day) => Number(day.total_tokens || 0) > Number(best.total_tokens || 0) ? day : best, {date:'n/a', total_tokens:0});
  const avg = days.length ? summary.total_tokens / days.length : 0;
  const cache = Number(summary.cache_creation_tokens || 0) + Number(summary.cache_read_tokens || 0);
  const direct = Number(summary.input_tokens || 0) + Number(summary.output_tokens || 0);
  const cacheMult = direct ? cache / direct : 0;
  const outputShare = summary.total_tokens ? summary.output_tokens / summary.total_tokens * 100 : 0;
  [['peak day', `${fmt(peak.total_tokens)} on ${peak.date}`], ['avg/day', fmt(avg)], ['cache multiplier', cacheMult.toFixed(1)+'×'], ['output share', pct(outputShare)]].forEach(([label, value]) => { const box = node('div','tokenmax-metric'); box.append(node('div','label',label)); box.append(node('strong','',value)); root.append(box); });
  const line = document.getElementById('tokenmaxLine');
  line.textContent = summary.total_tokens ? `You are tokenmaxxing at ${fmt(avg)} tokens/day in this range, with ${fmt(cache)} cache tokens doing the heavy lifting.` : 'No tokens in this range.';
}
function heatLevel(value, max) { if (!value || !max) return 0; const ratio = value / max; if (ratio >= .75) return 4; if (ratio >= .45) return 3; if (ratio >= .18) return 2; return 1; }
function calendarDays(days) {
  if (!state.from || !state.to) return days.map(d => d.date);
  const output = [];
  let cursor = state.from;
  while (cursor <= state.to && output.length < 3700) { output.push(cursor); cursor = dateAdd(cursor, 1); }
  return output;
}
function shortMonth(date) { return new Date(date + 'T00:00:00Z').toLocaleString('en', {month: 'short', timeZone: 'UTC'}); }
function showHover(event, lines) {
  const tip = document.getElementById('hovercard');
  tip.replaceChildren(...lines.map(line => node('div', '', line)));
  tip.style.left = event.clientX + 'px';
  tip.style.top = event.clientY + 'px';
  tip.style.display = 'block';
}
function moveHover(event) {
  const tip = document.getElementById('hovercard');
  tip.style.left = event.clientX + 'px';
  tip.style.top = event.clientY + 'px';
}
function hideHover() { document.getElementById('hovercard').style.display = 'none'; }
function renderMonthMarkers(monthsId, calendar) {
  const root = clear(monthsId);
  if (!calendar.length) return;
  const firstDow = new Date(calendar[0] + 'T00:00:00Z').getUTCDay();
  const weekCount = Math.ceil((firstDow + calendar.length) / 7);
  root.style.gridTemplateColumns = `repeat(${weekCount}, 11px)`;
  const labels = Array.from({length: weekCount}, () => '');
  calendar.forEach((date, index) => {
    const week = Math.floor((firstDow + index) / 7);
    if (index === 0 || date.endsWith('-01')) labels[week] = shortMonth(date);
  });
  labels.forEach(label => root.append(node('span', 'heat-month', label)));
}
function renderHeatmap(rootId, monthsId, maxId, days, field, formatter, costMode) {
  const root = clear(rootId);
  const byDate = new Map(days.map(day => [day.date, day]));
  const calendar = calendarDays(days);
  renderMonthMarkers(monthsId, calendar);
  const max = Math.max(0, ...calendar.map(date => Number((byDate.get(date) || {})[field] || 0)));
  document.getElementById(maxId).textContent = max ? `peak ${formatter(max)}` : 'no activity';
  if (calendar.length) {
    const firstDow = new Date(calendar[0] + 'T00:00:00Z').getUTCDay();
    for (let i = 0; i < firstDow; i += 1) root.append(node('i', 'cell empty'));
  }
  calendar.forEach(date => {
    const day = byDate.get(date) || {date, total_tokens: 0, cost_usd: 0, input_tokens: 0, output_tokens: 0, cache_creation_tokens: 0, cache_read_tokens: 0, reasoning_tokens: 0, provider_costs: {}};
    const value = Number(day[field] || 0);
    const level = heatLevel(value, max);
    const cell = node('i', `cell${costMode ? ' cost' : ''}${level ? ' l' + level : ''}`);
    const lines = costMode
      ? [date, `${formatter(value)} est. cost`, `${fmt(day.total_tokens || 0)} tokens`, ...providerCostLines(day)]
      : [date, `${formatter(value)} total tokens`, `${fmt(day.input_tokens || 0)} in · ${fmt(day.output_tokens || 0)} out`, `${fmt((day.cache_creation_tokens || 0) + (day.cache_read_tokens || 0))} cache · ${usd(day.cost_usd || 0)}`, ...providerCostLines(day)];
    cell.setAttribute('aria-label', lines.join(' · '));
    cell.addEventListener('mouseenter', event => showHover(event, lines));
    cell.addEventListener('mousemove', moveHover);
    cell.addEventListener('mouseleave', hideHover);
    root.append(cell);
  });
}
function renderHeatmaps(days) {
  renderHeatmap('tokenHeatmap', 'tokenHeatMonths', 'tokenHeatMax', days, 'total_tokens', fmt, false);
  renderHeatmap('costHeatmap', 'costHeatMonths', 'costHeatMax', days, 'cost_usd', usd, true);
}
function hostSummary(hosts) {
  const list = (hosts || []).filter(Boolean);
  if (!list.length) return 'all hosts';
  if (list.length <= 3) return list.join(', ');
  return `${list.slice(0, 3).join(', ')} +${list.length - 3}`;
}
function routeSummary(row) {
  const sources = (row.sources || []).filter(Boolean);
  const via = sources.length ? `via ${sources.join(', ')}` : '';
  const service = row.service || '';
  return [service, via, hostSummary(row.hosts)].filter(Boolean).join(' · ');
}
let tableState = { key: 'cost_usd', dir: -1, query: '' };
let lastModels = [];
function modelSortValue(row, key) {
  if (key === 'model') return (row.model || '').toLowerCase();
  if (key === 'cache') return Number(row.cache_creation_tokens || 0) + Number(row.cache_read_tokens || 0);
  return Number(row[key] || 0);
}
function syncSortHeaders() {
  document.querySelectorAll('th.sortable').forEach(th => {
    th.classList.toggle('asc', th.dataset.key === tableState.key && tableState.dir === 1);
    th.classList.toggle('desc', th.dataset.key === tableState.key && tableState.dir === -1);
  });
}
function renderModels(models) {
  const body = clear('models');
  const query = tableState.query.trim().toLowerCase();
  const filtered = models.filter(row => !query || [row.model, row.service, row.provider, (row.sources || []).join(' '), (row.hosts || []).join(' '), (row.accounts || []).join(' ')].join(' ').toLowerCase().includes(query));
  const sorted = [...filtered].sort((a, b) => {
    const va = modelSortValue(a, tableState.key), vb = modelSortValue(b, tableState.key);
    return (va < vb ? -1 : va > vb ? 1 : 0) * tableState.dir;
  });
  sorted.forEach(row => {
    const tr = document.createElement('tr');
    const name = document.createElement('td');
    name.title = `sources: ${(row.sources || []).join(', ')}; hosts: ${(row.hosts || []).join(', ')}; accounts: ${(row.accounts || []).join(', ')}`;
    name.append(node('div','model-name',row.model || 'unknown'));
    name.append(node('div','meta',routeSummary(row)));
    tr.append(name);
    [fmt(row.days), fmt(row.input_tokens), fmt(row.output_tokens), fmt(Number(row.cache_creation_tokens || 0)+Number(row.cache_read_tokens || 0)), fmt(row.total_tokens), usd(row.cost_usd)].forEach(value => tr.append(node('td','num',value)));
    body.append(tr);
  });
  document.getElementById('modelCount').textContent = query ? `${sorted.length} of ${models.length} models` : `${models.length} models`;
  syncSortHeaders();
}
function renderHosts() {
  const root = clear('hosts');
  (D.hosts || []).forEach(row => {
    const status = row.status || 'missing';
    const stale = status === 'cached' && row.collected_at ? ` (as of ${String(row.collected_at).slice(0, 10)})` : '';
    const item = node('div','host '+status);
    item.title = row.message || row.cache || '';
    item.append(node('span','dot', status === 'updated' ? '● ' : status === 'cached' ? '◐ ' : '○ '));
    item.append(document.createTextNode(`${row.host || 'host'} · ${status}${stale}`));
    root.append(item);
  });
}
function renderCoverage() {
  const banner = document.getElementById('coverage');
  const issues = (D.hosts || []).filter(row => row.status && row.status !== 'updated');
  if (!issues.length) { banner.classList.remove('visible'); banner.textContent = ''; return; }
  const parts = issues.map(row => {
    if (row.status === 'cached') return `${row.host}: stale cache${row.collected_at ? ' from ' + String(row.collected_at).slice(0, 10) : ''}`;
    return `${row.host}: no data (${row.message || 'unreachable'})`;
  });
  banner.textContent = `⚠ Incomplete coverage — ${parts.join(' · ')}`;
  banner.classList.add('visible');
}
function applyRange(preset) {
  const dates = availableDates();
  if (!dates.length) return renderAll();
  const latest = dates.at(-1);
  state.preset = preset;
  if (preset === 'all') { state.from = dates[0]; state.to = latest; }
  else { state.to = latest; state.from = dateAdd(latest, -Number(preset) + 1); }
  document.getElementById('fromDate').value = state.from;
  document.getElementById('toDate').value = state.to;
  document.querySelectorAll('#presets button').forEach(b => b.classList.toggle('active', b.dataset.range === preset));
  renderAll();
}
function applyCustomRange() {
  state.from = document.getElementById('fromDate').value || null;
  state.to = document.getElementById('toDate').value || null;
  state.preset = 'custom';
  document.querySelectorAll('#presets button').forEach(b => b.classList.remove('active'));
  renderAll();
}
function populateHostFilter() {
  const root = clear('hostFilter');
  const hosts = ['all', ...[...new Set((D.rows || []).flatMap(rowHosts))].sort()];
  hosts.forEach(host => {
    const chip = node('button', 'chip', host === 'all' ? 'All' : host);
    chip.type = 'button';
    chip.dataset.host = host;
    chip.addEventListener('click', () => toggleHostChip(host));
    root.append(chip);
  });
  syncHostChips();
}
function toggleHostChip(host) {
  if (host === 'all') {
    state.hosts = ['all'];
  } else {
    const chosen = new Set(state.hosts.filter(value => value !== 'all'));
    if (chosen.has(host)) chosen.delete(host); else chosen.add(host);
    state.hosts = chosen.size ? [...chosen] : ['all'];
  }
  syncHostChips();
  renderAll();
}
function syncHostChips() {
  document.querySelectorAll('#hostFilter .chip').forEach(chip => {
    chip.classList.toggle('active', state.hosts.includes(chip.dataset.host));
  });
}
function applyTokenScale() {
  state.tokenScale = document.getElementById('tokenScale').value || 'log';
  renderAll();
}
function renderAll() {
  const derived = derive(selectedRows());
  lastModels = derived.models;
  renderStats(derived.summary); renderChart(derived.days); renderServices(derived.services); renderTokenmax(derived.days, derived.summary); renderHeatmaps(derived.days); renderModels(lastModels); renderHosts();
  const readout = document.getElementById('rangeReadout');
  const hostText = state.hosts.includes('all') ? 'all hosts' : state.hosts.join(', ');
  readout.textContent = `${derived.days.length} days · ${derived.summary.first_date || 'n/a'} to ${derived.summary.latest_date || 'n/a'} · ${hostText}`;
}
document.querySelectorAll('#presets button').forEach(button => button.addEventListener('click', () => applyRange(button.dataset.range)));
document.getElementById('fromDate').addEventListener('change', applyCustomRange);
document.getElementById('toDate').addEventListener('change', applyCustomRange);
document.getElementById('tokenScale').addEventListener('change', applyTokenScale);
document.getElementById('modelSearch').addEventListener('input', event => { tableState.query = event.target.value || ''; renderModels(lastModels); });
document.querySelectorAll('th.sortable').forEach(th => th.addEventListener('click', () => {
  const key = th.dataset.key;
  if (tableState.key === key) tableState.dir = -tableState.dir;
  else { tableState.key = key; tableState.dir = key === 'model' ? 1 : -1; }
  renderModels(lastModels);
}));
let resizeTimer = null;
window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(renderAll, 150); });
populateHostFilter();
renderCoverage();
applyRange('all');
</script>
</body>
</html>
"""


def d3_script_tag(cache_dir: Path) -> str:
    """Inline a pinned d3 build so the dashboard works offline; fall back to the CDN."""
    vendor = cache_dir / f"d3-{D3_VERSION}.min.js"
    source = ""
    if vendor.exists():
        try:
            source = vendor.read_text(encoding="utf-8")
        except OSError:
            source = ""
    if not source:
        try:
            with urllib.request.urlopen(D3_URL, timeout=30) as response:
                source = response.read().decode("utf-8")
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            eprint(f"Warning: could not fetch d3 for inlining ({exc}); dashboard will use the CDN.")
            return f'<script src="{D3_URL}"></script>'
        vendor.parent.mkdir(parents=True, exist_ok=True)
        vendor.write_text(source, encoding="utf-8")
    # Guard against the parser closing our tag early if the payload contains "</script".
    return "<script>" + source.replace("</script", "<\\/script") + "</script>"


def write_html(path: Path, combined: dict[str, Any], daily: list[dict[str, Any]], cache_dir: Path) -> None:
    dashboard_daily = aggregate_daily(combined["records"], split_hosts=True, split_accounts=False)
    payload = dashboard_payload(combined, dashboard_daily or daily)
    static_stats, static_models = static_dashboard_html(payload["rows"])
    rendered = HTML_TEMPLATE.replace("__DATA__", json_for_script(payload))
    rendered = rendered.replace("__D3_SCRIPT__", d3_script_tag(cache_dir))
    rendered = rendered.replace("__GENERATED_AT__", html_escape(payload.get("generated_at") or ""))
    rendered = rendered.replace("__STATIC_STATS__", static_stats)
    rendered = rendered.replace("__STATIC_MODELS__", static_models)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(rendered, encoding="utf-8")
    tmp.replace(path)


def provider_group(row: dict[str, Any]) -> str:
    service = str(row.get("service") or "")
    if service == "codex":
        return "openai"
    return service or str(row.get("provider") or row.get("source") or "unknown")


# Ledger theme for the infographic. The five segment colors were validated for the
# dark surface (OKLCH lightness band, chroma floor, CVD ΔE >= 12, contrast >= 3:1).
INFOGRAPHIC_THEME = {
    "paper": "#15130f",
    "ink": "#ede4d1",
    "muted": "#9d927f",
    "rule": "#343025",
    "rule_strong": "#5a4d35",
    "gold": "#d8a33d",
    "serif": ["Georgia", "Times New Roman", "DejaVu Serif", "serif"],
    "mono": ["Menlo", "Consolas", "DejaVu Sans Mono", "monospace"],
    "segments": [
        ("input_tokens", "input", "#5aa860"),
        ("output_tokens", "output", "#2ba3b5"),
        ("cache_creation_tokens", "cache write", "#4b83d1"),
        ("cache_read_tokens", "cache read", "#c563a9"),
        ("reasoning_tokens", "reasoning", "#d0705b"),
    ],
}


def write_infographic(path: Path, daily: list[dict[str, Any]], generated_at: str) -> bool:
    """Render a shareable PNG summary: stat tiles, daily token flow, estimated cost,
    and provider mix. No tables or host detail — this is the version to share."""
    try:
        import logging

        import matplotlib

        matplotlib.use("Agg")
        # Font fallback is expected (Menlo on macOS, DejaVu elsewhere); don't warn per glyph.
        logging.getLogger("matplotlib.font_manager").setLevel(logging.ERROR)
        import matplotlib.dates as mdates
        import matplotlib.pyplot as plt
    except ImportError:
        eprint(
            "Warning: matplotlib unavailable; skipping infographic. "
            "Run via 'uv run --script ai-usage-collect.py' to include it."
        )
        return False

    theme = INFOGRAPHIC_THEME
    days: dict[str, dict[str, float]] = {}
    providers: dict[str, dict[str, float]] = {}
    token_fields = [key for key, _, _ in theme["segments"]]
    for row in daily:
        date = str(row.get("date") or "")
        if not date:
            continue
        day = days.setdefault(date, {key: 0.0 for key in (*token_fields, "total_tokens", "cost_usd")})
        for key in (*token_fields, "total_tokens"):
            day[key] += as_int(row.get(key))
        day["cost_usd"] += as_float(row.get("cost_usd"))
        provider = providers.setdefault(provider_group(row), {"total_tokens": 0.0, "cost_usd": 0.0})
        provider["total_tokens"] += as_int(row.get("total_tokens"))
        provider["cost_usd"] += as_float(row.get("cost_usd"))

    if not days:
        eprint("Warning: no daily data; skipping infographic.")
        return False

    dates = sorted(days)
    day_values = [days[date] for date in dates]
    xs = [dt.datetime.strptime(date, "%Y-%m-%d") for date in dates]
    totals = {key: sum(day[key] for day in day_values) for key in (*token_fields, "total_tokens", "cost_usd")}
    active_segments = [(key, label, color) for key, label, color in theme["segments"] if totals[key] > 0]
    peak = max(day_values, key=lambda day: day["total_tokens"])
    peak_date = dates[day_values.index(peak)]
    cache = totals["cache_creation_tokens"] + totals["cache_read_tokens"]
    direct = totals["input_tokens"] + totals["output_tokens"]
    ranked_providers = sorted(providers.items(), key=lambda item: (item[1]["cost_usd"], item[1]["total_tokens"]), reverse=True)[:8]

    with plt.rc_context(
        {
            "figure.facecolor": theme["paper"],
            "axes.facecolor": theme["paper"],
            "font.family": theme["serif"],
            "text.color": theme["ink"],
            "axes.edgecolor": theme["rule"],
            "xtick.color": theme["muted"],
            "ytick.color": theme["muted"],
            "svg.fonttype": "none",
        }
    ):
        # 10 x 12.5 in at 108 dpi = 1080 x 1350 px: Instagram portrait (4:5), WhatsApp-friendly.
        fig = plt.figure(figsize=(10, 12.5), dpi=108)
        grid = fig.add_gridspec(
            5, 1, height_ratios=[1.05, 0.62, 3.1, 1.5, 2.1], hspace=0.42, left=0.075, right=0.94, top=0.975, bottom=0.055
        )

        header = fig.add_subplot(grid[0])
        header.axis("off")
        left, right = 0.075, 0.94
        fig.text(left, 0.962, "P E R S O N A L   I N S T R U M E N T   P A N E L", fontsize=8, color=theme["muted"], family=theme["mono"])
        fig.text(left, 0.912, "AI Usage Ledger", fontsize=38, color=theme["ink"], family=theme["serif"], va="baseline")
        fig.text(right, 0.958, f"generated {generated_at}", fontsize=8, color=theme["muted"], family=theme["mono"], ha="right")
        fig.text(right, 0.942, f"{dates[0]} to {dates[-1]} · {len(dates)} active days · all hosts merged", fontsize=8, color=theme["muted"], family=theme["mono"], ha="right")
        header.axhline(y=0.0, xmin=0, xmax=1, color=theme["rule_strong"], linewidth=1.2, clip_on=False)

        tiles = fig.add_subplot(grid[1])
        tiles.axis("off")
        stat_items = [
            ("EST. COST", fmt_usd(totals["cost_usd"])),
            ("OUTPUT", fmt_tokens(totals["output_tokens"])),
            ("INPUT", fmt_tokens(totals["input_tokens"])),
            ("CACHE READ", fmt_tokens(totals["cache_read_tokens"])),
            ("CACHE WRITE", fmt_tokens(totals["cache_creation_tokens"])),
            ("TOTAL", fmt_tokens(totals["total_tokens"])),
        ]
        step = 1.0 / len(stat_items)
        for index, (label, value) in enumerate(stat_items):
            x = index * step
            tiles.text(x, 0.78, label, fontsize=8, color=theme["muted"], family=theme["mono"])
            tiles.text(x, 0.16, value, fontsize=19, color=theme["ink"], family=theme["mono"])
            if index:
                tiles.axvline(x=x - step * 0.09, ymin=0.05, ymax=0.95, color=theme["rule"], linewidth=1)

        flow = fig.add_subplot(grid[2])
        bottoms = [0.0] * len(dates)
        bar_width = max(0.8, (xs[-1] - xs[0]).days / max(1, len(dates)) * 0.85) if len(xs) > 1 else 0.8
        for key, label, color in active_segments:
            values = [day[key] for day in day_values]
            flow.bar(xs, values, bottom=bottoms, width=bar_width, color=color, label=label, linewidth=0)
            bottoms = [base + value for base, value in zip(bottoms, values)]
        flow.set_title("Daily Token Flow", loc="left", fontsize=16, color=theme["ink"], family=theme["serif"], pad=10)
        flow.legend(loc="upper left", frameon=False, ncol=len(active_segments), fontsize=8, labelcolor=theme["muted"], handlelength=1, handleheight=1, prop={"family": theme["mono"], "size": 8})
        flow.grid(axis="y", color=theme["rule"], linewidth=0.7)
        flow.set_axisbelow(True)
        flow.yaxis.set_major_formatter(plt.FuncFormatter(lambda value, _pos: fmt_tokens(value)))
        flow.margins(x=0.01)

        cost_ax = fig.add_subplot(grid[3], sharex=flow)
        costs = [day["cost_usd"] for day in day_values]
        cost_ax.plot(xs, costs, color=theme["gold"], linewidth=1.6)
        cost_ax.fill_between(xs, costs, color=theme["gold"], alpha=0.14, linewidth=0)
        cost_ax.set_title("Daily Estimated Cost (API-equivalent)", loc="left", fontsize=16, color=theme["ink"], family=theme["serif"], pad=10)
        cost_ax.grid(axis="y", color=theme["rule"], linewidth=0.7)
        cost_ax.set_axisbelow(True)
        cost_ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda value, _pos: fmt_usd(value)))
        cost_ax.margins(x=0.01)
        cost_ax.xaxis.set_major_locator(mdates.AutoDateLocator(maxticks=8))
        cost_ax.xaxis.set_major_formatter(mdates.ConciseDateFormatter(cost_ax.xaxis.get_major_locator()))
        for axis in (flow, cost_ax):
            for side in ("top", "right", "left"):
                axis.spines[side].set_visible(False)
            for tick in (*axis.get_xticklabels(), *axis.get_yticklabels()):
                tick.set_fontfamily(theme["mono"])
                tick.set_fontsize(8)
        plt.setp(flow.get_xticklabels(), visible=False)

        mix = fig.add_subplot(grid[4])
        names = [name for name, _ in ranked_providers][::-1]
        mix_costs = [values["cost_usd"] for _, values in ranked_providers][::-1]
        mix_tokens = [values["total_tokens"] for _, values in ranked_providers][::-1]
        mix.barh(names, mix_costs, color=theme["gold"], height=0.62, linewidth=0)
        mix.set_title("Provider Mix by Estimated Cost", loc="left", fontsize=16, color=theme["ink"], family=theme["serif"], pad=10)
        top_cost = max(mix_costs) if mix_costs else 1
        for index, (cost_value, token_value) in enumerate(zip(mix_costs, mix_tokens)):
            mix.text(cost_value + top_cost * 0.015, index, f"{fmt_usd(cost_value)} · {fmt_tokens(token_value)} tokens", va="center", fontsize=8.5, color=theme["ink"], family=theme["mono"])
        mix.set_xlim(0, top_cost * 1.28)
        mix.xaxis.set_visible(False)
        for side in ("top", "right", "bottom"):
            mix.spines[side].set_visible(False)
        mix.spines["left"].set_color(theme["rule_strong"])
        mix.tick_params(axis="y", length=0)
        for tick in mix.get_yticklabels():
            tick.set_fontfamily(theme["mono"])
            tick.set_fontsize(9)
            tick.set_color(theme["ink"])

        avg = totals["total_tokens"] / max(1, len(dates))
        output_share = totals["output_tokens"] / totals["total_tokens"] * 100 if totals["total_tokens"] else 0
        cache_mult = cache / direct if direct else 0
        fig.text(0.075, 0.022, f"Tokenmaxxing at {fmt_tokens(avg)} tokens/day · cache multiplier {cache_mult:.1f}x · output share {output_share:.1f}% · peak {peak_date} ({fmt_tokens(peak['total_tokens'])})", fontsize=9, color=theme["gold"], family=theme["mono"])
        fig.text(0.075, 0.007, "Cost is an API-equivalent estimate from ccusage pricing, not billed spend · generated by ai-usage-collect.py", fontsize=7.5, color=theme["muted"], family=theme["mono"])

        path.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(path, facecolor=theme["paper"])
        plt.close(fig)
    return True


def build_combined(host_payloads: list[tuple[HostSpec, dict[str, Any], bool]], statuses: list[dict[str, Any]]) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    for spec, payload, cached in host_payloads:
        records.extend(add_host_context(payload, spec, cached))
    records.sort(key=lambda item: (item.get("timestamp") or "", item.get("host") or "", item.get("source") or ""))
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "statuses": statuses,
        "summary": summarize_records(records),
        "records": records,
    }


def default_specs(include_local: bool) -> list[HostSpec]:
    if include_local:
        return [HostSpec(label=socket.gethostname().split(".", 1)[0], target="local")]
    return []


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect Claude Code, Codex, opencode, and pi usage into JSON/CSV without copying prompts."
    )
    parser.add_argument("--inventory", type=Path, help=f"Host inventory file. Defaults to {DEFAULT_INVENTORY} next to this script when present.")
    parser.add_argument("--host", action="append", default=[], help="Remote host, or label=ssh-target. Can be repeated.")
    parser.add_argument("--no-local", action="store_true", help="Skip local collection.")
    parser.add_argument("--cache-dir", type=Path, help=f"Per-host cache directory. Defaults to {DEFAULT_CACHE_DIR} next to this script.")
    parser.add_argument("--output-json", type=Path, default=Path(DEFAULT_JSON), help=f"Combined JSON output, default {DEFAULT_JSON}.")
    parser.add_argument("--output-csv", type=Path, default=Path(DEFAULT_CSV), help=f"Combined CSV output, default {DEFAULT_CSV}.")
    parser.add_argument("--daily-json", type=Path, default=Path(DEFAULT_DAILY_JSON), help=f"Daily aggregate JSON output, default {DEFAULT_DAILY_JSON}.")
    parser.add_argument("--daily-csv", type=Path, default=Path(DEFAULT_DAILY_CSV), help=f"Daily aggregate CSV output, default {DEFAULT_DAILY_CSV}.")
    parser.add_argument("--html", type=Path, default=Path(DEFAULT_HTML), help=f"Static HTML dashboard output, default {DEFAULT_HTML}.")
    parser.add_argument("--infographic", type=Path, default=Path(DEFAULT_INFOGRAPHIC), help=f"Shareable PNG infographic output, default {DEFAULT_INFOGRAPHIC}. Requires matplotlib (run via uv).")
    parser.add_argument("--no-daily", action="store_true", help="Skip daily aggregate outputs.")
    parser.add_argument("--no-html", action="store_true", help="Skip static HTML dashboard output.")
    parser.add_argument("--no-infographic", action="store_true", help="Skip the PNG infographic output.")
    parser.add_argument("--daily-split-hosts", action="store_true", help="Keep hosts separate in daily aggregates instead of merging them.")
    parser.add_argument("--daily-split-accounts", action="store_true", help="Keep accounts separate in daily aggregates instead of merging them.")
    parser.add_argument("--ssh-timeout", type=int, default=8, help="SSH connect timeout in seconds.")
    parser.add_argument(
        "--ccusage-runner",
        choices=("auto", "ccusage", "npx"),
        default="auto",
        help="ccusage runner: auto uses npx ccusage@latest or installed ccusage.",
    )
    parser.add_argument(
        "--ccusage-package",
        default=DEFAULT_CCUSAGE_PACKAGE,
        help=f"npm spec for the npx runner, e.g. ccusage@17.2.0 to pin. Default {DEFAULT_CCUSAGE_PACKAGE}.",
    )
    parser.add_argument(
        "--timezone",
        default="",
        help="Timezone for ccusage daily buckets (e.g. Asia/Kolkata). Set it uniformly so days align across hosts; default is each machine's local timezone.",
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=4,
        help="Number of hosts to collect concurrently. Default 4; use 1 to collect sequentially.",
    )
    parser.add_argument("--json-only", action="store_true", help="Do not write CSV output.")
    parser.add_argument(
        "--collect-local",
        action="store_true",
        help="Collect this machine only and print the payload to stdout. Pair with --collect-output for push-style cron collection into a synced cache directory.",
    )
    parser.add_argument(
        "--collect-output",
        type=Path,
        help="With --collect-local: merge the collection into this ledger file (e.g. a synced cache dir's <label>.json) instead of printing JSON.",
    )
    parser.add_argument("--host-label", default="", help="Host label for --collect-local payloads. Defaults to the short hostname.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.collect_local:
        payload = collect_local(args.host_label, args.ccusage_runner, args.timezone, args.ccusage_package)
        if args.collect_output:
            merged = merge_payload(load_json(args.collect_output), payload)
            atomic_write_json(args.collect_output, merged)
            eprint(f"Merged {len(payload.get('records', []))} fresh records into {args.collect_output}")
        else:
            print(json.dumps(payload, sort_keys=True))
        return 0

    script_dir = Path(__file__).resolve().parent
    cache_dir = args.cache_dir or script_dir / DEFAULT_CACHE_DIR

    specs = default_specs(not args.no_local)
    inventory_path = args.inventory
    if inventory_path is None:
        inventory_path = script_dir / DEFAULT_INVENTORY
    if inventory_path.exists():
        specs.extend(parse_inventory(inventory_path))
    elif args.inventory:
        raise SystemExit(f"Inventory file not found: {inventory_path}")
    specs.extend(parse_host_arg(value) for value in args.host)

    # Later specs with the same label replace earlier ones, which lets inventory
    # override the implicit local host cleanly.
    deduped: dict[str, HostSpec] = {}
    for spec in specs:
        deduped[spec.label] = spec
    specs = list(deduped.values())
    if not specs:
        raise SystemExit("No hosts selected. Use --host, --inventory, or omit --no-local.")

    workers = max(1, min(args.parallel, len(specs)))
    results: list[tuple[dict[str, Any] | None, dict[str, Any]]] = []
    if workers == 1:
        results = [
            collect_host(spec, cache_dir, args.ssh_timeout, args.ccusage_runner, args.timezone, args.ccusage_package)
            for spec in specs
        ]
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [
                pool.submit(
                    collect_host, spec, cache_dir, args.ssh_timeout, args.ccusage_runner, args.timezone, args.ccusage_package
                )
                for spec in specs
            ]
            results = [future.result() for future in futures]

    host_payloads: list[tuple[HostSpec, dict[str, Any], bool]] = []
    statuses: list[dict[str, Any]] = []
    machines_seen: dict[str, str] = {}
    for spec, (payload, status) in zip(specs, results):
        if payload is not None:
            mid = str(payload.get("machine_id") or "")
            if mid and mid in machines_seen:
                status["status"] = "duplicate"
                status["message"] = f"same machine as {machines_seen[mid]}; skipped to avoid double counting"
                statuses.append(status)
                eprint(f"{spec.label}: skipped ({status['message']})")
                continue
            if mid:
                machines_seen[mid] = spec.label
        statuses.append(status)
        if payload is None:
            eprint(f"{spec.label}: no data ({status.get('message')})")
            continue
        cached = status.get("status") == "cached"
        label = "cached" if cached else "updated"
        eprint(f"{spec.label}: {label}, {len(payload.get('records', []))} records")
        host_payloads.append((spec, payload, cached))

    combined = build_combined(host_payloads, statuses)
    daily: list[dict[str, Any]] = []
    if not args.no_daily or not args.no_html:
        daily = aggregate_daily(
            combined["records"],
            split_hosts=args.daily_split_hosts,
            split_accounts=args.daily_split_accounts,
        )

    atomic_write_json(args.output_json, combined)
    if not args.json_only:
        write_csv(args.output_csv, combined["records"])
    if not args.no_daily:
        atomic_write_json(
            args.daily_json,
            {
                "schema_version": SCHEMA_VERSION,
                "generated_at": combined["generated_at"],
                "summary": summarize_records(daily),
                "records": daily,
            },
        )
        if not args.json_only:
            write_daily_csv(args.daily_csv, daily)
    if not args.no_html:
        write_html(args.html, combined, daily, cache_dir)
    infographic_written = False
    if not args.no_infographic:
        infographic_written = write_infographic(args.infographic, aggregate_daily(combined["records"]), combined["generated_at"])

    eprint(f"Wrote {args.output_json}")
    if not args.json_only:
        eprint(f"Wrote {args.output_csv}")
    if not args.no_daily:
        eprint(f"Wrote {args.daily_json}")
        if not args.json_only:
            eprint(f"Wrote {args.daily_csv}")
    if not args.no_html:
        eprint(f"Wrote {args.html}")
    if infographic_written:
        eprint(f"Wrote {args.infographic}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
