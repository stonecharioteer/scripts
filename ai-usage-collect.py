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
    parser.add_argument("--no-daily", action="store_true", help="Skip daily aggregate outputs.")
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
    atomic_write_json(args.output_json, combined)
    if not args.json_only:
        write_csv(args.output_csv, combined["records"])
    if not args.no_daily:
        daily = aggregate_daily(
            combined["records"],
            split_hosts=args.daily_split_hosts,
            split_accounts=args.daily_split_accounts,
        )
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
    eprint(f"Wrote {args.output_json}")
    if not args.json_only:
        eprint(f"Wrote {args.output_csv}")
    if not args.no_daily:
        eprint(f"Wrote {args.daily_json}")
        if not args.json_only:
            eprint(f"Wrote {args.daily_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
