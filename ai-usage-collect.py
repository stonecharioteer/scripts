#!/usr/bin/env python3
"""Collect local and remote AI coding-agent usage into JSON and CSV.

The collector intentionally records usage metadata only. It does not copy prompts,
responses, tool arguments, auth files, or raw transcripts into the output.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import glob
import html
import json
import os
import platform
import re
import shlex
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1
DEFAULT_CACHE_DIR = ".ai-usage-cache"
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


def normalize_timestamp(value: Any) -> str:
    if value is None or value == "":
        return ""
    if isinstance(value, (int, float)):
        seconds = float(value)
        if seconds > 10_000_000_000:
            seconds = seconds / 1000.0
        try:
            return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        except (OSError, OverflowError, ValueError):
            return ""
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return ""
        if text.isdigit():
            return normalize_timestamp(int(text))
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            parsed = dt.datetime.fromisoformat(text)
        except ValueError:
            return value.strip()
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    return ""


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


def get_nested(mapping: dict[str, Any], *keys: str) -> Any:
    current: Any = mapping
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def rel_home(path: Path) -> str:
    try:
        return "~/" + str(path.expanduser().resolve().relative_to(Path.home().resolve()))
    except ValueError:
        return str(path)


def project_from_path(path: Path, marker: str) -> str:
    parts = path.parts
    try:
        idx = parts.index(marker)
    except ValueError:
        return ""
    if idx + 1 < len(parts):
        return parts[idx + 1]
    return ""


def infer_service(source: str, provider: str, model: str) -> str:
    haystack = f"{source} {provider} {model}".lower()
    if "grok" in haystack or "xai" in haystack or "x.ai" in haystack:
        return "grok"
    if "claude" in haystack or "anthropic" in haystack:
        return "claude"
    if "codex" in haystack:
        return "codex"
    if "openai" in haystack or model.startswith("gpt-") or model.startswith("o"):
        return "openai"
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


def iter_jsonl(paths: Iterable[Path]) -> Iterable[tuple[Path, dict[str, Any]]]:
    for path in paths:
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        value = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(value, dict):
                        yield path, value
        except OSError:
            continue


def collect_claude_raw(home: Path) -> list[dict[str, Any]]:
    roots = [home / ".claude" / "projects", home / ".claude" / "transcripts"]
    paths: list[Path] = []
    for root in roots:
        if root.exists():
            paths.extend(root.rglob("*.jsonl"))

    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for path, event in iter_jsonl(paths):
        message = event.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        usage = message.get("usage")
        if not isinstance(usage, dict):
            continue
        record_id = str(event.get("uuid") or event.get("requestId") or message.get("id") or f"{path}:{len(records)}")
        if record_id in seen:
            continue
        seen.add(record_id)
        records.append(
            new_record(
                source="claude_code",
                timestamp=normalize_timestamp(event.get("timestamp")),
                session_id=str(event.get("sessionId") or path.stem),
                project=project_from_path(path, "projects"),
                model=str(message.get("model") or ""),
                input_tokens=as_int(usage.get("input_tokens")),
                output_tokens=as_int(usage.get("output_tokens")),
                cache_creation_tokens=as_int(usage.get("cache_creation_input_tokens")),
                cache_read_tokens=as_int(usage.get("cache_read_input_tokens")),
                source_path=rel_home(path),
            )
        )
    return records


def run_ccusage(mode: str, home: Path) -> dict[str, Any] | None:
    if mode == "raw":
        return None
    command: list[str] | None = None
    if mode in {"auto", "ccusage"} and shutil.which("ccusage"):
        command = ["ccusage", "daily", "--json"]
    elif mode in {"auto", "npx"} and shutil.which("npx"):
        command = ["npx", "--yes", "ccusage@latest", "daily", "--json"]
    if command is None:
        return None

    env = os.environ.copy()
    env.setdefault("HOME", str(home))
    try:
        completed = subprocess.run(
            command,
            text=True,
            capture_output=True,
            timeout=90,
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


def collect_claude_ccusage(home: Path, mode: str) -> list[dict[str, Any]]:
    payload = run_ccusage(mode, home)
    if payload is None:
        return []
    daily = payload.get("daily")
    if not isinstance(daily, list):
        return []

    records: list[dict[str, Any]] = []
    for day in daily:
        if not isinstance(day, dict):
            continue
        date = str(day.get("date") or "")
        if not date:
            continue
        timestamp = f"{date}T00:00:00Z"
        breakdowns = day.get("modelBreakdowns")
        if isinstance(breakdowns, list) and breakdowns:
            for breakdown in breakdowns:
                if not isinstance(breakdown, dict):
                    continue
                model = str(breakdown.get("modelName") or "")
                records.append(
                    new_record(
                        source="claude_code",
                        timestamp=timestamp,
                        session_id=f"ccusage:{date}:{model}",
                        model=model,
                        input_tokens=as_int(breakdown.get("inputTokens")),
                        output_tokens=as_int(breakdown.get("outputTokens")),
                        cache_creation_tokens=as_int(breakdown.get("cacheCreationTokens")),
                        cache_read_tokens=as_int(breakdown.get("cacheReadTokens")),
                        cost_usd=as_float(breakdown.get("cost")),
                        source_path="ccusage daily --json",
                    )
                )
        else:
            records.append(
                new_record(
                    source="claude_code",
                    timestamp=timestamp,
                    session_id=f"ccusage:{date}",
                    model=", ".join(str(model) for model in day.get("modelsUsed", []) if model),
                    input_tokens=as_int(day.get("inputTokens")),
                    output_tokens=as_int(day.get("outputTokens")),
                    cache_creation_tokens=as_int(day.get("cacheCreationTokens")),
                    cache_read_tokens=as_int(day.get("cacheReadTokens")),
                    total_tokens=as_int(day.get("totalTokens")),
                    cost_usd=as_float(day.get("totalCost")),
                    source_path="ccusage daily --json",
                )
            )
    return records


def collect_claude(home: Path, cost_source: str = "auto") -> list[dict[str, Any]]:
    if cost_source != "raw":
        records = collect_claude_ccusage(home, cost_source)
        if records:
            return records
    return collect_claude_raw(home)


def collect_pi(home: Path) -> list[dict[str, Any]]:
    root = home / ".pi" / "agent" / "sessions"
    if not root.exists():
        return []

    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for path, event in iter_jsonl(root.rglob("*.jsonl")):
        message = event.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        usage = message.get("usage")
        if not isinstance(usage, dict):
            continue
        record_id = str(event.get("id") or message.get("responseId") or f"{path}:{len(records)}")
        if record_id in seen:
            continue
        seen.add(record_id)
        cost = usage.get("cost") if isinstance(usage.get("cost"), dict) else {}
        records.append(
            new_record(
                source="pi",
                timestamp=normalize_timestamp(event.get("timestamp") or message.get("timestamp")),
                session_id=path.stem.split("_", 1)[-1],
                project=project_from_path(path, "sessions"),
                provider=str(message.get("provider") or message.get("api") or ""),
                model=str(message.get("model") or ""),
                input_tokens=as_int(usage.get("input") or usage.get("input_tokens")),
                output_tokens=as_int(usage.get("output") or usage.get("output_tokens")),
                cache_creation_tokens=as_int(usage.get("cacheWrite") or usage.get("cache_creation_input_tokens")),
                cache_read_tokens=as_int(usage.get("cacheRead") or usage.get("cache_read_input_tokens")),
                reasoning_tokens=as_int(usage.get("reasoning") or usage.get("reasoning_tokens")),
                total_tokens=as_int(usage.get("totalTokens") or usage.get("total_tokens")),
                cost_usd=as_float(cost.get("total") if isinstance(cost, dict) else 0),
                source_path=rel_home(path),
            )
        )
    return records


def codex_session_id(path: Path) -> str:
    match = re.search(r"rollout-[^-]+-[^-]+-(.+)\.jsonl$", path.name)
    return match.group(1) if match else path.stem


def collect_codex(home: Path) -> list[dict[str, Any]]:
    roots = [home / ".codex" / "sessions", home / ".codex" / "archived_sessions"]
    records: list[dict[str, Any]] = []

    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*.jsonl"):
            latest_usage: dict[str, Any] | None = None
            latest_ts = ""
            latest_model = ""
            plan_type = ""
            for _, event in iter_jsonl([path]):
                payload = event.get("payload")
                if isinstance(payload, dict) and event.get("type") == "turn_context":
                    latest_model = str(payload.get("model") or latest_model)
                if not isinstance(payload, dict) or payload.get("type") != "token_count":
                    continue
                info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
                usage = info.get("total_token_usage") if isinstance(info, dict) else None
                if not isinstance(usage, dict):
                    continue
                latest_usage = usage
                latest_ts = normalize_timestamp(event.get("timestamp"))
                rate_limits = payload.get("rate_limits")
                if isinstance(rate_limits, dict):
                    plan_type = str(rate_limits.get("plan_type") or plan_type)
            if latest_usage:
                records.append(
                    new_record(
                        source="codex",
                        timestamp=latest_ts,
                        session_id=codex_session_id(path),
                        account=plan_type,
                        model=latest_model,
                        input_tokens=as_int(latest_usage.get("input_tokens")),
                        output_tokens=as_int(latest_usage.get("output_tokens")),
                        cache_read_tokens=as_int(latest_usage.get("cached_input_tokens")),
                        reasoning_tokens=as_int(latest_usage.get("reasoning_output_tokens")),
                        total_tokens=as_int(latest_usage.get("total_tokens")),
                        source_path=rel_home(path),
                    )
                )
    return records


def sqlite_copy(path: Path) -> Path | None:
    if not path.exists():
        return None
    temp = tempfile.NamedTemporaryFile(prefix="ai-usage-sqlite-", suffix=".db", delete=False)
    temp.close()
    temp_path = Path(temp.name)
    try:
        source = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        dest = sqlite3.connect(temp_path)
        with dest:
            source.backup(dest)
        source.close()
        dest.close()
        return temp_path
    except sqlite3.Error:
        try:
            temp_path.unlink()
        except OSError:
            pass
        return None


def parse_opencode_model(raw: Any) -> tuple[str, str]:
    if not raw:
        return "", ""
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return raw, ""
    elif isinstance(raw, dict):
        parsed = raw
    else:
        return str(raw), ""
    return str(parsed.get("id") or ""), str(parsed.get("providerID") or parsed.get("provider") or "")


def collect_opencode(home: Path) -> list[dict[str, Any]]:
    db_path = home / ".local" / "share" / "opencode" / "opencode.db"
    copied = sqlite_copy(db_path)
    if copied is None:
        return []

    records: list[dict[str, Any]] = []
    try:
        conn = sqlite3.connect(copied)
        conn.row_factory = sqlite3.Row
        query = """
            SELECT id, directory, title, agent, model, cost,
                   tokens_input, tokens_output, tokens_reasoning,
                   tokens_cache_read, tokens_cache_write, time_created
            FROM session
        """
        for row in conn.execute(query):
            model, provider = parse_opencode_model(row["model"])
            records.append(
                new_record(
                    source="opencode",
                    timestamp=normalize_timestamp(row["time_created"]),
                    session_id=str(row["id"] or ""),
                    project=str(row["directory"] or row["title"] or ""),
                    provider=provider,
                    model=model,
                    input_tokens=as_int(row["tokens_input"]),
                    output_tokens=as_int(row["tokens_output"]),
                    cache_creation_tokens=as_int(row["tokens_cache_write"]),
                    cache_read_tokens=as_int(row["tokens_cache_read"]),
                    reasoning_tokens=as_int(row["tokens_reasoning"]),
                    cost_usd=as_float(row["cost"]),
                    source_path=rel_home(db_path),
                )
            )
        conn.close()
    except sqlite3.Error as exc:
        eprint(f"Warning: failed to read opencode database: {exc}")
    finally:
        try:
            copied.unlink()
        except OSError:
            pass
    return records


def collect_local(host_label: str = "", claude_cost_source: str = "auto") -> dict[str, Any]:
    home = Path.home()
    label = host_label or socket.gethostname().split(".", 1)[0]
    records = []
    collectors = (
        ("collect_claude", lambda: collect_claude(home, claude_cost_source)),
        ("collect_pi", lambda: collect_pi(home)),
        ("collect_codex", lambda: collect_codex(home)),
        ("collect_opencode", lambda: collect_opencode(home)),
    )
    for collector_name, collector in collectors:
        try:
            records.extend(collector())
        except Exception as exc:  # noqa: BLE001 - collectors should not block other sources.
            eprint(f"Warning: {collector_name} failed: {exc}")

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


def run_remote_collect(spec: HostSpec, timeout: int, claude_cost_source: str) -> tuple[dict[str, Any] | None, str]:
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
        "--claude-cost-source",
        claude_cost_source,
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
    spec: HostSpec, cache_dir: Path, timeout: int, claude_cost_source: str
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
        payload = collect_local(spec.label, claude_cost_source)
        status["status"] = "updated"
        atomic_write_json(path, payload)
        return payload, status

    payload, error = run_remote_collect(spec, timeout, claude_cost_source)
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
            bucket["sessions"].add(str(record.get("session_id")))
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

    return {
        "generated_at": combined.get("generated_at") or utc_now(),
        "summary": totals,
        "days": days,
        "models": models[:30],
        "services": services,
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
.grid { display: grid; grid-template-columns: minmax(0, 1.35fr) minmax(320px, .65fr); gap: 28px; margin-top: 30px; }
.panel { border-top: 1px solid var(--rule-strong); padding-top: 14px; min-width: 0; }
.panel h2 { margin: 0 0 14px; font-size: 22px; font-weight: 500; letter-spacing: -.02em; }
.chart { display: flex; align-items: flex-end; gap: 3px; height: 230px; padding: 10px 0 0; border-bottom: 1px solid var(--rule); }
.day { flex: 1 1 3px; min-width: 3px; height: 100%; display: flex; flex-direction: column-reverse; justify-content: flex-start; opacity: .94; }
.day:hover { outline: 1px solid var(--gold); outline-offset: 2px; opacity: 1; }
.seg.in { background: var(--in); } .seg.out { background: var(--out); } .seg.cw { background: var(--cw); } .seg.cr { background: var(--cr); } .seg.rz { background: var(--rz); }
.legend { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 10px; color: var(--muted); font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.swatch { display: inline-block; width: 10px; height: 10px; margin-right: 5px; vertical-align: -1px; }
.costline { width: 100%; height: 74px; margin-top: 8px; overflow: visible; }
.servicebar { display: flex; height: 32px; border: 1px solid var(--rule); margin-bottom: 12px; }
.servicebit { min-width: 2px; }
.service-list { display: grid; gap: 8px; }
.service-row { display: grid; grid-template-columns: 1fr auto; gap: 12px; font: 13px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: var(--muted); }
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
@media (max-width: 900px) { .mast, .grid { display: block; } .generated { text-align: left; margin-top: 14px; } .stats { grid-template-columns: repeat(2, 1fr); } .stat:nth-child(2n) { border-right: 0; } }
</style>
</head>
<body>
<main>
  <header class="mast">
    <div><div class="kicker">Personal instrument panel</div><h1>AI Usage<br>Ledger</h1></div>
    <div class="generated"><div class="label">Generated</div><div id="generated"></div><p class="note">Accounts are merged by default. Cost is reported only when the source provides it.</p></div>
  </header>
  <section class="stats" id="stats" aria-label="Summary statistics"></section>
  <section class="grid">
    <div class="panel">
      <h2>Daily Token Flow</h2>
      <div id="chart" class="chart" aria-label="Daily token bars"></div>
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
      <p class="note">The service field is inferred from provider/model names, so Grok used through pi is counted as Grok while retaining source=pi.</p>
    </aside>
  </section>
  <section class="panel" style="margin-top:30px">
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
<script id="usage-data" type="application/json">__DATA__</script>
<script>
const D = JSON.parse(document.getElementById('usage-data').textContent);
const fields = ['input_tokens','output_tokens','cache_creation_tokens','cache_read_tokens','reasoning_tokens'];
const segClass = ['in','out','cw','cr','rz'];
function fmt(n) { n = Number(n || 0); if (n >= 1e9) return (n/1e9).toFixed(1)+'B'; if (n >= 1e6) return (n/1e6).toFixed(1)+'M'; if (n >= 1e3) return (n/1e3).toFixed(0)+'k'; return String(Math.round(n)); }
function usd(n) { return '$' + Number(n || 0).toFixed(2); }
function node(tag, cls, text) { const el = document.createElement(tag); if (cls) el.className = cls; if (text !== undefined) el.textContent = text; return el; }
function renderStats() {
  document.getElementById('generated').textContent = D.generated_at || 'unknown';
  const stats = [
    ['total', fmt(D.summary.total_tokens)], ['input', fmt(D.summary.input_tokens)], ['output', fmt(D.summary.output_tokens)],
    ['cache read', fmt(D.summary.cache_read_tokens)], ['cache write', fmt(D.summary.cache_creation_tokens)], ['cost', usd(D.summary.cost_usd)],
    ['models', fmt(D.summary.active_models)], ['latest', D.summary.latest_date || 'n/a']
  ];
  const root = document.getElementById('stats');
  stats.forEach(([label, value]) => { const box = node('div','stat'); box.append(node('div','label',label)); box.append(node('div','value',value)); root.append(box); });
}
function renderChart() {
  const root = document.getElementById('chart');
  const days = D.days || [];
  const max = Math.max(1, ...days.map(d => Number(d.total_tokens || 0)));
  days.forEach(d => {
    const day = node('div','day');
    day.title = `${d.date} · ${fmt(d.total_tokens)} tokens · ${usd(d.cost_usd)}`;
    fields.forEach((f, idx) => { const seg = node('div', 'seg ' + segClass[idx]); const pct = Math.max(0, Number(d[f] || 0) / max * 100); seg.style.height = pct ? Math.max(.8, pct) + '%' : '0'; day.append(seg); });
    root.append(day);
  });
}
function renderCost() {
  const svg = document.getElementById('costline');
  const days = D.days || [];
  const max = Math.max(0, ...days.map(d => Number(d.cost_usd || 0)));
  if (!days.length || !max) { const t = document.createElementNS('http://www.w3.org/2000/svg','text'); t.setAttribute('x','0'); t.setAttribute('y','38'); t.setAttribute('fill','#9d927f'); t.textContent = 'No reported cost data'; svg.append(t); return; }
  const points = days.map((d, i) => { const x = days.length === 1 ? 0 : i * (1000 / (days.length - 1)); const y = 62 - (Number(d.cost_usd || 0) / max * 54); return `${x.toFixed(1)},${y.toFixed(1)}`; }).join(' ');
  const line = document.createElementNS('http://www.w3.org/2000/svg','polyline'); line.setAttribute('points', points); line.setAttribute('fill','none'); line.setAttribute('stroke','#d8a33d'); line.setAttribute('stroke-width','3'); line.setAttribute('vector-effect','non-scaling-stroke'); svg.append(line);
  const t = document.createElementNS('http://www.w3.org/2000/svg','text'); t.setAttribute('x','1000'); t.setAttribute('y','12'); t.setAttribute('text-anchor','end'); t.setAttribute('fill','#d8a33d'); t.textContent = 'max ' + usd(max); svg.append(t);
}
function renderServices() {
  const palette = ['#d8a33d','#8fb8b6','#577f86','#7d6c9f','#d66b55','#77b77a','#ede4d1'];
  const total = Math.max(1, D.services.reduce((sum, row) => sum + Number(row.total_tokens || 0), 0));
  const bar = document.getElementById('servicebar');
  const list = document.getElementById('services');
  D.services.forEach((row, idx) => {
    const color = palette[idx % palette.length];
    const bit = node('div','servicebit'); bit.style.width = (Number(row.total_tokens || 0) / total * 100) + '%'; bit.style.background = color; bit.title = `${row.source}/${row.service} · ${fmt(row.total_tokens)}`; bar.append(bit);
    const item = node('div','service-row'); const left = node('span','',`${row.source}/${row.service}`); left.style.color = color; item.append(left); item.append(node('span','',`${fmt(row.total_tokens)} · ${usd(row.cost_usd)}`)); list.append(item);
  });
}
function renderModels() {
  const body = document.getElementById('models');
  D.models.forEach(row => {
    const tr = document.createElement('tr');
    const name = document.createElement('td');
    name.title = `sources: ${(row.sources || []).join(', ')}; hosts: ${(row.hosts || []).join(', ')}; accounts: ${(row.accounts || []).join(', ')}`;
    name.append(node('div','model-name',row.model || 'unknown'));
    name.append(node('div','meta',`${row.service || 'unknown'} ${row.provider ? '· '+row.provider : ''} · ${(row.hosts || []).length || 'all'} hosts`));
    tr.append(name);
    [['days',fmt(row.days)],['input',fmt(row.input_tokens)],['output',fmt(row.output_tokens)],['cache',fmt(Number(row.cache_creation_tokens || 0)+Number(row.cache_read_tokens || 0))],['total',fmt(row.total_tokens)],['cost',usd(row.cost_usd)]].forEach(([, value]) => tr.append(node('td','num',value)));
    body.append(tr);
  });
}
function renderHosts() {
  const root = document.getElementById('hosts');
  (D.hosts || []).forEach(row => { const status = row.status || 'missing'; const item = node('div','host '+status); item.title = row.message || row.cache || ''; item.append(node('span','dot', status === 'updated' ? '● ' : status === 'cached' ? '◐ ' : '○ ')); item.append(document.createTextNode(`${row.host || 'host'} · ${status}`)); root.append(item); });
}
renderStats(); renderChart(); renderCost(); renderServices(); renderModels(); renderHosts();
</script>
</body>
</html>
"""


def write_html(path: Path, combined: dict[str, Any], daily: list[dict[str, Any]]) -> None:
    payload = dashboard_payload(combined, daily)
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
    parser.add_argument("--inventory", type=Path, help="Host inventory file. Lines are 'label ssh-target account=name'.")
    parser.add_argument("--host", action="append", default=[], help="Remote host, or label=ssh-target. Can be repeated.")
    parser.add_argument("--no-local", action="store_true", help="Skip local collection.")
    parser.add_argument("--cache-dir", type=Path, default=Path(DEFAULT_CACHE_DIR), help=f"Per-host cache directory, default {DEFAULT_CACHE_DIR}.")
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
        "--claude-cost-source",
        choices=("auto", "raw", "ccusage", "npx"),
        default="auto",
        help="Claude Code source: auto uses installed ccusage or npx ccusage@latest, raw parses JSONL only.",
    )
    parser.add_argument("--json-only", action="store_true", help="Do not write CSV output.")
    parser.add_argument("--collect-local", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--host-label", default="", help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.collect_local:
        print(json.dumps(collect_local(args.host_label, args.claude_cost_source), sort_keys=True))
        return 0

    specs = default_specs(not args.no_local)
    if args.inventory:
        specs.extend(parse_inventory(args.inventory))
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
        payload, status = collect_host(spec, args.cache_dir, args.ssh_timeout, args.claude_cost_source)
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
