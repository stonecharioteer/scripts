#!/usr/bin/env python3
"""Collect local and remote AI coding-agent usage into JSON and CSV.

The collector intentionally records usage metadata only. It does not copy prompts,
responses, tool arguments, auth files, or raw transcripts into the output.
"""

from __future__ import annotations

import argparse
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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
DEFAULT_CACHE_DIR = ".ai-usage-cache"
DEFAULT_INVENTORY = "ai-usage.hosts"
DEFAULT_JSON = "ai-usage.json"
DEFAULT_CSV = "ai-usage.csv"
DEFAULT_DAILY_JSON = "ai-usage-daily.json"
DEFAULT_DAILY_CSV = "ai-usage-daily.csv"
DEFAULT_HTML = "ai-usage.html"


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
    if "openai" in haystack or normalized_model.startswith("gpt-") or normalized_model.startswith("o"):
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


def run_ccusage(mode: str, home: Path, extra_args: list[str] | None = None) -> dict[str, Any] | None:
    extra_args = extra_args or []
    command: list[str] | None = None
    if mode in {"auto", "npx"} and shutil.which("npx"):
        command = ["npx", "--yes", "ccusage@latest", "daily", "--json", *extra_args]
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


def collect_ccusage_unified(home: Path, mode: str = "auto") -> list[dict[str, Any]]:
    payload = run_ccusage(mode, home, ["--by-agent"])
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
                        total_tokens=as_int(agent_row.get("totalTokens")),
                        cost_usd=as_float(agent_row.get("totalCost")),
                        source_path="ccusage daily --json --by-agent",
                    )
                )
    return records


def collect_local(host_label: str = "", ccusage_runner: str = "auto") -> dict[str, Any]:
    home = Path.home()
    label = host_label or socket.gethostname().split(".", 1)[0]
    records: list[dict[str, Any]] = []
    try:
        records = collect_ccusage_unified(home, ccusage_runner)
    except Exception as exc:  # noqa: BLE001 - one host should not block cached/offline behavior elsewhere.
        eprint(f"Warning: collect_ccusage_unified failed: {exc}")

    records.sort(key=lambda item: (item.get("timestamp") or "", item.get("source") or "", item.get("session_id") or ""))
    return {
        "schema_version": SCHEMA_VERSION,
        "host": label,
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
    spec: HostSpec, timeout: int, ccusage_runner: str
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
    ]
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
    spec: HostSpec, cache_dir: Path, timeout: int, ccusage_runner: str
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    path = cache_path(cache_dir, spec.label)
    status = {
        "host": spec.label,
        "target": spec.target,
        "status": "unknown",
        "cache": str(path),
        "message": "",
    }

    if spec.is_local:
        payload = collect_local(spec.label, ccusage_runner)
        status["status"] = "updated"
        atomic_write_json(path, payload)
        return payload, status

    payload, error = run_remote_collect(spec, timeout, ccusage_runner)
    if payload is not None:
        status["status"] = "updated"
        atomic_write_json(path, payload)
        return payload, status

    cached = load_json(path)
    if cached is not None:
        status["status"] = "cached"
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
                "sessions": set(),
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
        if record.get("session_id"):
            session_host = str(record.get("host") or record.get("host_label") or "")
            bucket["sessions"].add(f"{session_host}:{record.get('session_id')}")
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
        row["sessions"] = len(bucket["sessions"])
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
        "sessions",
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


def add_to_bucket(bucket: dict[str, Any], record: dict[str, Any]) -> None:
    bucket["records"] = as_int(bucket.get("records")) + as_int(record.get("records", 1))
    bucket["sessions"] = as_int(bucket.get("sessions")) + as_int(record.get("sessions", 0))
    for field in (
        "input_tokens",
        "output_tokens",
        "cache_creation_tokens",
        "cache_read_tokens",
        "reasoning_tokens",
        "total_tokens",
    ):
        bucket[field] = as_int(bucket.get(field)) + as_int(record.get(field))
    bucket["cost_usd"] = as_float(bucket.get("cost_usd")) + as_float(record.get("cost_usd"))


def dashboard_payload(combined: dict[str, Any], daily: list[dict[str, Any]]) -> dict[str, Any]:
    day_buckets: dict[str, dict[str, Any]] = {}
    model_buckets: dict[tuple[str, str, str], dict[str, Any]] = {}
    service_buckets: dict[tuple[str, str], dict[str, Any]] = {}
    hosts_seen: set[str] = set()
    accounts_seen: set[str] = set()

    for record in daily:
        date = str(record.get("date") or "")
        if date:
            day_bucket = day_buckets.setdefault(
                date,
                {
                    "date": date,
                    "records": 0,
                    "sessions": 0,
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "cache_creation_tokens": 0,
                    "cache_read_tokens": 0,
                    "reasoning_tokens": 0,
                    "total_tokens": 0,
                    "cost_usd": 0.0,
                },
            )
            add_to_bucket(day_bucket, record)

        service = str(record.get("service") or record.get("source") or "unknown")
        source = str(record.get("source") or "unknown")
        provider = str(record.get("provider") or "")
        model = str(record.get("model") or "unknown")
        model_key = (service, provider, model)
        model_bucket = model_buckets.setdefault(
            model_key,
            {
                "service": service,
                "provider": provider,
                "model": model,
                "records": 0,
                "sessions": 0,
                "days": set(),
                "sources": set(),
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
        add_to_bucket(model_bucket, record)
        if date:
            model_bucket["days"].add(date)
        model_bucket["sources"].add(source)

        for host in str(record.get("hosts") or record.get("host") or "").split(","):
            if host and host != "all":
                model_bucket["hosts"].add(host)
                hosts_seen.add(host)
        for account in str(record.get("accounts") or record.get("account_label") or "").split(","):
            if account and account != "all":
                model_bucket["accounts"].add(account)
                accounts_seen.add(account)

        service_key = (source, service)
        service_bucket = service_buckets.setdefault(
            service_key,
            {
                "source": source,
                "service": service,
                "records": 0,
                "sessions": 0,
                "input_tokens": 0,
                "output_tokens": 0,
                "cache_creation_tokens": 0,
                "cache_read_tokens": 0,
                "reasoning_tokens": 0,
                "total_tokens": 0,
                "cost_usd": 0.0,
            },
        )
        add_to_bucket(service_bucket, record)

    days = sorted(day_buckets.values(), key=lambda item: item["date"])
    models = []
    for bucket in model_buckets.values():
        item = dict(bucket)
        item["days"] = len(bucket["days"])
        item["sources"] = sorted(bucket["sources"])
        item["hosts"] = sorted(bucket["hosts"])
        item["accounts"] = sorted(bucket["accounts"])
        item["cost_usd"] = round(item["cost_usd"], 6)
        models.append(item)
    models.sort(key=lambda item: item["total_tokens"], reverse=True)

    services = []
    for bucket in service_buckets.values():
        item = dict(bucket)
        item["cost_usd"] = round(item["cost_usd"], 6)
        services.append(item)
    services.sort(key=lambda item: item["total_tokens"], reverse=True)

    totals = {
        "records": sum(as_int(day.get("records")) for day in days),
        "sessions": sum(as_int(day.get("sessions")) for day in days),
        "input_tokens": sum(as_int(day.get("input_tokens")) for day in days),
        "output_tokens": sum(as_int(day.get("output_tokens")) for day in days),
        "cache_creation_tokens": sum(as_int(day.get("cache_creation_tokens")) for day in days),
        "cache_read_tokens": sum(as_int(day.get("cache_read_tokens")) for day in days),
        "reasoning_tokens": sum(as_int(day.get("reasoning_tokens")) for day in days),
        "total_tokens": sum(as_int(day.get("total_tokens")) for day in days),
        "cost_usd": round(sum(as_float(day.get("cost_usd")) for day in days), 6),
        "active_models": len(models),
        "latest_date": days[-1]["date"] if days else "",
        "first_date": days[0]["date"] if days else "",
        "hosts": len(hosts_seen),
        "accounts": len(accounts_seen),
    }

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
                "sessions": as_int(record.get("sessions")),
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
        "summary": totals,
        "days": days,
        "models": models[:30],
        "services": services,
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
.rangebar { display: flex; align-items: center; justify-content: space-between; gap: 18px; padding: 16px 0; border-bottom: 1px solid var(--rule); }
.presets { display: flex; flex-wrap: wrap; gap: 8px; }
.rangebar button, .rangebar input, .rangebar select { color: var(--ink); background: var(--paper); border: 1px solid var(--rule); padding: 8px 10px; font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.rangebar select { min-width: 180px; max-height: 120px; }
.rangebar button { cursor: pointer; text-transform: uppercase; letter-spacing: .08em; }
.rangebar button.active, .rangebar button:hover, .rangebar input:focus, .rangebar select:focus { border-color: var(--gold); outline: 0; }
.custom-range { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
.range-readout { color: var(--muted); font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; margin-left: 6px; }
.grid { display: grid; grid-template-columns: minmax(0, 1.35fr) minmax(320px, .65fr); gap: 28px; margin-top: 30px; align-items: start; }
.panel { border-top: 1px solid var(--rule-strong); padding-top: 14px; min-width: 0; }
.flow-panel { overflow: hidden; padding-bottom: 8px; }
.panel h2 { margin: 0 0 14px; font-size: 22px; font-weight: 500; letter-spacing: -.02em; }
.chart { display: flex; align-items: flex-end; gap: 3px; height: 230px; padding: 10px 0 0; border-bottom: 1px solid var(--rule); }
.day { flex: 1 1 3px; min-width: 3px; height: 100%; display: flex; flex-direction: column-reverse; justify-content: flex-start; opacity: .94; }
.day:hover { outline: 1px solid var(--gold); outline-offset: 2px; opacity: 1; }
.seg.in { background: var(--in); } .seg.out { background: var(--out); } .seg.cw { background: var(--cw); } .seg.cr { background: var(--cr); } .seg.rz { background: var(--rz); }
.chart-axis { position: relative; height: 22px; margin: 8px 0 12px; overflow: hidden; color: var(--muted); font: 10px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.axis-tick { position: absolute; transform: translateX(-50%); white-space: nowrap; }
.axis-tick:first-child { transform: translateX(0); }
.axis-tick:last-child { transform: translateX(-100%); }
.legend { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 10px; color: var(--muted); font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.swatch { display: inline-block; width: 10px; height: 10px; margin-right: 5px; vertical-align: -1px; }
.costline { display: block; width: 100%; height: 74px; margin-top: 10px; overflow: hidden; }
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
table { width: 100%; border-collapse: collapse; font: 13px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
th, td { padding: 10px 8px; border-bottom: 1px solid var(--rule); vertical-align: top; }
th { text-align: left; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.model-name { color: var(--ink); font-family: Georgia, "Times New Roman", serif; font-size: 15px; }
.meta { color: var(--muted); font-size: 11px; margin-top: 3px; }
.hosts { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 12px; }
.host { border: 1px solid var(--rule); padding: 7px 9px; font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: var(--muted); }
.host.updated .dot { color: var(--green); } .host.cached .dot { color: var(--gold); } .host.missing .dot { color: var(--red); }
.note { color: var(--muted); font-size: 13px; line-height: 1.45; margin-top: 12px; }
@media (max-width: 900px) { .mast, .grid, .rangebar, .heatmaps { display: block; } .heatmap-wrap { margin-top: 20px; } .custom-range { margin-top: 12px; } .generated { text-align: left; margin-top: 14px; } .stats { grid-template-columns: repeat(2, 1fr); } .stat:nth-child(2n) { border-right: 0; } }
</style>
</head>
<body>
<main>
  <header class="mast">
    <div><div class="kicker">Personal instrument panel</div><h1>AI Usage<br>Ledger</h1></div>
    <div class="generated"><div class="label">Generated</div><div id="generated"></div><p class="note">Accounts are merged by default. Cost is reported only when the source provides it.</p></div>
  </header>
  <section class="stats" id="stats" aria-label="Summary statistics"></section>
  <section class="rangebar" aria-label="Date range selector">
    <div class="presets" id="presets">
      <button type="button" data-range="all" class="active">All</button>
      <button type="button" data-range="7">7D</button>
      <button type="button" data-range="30">30D</button>
      <button type="button" data-range="90">90D</button>
      <button type="button" data-range="365">1Y</button>
    </div>
    <div class="custom-range">
      <span class="label">From</span><input id="fromDate" type="date">
      <span class="label">To</span><input id="toDate" type="date">
      <span class="label">Hosts</span><select id="hostFilter" multiple size="4"><option value="all" selected>All hosts</option></select>
      <span class="range-readout" id="rangeReadout"></span>
    </div>
  </section>
  <section class="grid">
    <div class="panel flow-panel">
      <h2>Daily Token Flow</h2>
      <div id="chart" class="chart" aria-label="Daily token bars"></div>
      <div id="chartAxis" class="chart-axis" aria-label="Daily token date axis"></div>
      <div class="legend">
        <span><i class="swatch" style="background:var(--in)"></i>input</span>
        <span><i class="swatch" style="background:var(--out)"></i>output</span>
        <span><i class="swatch" style="background:var(--cw)"></i>cache write</span>
        <span><i class="swatch" style="background:var(--cr)"></i>cache read</span>
        <span><i class="swatch" style="background:var(--rz)"></i>reasoning</span>
      </div>
      <svg id="costline" class="costline" viewBox="0 0 1000 74" preserveAspectRatio="none" aria-label="Daily cost line"></svg>
    </div>
    <aside class="panel">
      <h2>Service Mix</h2>
      <div id="servicebar" class="servicebar"></div>
      <div id="services" class="service-list"></div>
      <div class="tokenmax">
        <h2>Tokenmaxxing</h2>
        <div id="tokenmax" class="tokenmax-grid"></div>
        <div id="tokenmaxLine" class="tokenmax-line"></div>
      </div>
      <p class="note">The service field is inferred from provider/model names, so Grok used through pi is counted as Grok while retaining source=pi.</p>
    </aside>
  </section>
  <section class="heatmaps" aria-label="Daily heatmaps">
    <div class="heatmap-wrap">
      <div class="heatmap-head"><div class="heatmap-title">Daily Token Measure</div><div id="tokenHeatMax" class="heatmap-max"></div></div>
      <div class="heatmap-scroll"><div id="tokenHeatMonths" class="heat-months"></div><div id="tokenHeatmap" class="heatmap"></div></div>
      <div class="heatmap-legend"><span>less</span><i class="cell"></i><i class="cell l1"></i><i class="cell l2"></i><i class="cell l3"></i><i class="cell l4"></i><span>more</span></div>
    </div>
    <div class="heatmap-wrap">
      <div class="heatmap-head"><div class="heatmap-title">Daily Cost Measure</div><div id="costHeatMax" class="heatmap-max"></div></div>
      <div class="heatmap-scroll"><div id="costHeatMonths" class="heat-months"></div><div id="costHeatmap" class="heatmap"></div></div>
      <div class="heatmap-legend"><span>less</span><i class="cell cost"></i><i class="cell cost l1"></i><i class="cell cost l2"></i><i class="cell cost l3"></i><i class="cell cost l4"></i><span>more</span></div>
    </div>
  </section>
  <section class="panel" style="margin-top:42px">
    <h2>Top Models</h2>
    <table>
      <thead><tr><th>Model</th><th class="num">Days</th><th class="num">Input</th><th class="num">Output</th><th class="num">Cache</th><th class="num">Total</th><th class="num">Cost</th></tr></thead>
      <tbody id="models"></tbody>
    </table>
  </section>
  <section class="panel" style="margin-top:30px">
    <h2>Host Cache Status</h2>
    <div id="hosts" class="hosts"></div>
  </section>
</main>
<div id="hovercard" class="hovercard"></div>
<script id="usage-data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('usage-data').textContent);
const fields = ['input_tokens','output_tokens','cache_creation_tokens','cache_read_tokens','reasoning_tokens'];
const segClass = ['in','out','cw','cr','rz'];
let state = { from: null, to: null, preset: 'all', hosts: ['all'] };
function fmt(n) { n = Number(n || 0); if (n >= 1e9) return (n/1e9).toFixed(1)+'B'; if (n >= 1e6) return (n/1e6).toFixed(1)+'M'; if (n >= 1e3) return (n/1e3).toFixed(0)+'k'; return String(Math.round(n)); }
function usd(n) { return '$' + Number(n || 0).toFixed(2); }
function pct(n) { return Number(n || 0).toFixed(1) + '%'; }
function node(tag, cls, text) { const el = document.createElement(tag); if (cls) el.className = cls; if (text !== undefined) el.textContent = text; return el; }
function clear(id) { const el = document.getElementById(id); while (el.firstChild) el.removeChild(el.firstChild); return el; }
function addTotals(target, row) { fields.concat(['total_tokens']).forEach(f => target[f] = Number(target[f] || 0) + Number(row[f] || 0)); target.cost_usd = Number(target.cost_usd || 0) + Number(row.cost_usd || 0); target.records = Number(target.records || 0) + Number(row.records || 0); target.sessions = Number(target.sessions || 0) + Number(row.sessions || 0); }
function dateAdd(date, delta) { const d = new Date(date + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + delta); return d.toISOString().slice(0,10); }
function availableDates() { return [...new Set((D.rows || []).map(r => r.date).filter(Boolean))].sort(); }
function rowHosts(row) { return (row.host || row.hosts || '').split(',').map(v => v.trim()).filter(Boolean); }
function selectedRows() { return (D.rows || []).filter(r => {
  const hostOk = state.hosts.includes('all') || state.hosts.length === 0 || rowHosts(r).some(host => state.hosts.includes(host));
  return (!state.from || r.date >= state.from) && (!state.to || r.date <= state.to) && hostOk;
}); }
function derive(rows) {
  const daysMap = new Map(), modelsMap = new Map(), servicesMap = new Map();
  rows.forEach(row => {
    if (!row.date) return;
    if (!daysMap.has(row.date)) daysMap.set(row.date, {date: row.date, records:0, sessions:0, input_tokens:0, output_tokens:0, cache_creation_tokens:0, cache_read_tokens:0, reasoning_tokens:0, total_tokens:0, cost_usd:0});
    addTotals(daysMap.get(row.date), row);
    const modelKey = [row.service, row.provider, row.model].join('\u0000');
    if (!modelsMap.has(modelKey)) modelsMap.set(modelKey, {service: row.service, provider: row.provider, model: row.model, days: new Set(), sources: new Set(), hosts: new Set(), accounts: new Set(), records:0, sessions:0, input_tokens:0, output_tokens:0, cache_creation_tokens:0, cache_read_tokens:0, reasoning_tokens:0, total_tokens:0, cost_usd:0});
    const model = modelsMap.get(modelKey); addTotals(model, row); model.days.add(row.date); model.sources.add(row.source); (row.hosts || '').split(',').filter(Boolean).forEach(v => model.hosts.add(v)); (row.accounts || '').split(',').filter(Boolean).forEach(v => model.accounts.add(v));
    const serviceKey = [row.source, row.service].join('\u0000');
    if (!servicesMap.has(serviceKey)) servicesMap.set(serviceKey, {source: row.source, service: row.service, records:0, sessions:0, input_tokens:0, output_tokens:0, cache_creation_tokens:0, cache_read_tokens:0, reasoning_tokens:0, total_tokens:0, cost_usd:0});
    addTotals(servicesMap.get(serviceKey), row);
  });
  const days = [...daysMap.values()].sort((a,b) => a.date.localeCompare(b.date));
  const models = [...modelsMap.values()].map(m => ({...m, days: m.days.size, sources: [...m.sources].sort(), hosts: [...m.hosts].sort(), accounts: [...m.accounts].sort()})).sort((a,b) => b.total_tokens - a.total_tokens);
  const services = [...servicesMap.values()].sort((a,b) => b.total_tokens - a.total_tokens);
  const summary = {records:0, sessions:0, input_tokens:0, output_tokens:0, cache_creation_tokens:0, cache_read_tokens:0, reasoning_tokens:0, total_tokens:0, cost_usd:0, active_models: models.length, first_date: days[0]?.date || '', latest_date: days.at(-1)?.date || ''};
  days.forEach(day => addTotals(summary, day));
  return {days, models, services, summary};
}
function renderStats(summary) {
  document.getElementById('generated').textContent = D.generated_at || 'unknown';
  const stats = [
    ['total', fmt(summary.total_tokens)], ['input', fmt(summary.input_tokens)], ['output', fmt(summary.output_tokens)],
    ['cache read', fmt(summary.cache_read_tokens)], ['cache write', fmt(summary.cache_creation_tokens)], ['cost', usd(summary.cost_usd)],
    ['models', fmt(summary.active_models)], ['latest', summary.latest_date || 'n/a']
  ];
  const root = clear('stats');
  stats.forEach(([label, value]) => { const box = node('div','stat'); box.append(node('div','label',label)); box.append(node('div','value',value)); root.append(box); });
}
function dateLabel(date) {
  const parsed = new Date(date + 'T00:00:00Z');
  return parsed.toLocaleDateString('en', {month: 'short', day: 'numeric', timeZone: 'UTC'});
}
function renderChartAxis(days) {
  const axis = clear('chartAxis');
  if (!days.length) return;
  const count = Math.min(7, days.length);
  const used = new Set();
  for (let i = 0; i < count; i += 1) {
    const index = count === 1 ? 0 : Math.round(i * (days.length - 1) / (count - 1));
    if (used.has(index)) continue;
    used.add(index);
    const tick = node('span', 'axis-tick', dateLabel(days[index].date));
    tick.style.left = days.length === 1 ? '0%' : `${index / (days.length - 1) * 100}%`;
    axis.append(tick);
  }
}
function renderChart(days) {
  const root = clear('chart');
  const max = Math.max(1, ...days.map(d => Number(d.total_tokens || 0)));
  days.forEach(d => {
    const day = node('div','day');
    day.title = `${d.date} · ${fmt(d.total_tokens)} tokens · ${usd(d.cost_usd)}`;
    fields.forEach((f, idx) => { const seg = node('div', 'seg ' + segClass[idx]); const height = Math.max(0, Number(d[f] || 0) / max * 100); seg.style.height = height ? Math.max(.8, height) + '%' : '0'; day.append(seg); });
    root.append(day);
  });
  renderChartAxis(days);
}
function renderCost(days) {
  const svg = clear('costline');
  const max = Math.max(0, ...days.map(d => Number(d.cost_usd || 0)));
  if (!days.length || !max) { const t = document.createElementNS('http://www.w3.org/2000/svg','text'); t.setAttribute('x','0'); t.setAttribute('y','38'); t.setAttribute('fill','#9d927f'); t.textContent = 'No reported cost data'; svg.append(t); return; }
  const points = days.map((d, i) => { const x = days.length === 1 ? 0 : i * (1000 / (days.length - 1)); const y = 62 - (Number(d.cost_usd || 0) / max * 54); return `${x.toFixed(1)},${y.toFixed(1)}`; }).join(' ');
  const line = document.createElementNS('http://www.w3.org/2000/svg','polyline'); line.setAttribute('points', points); line.setAttribute('fill','none'); line.setAttribute('stroke','#d8a33d'); line.setAttribute('stroke-width','3'); line.setAttribute('vector-effect','non-scaling-stroke'); svg.append(line);
  const t = document.createElementNS('http://www.w3.org/2000/svg','text'); t.setAttribute('x','1000'); t.setAttribute('y','12'); t.setAttribute('text-anchor','end'); t.setAttribute('fill','#d8a33d'); t.textContent = 'max ' + usd(max); svg.append(t);
}
function renderServices(services) {
  const palette = ['#d8a33d','#8fb8b6','#577f86','#7d6c9f','#d66b55','#77b77a','#ede4d1'];
  const total = Math.max(1, services.reduce((sum, row) => sum + Number(row.total_tokens || 0), 0));
  const bar = clear('servicebar');
  const list = clear('services');
  services.forEach((row, idx) => {
    const color = palette[idx % palette.length];
    const bit = node('div','servicebit'); bit.style.width = (Number(row.total_tokens || 0) / total * 100) + '%'; bit.style.background = color; bit.title = `${row.source}/${row.service} · ${fmt(row.total_tokens)}`; bar.append(bit);
    const item = node('div','service-row'); const left = node('span','',`${row.source}/${row.service}`); left.style.color = color; item.append(left); item.append(node('span','',`${fmt(row.total_tokens)} · ${usd(row.cost_usd)}`)); list.append(item);
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
    const day = byDate.get(date) || {date, total_tokens: 0, cost_usd: 0, input_tokens: 0, output_tokens: 0, cache_creation_tokens: 0, cache_read_tokens: 0, reasoning_tokens: 0};
    const value = Number(day[field] || 0);
    const level = heatLevel(value, max);
    const cell = node('i', `cell${costMode ? ' cost' : ''}${level ? ' l' + level : ''}`);
    const lines = costMode
      ? [date, `${formatter(value)} reported cost`, `${fmt(day.total_tokens || 0)} tokens`]
      : [date, `${formatter(value)} total tokens`, `${fmt(day.input_tokens || 0)} in · ${fmt(day.output_tokens || 0)} out`, `${fmt((day.cache_creation_tokens || 0) + (day.cache_read_tokens || 0))} cache · ${usd(day.cost_usd || 0)}`];
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
function renderModels(models) {
  const body = clear('models');
  models.slice(0, 30).forEach(row => {
    const tr = document.createElement('tr');
    const name = document.createElement('td');
    name.title = `sources: ${(row.sources || []).join(', ')}; hosts: ${(row.hosts || []).join(', ')}; accounts: ${(row.accounts || []).join(', ')}`;
    name.append(node('div','model-name',row.model || 'unknown'));
    name.append(node('div','meta',routeSummary(row)));
    tr.append(name);
    [['days',fmt(row.days)],['input',fmt(row.input_tokens)],['output',fmt(row.output_tokens)],['cache',fmt(Number(row.cache_creation_tokens || 0)+Number(row.cache_read_tokens || 0))],['total',fmt(row.total_tokens)],['cost',usd(row.cost_usd)]].forEach(([, value]) => tr.append(node('td','num',value)));
    body.append(tr);
  });
}
function renderHosts() {
  const root = clear('hosts');
  (D.hosts || []).forEach(row => { const status = row.status || 'missing'; const item = node('div','host '+status); item.title = row.message || row.cache || ''; item.append(node('span','dot', status === 'updated' ? '● ' : status === 'cached' ? '◐ ' : '○ ')); item.append(document.createTextNode(`${row.host || 'host'} · ${status}`)); root.append(item); });
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
  const select = document.getElementById('hostFilter');
  const hosts = [...new Set((D.rows || []).flatMap(rowHosts))].sort();
  hosts.forEach(host => select.append(node('option', '', host)));
}
function applyHostFilter() {
  const select = document.getElementById('hostFilter');
  const values = [...select.selectedOptions].map(option => option.value);
  if (values.includes('all') || values.length === 0) {
    state.hosts = ['all'];
    [...select.options].forEach(option => option.selected = option.value === 'all');
  } else {
    state.hosts = values;
  }
  renderAll();
}
function renderAll() {
  const derived = derive(selectedRows());
  renderStats(derived.summary); renderChart(derived.days); renderCost(derived.days); renderServices(derived.services); renderTokenmax(derived.days, derived.summary); renderHeatmaps(derived.days); renderModels(derived.models); renderHosts();
  const readout = document.getElementById('rangeReadout');
  const hostText = state.hosts.includes('all') ? 'all hosts' : state.hosts.join(', ');
  readout.textContent = `${derived.days.length} days · ${derived.summary.first_date || 'n/a'} to ${derived.summary.latest_date || 'n/a'} · ${hostText}`;
}
document.querySelectorAll('#presets button').forEach(button => button.addEventListener('click', () => applyRange(button.dataset.range)));
document.getElementById('fromDate').addEventListener('change', applyCustomRange);
document.getElementById('toDate').addEventListener('change', applyCustomRange);
document.getElementById('hostFilter').addEventListener('change', applyHostFilter);
populateHostFilter();
applyRange('all');
</script>
</body>
</html>
"""


def write_html(path: Path, combined: dict[str, Any], daily: list[dict[str, Any]]) -> None:
    dashboard_daily = aggregate_daily(combined["records"], split_hosts=True, split_accounts=False)
    payload = dashboard_payload(combined, dashboard_daily or daily)
    rendered = HTML_TEMPLATE.replace("__DATA__", json_for_script(payload))
    rendered = rendered.replace("AI Usage Ledger", html_escape("AI Usage Ledger"), 1)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(rendered, encoding="utf-8")
    tmp.replace(path)


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
    parser.add_argument("--no-daily", action="store_true", help="Skip daily aggregate outputs.")
    parser.add_argument("--no-html", action="store_true", help="Skip static HTML dashboard output.")
    parser.add_argument("--daily-split-hosts", action="store_true", help="Keep hosts separate in daily aggregates instead of merging them.")
    parser.add_argument("--daily-split-accounts", action="store_true", help="Keep accounts separate in daily aggregates instead of merging them.")
    parser.add_argument("--ssh-timeout", type=int, default=8, help="SSH connect timeout in seconds.")
    parser.add_argument(
        "--ccusage-runner",
        choices=("auto", "ccusage", "npx"),
        default="auto",
        help="ccusage runner: auto uses npx ccusage@latest or installed ccusage.",
    )
    parser.add_argument("--json-only", action="store_true", help="Do not write CSV output.")
    parser.add_argument("--collect-local", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--host-label", default="", help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.collect_local:
        print(json.dumps(collect_local(args.host_label, args.ccusage_runner), sort_keys=True))
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

    host_payloads: list[tuple[HostSpec, dict[str, Any], bool]] = []
    statuses: list[dict[str, Any]] = []
    for spec in specs:
        payload, status = collect_host(spec, cache_dir, args.ssh_timeout, args.ccusage_runner)
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
        write_html(args.html, combined, daily)

    eprint(f"Wrote {args.output_json}")
    if not args.json_only:
        eprint(f"Wrote {args.output_csv}")
    if not args.no_daily:
        eprint(f"Wrote {args.daily_json}")
        if not args.json_only:
            eprint(f"Wrote {args.daily_csv}")
    if not args.no_html:
        eprint(f"Wrote {args.html}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
