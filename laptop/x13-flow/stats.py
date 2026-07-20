#!/usr/bin/env python3
# /// script
# dependencies = ["rich>=13.0.0"]
# ///

from __future__ import annotations

import argparse
import asyncio
import contextlib
import datetime as dt
import re
import sys
import termios
import tty
from dataclasses import dataclass
from pathlib import Path

from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.table import Table

DEFAULT_LOG = Path("/var/log/hang-health.log")
SNAPSHOT_RE = re.compile(r"^===== snapshot (\S+) =====$")
DURATION_RE = re.compile(r"^(\d+(?:\.\d+)?)(s|m|h)?$")


@dataclass
class Snapshot:
    timestamp: dt.datetime
    capacity: int | None = None
    battery_status: str | None = None
    battery_power_uw: int | None = None
    cpu_c: float | None = None
    gpu_c: float | None = None
    nvme_c: float | None = None


def parse_timestamp(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value)


def parse_duration(value: str) -> float:
    match = DURATION_RE.match(value.strip())
    if not match:
        raise argparse.ArgumentTypeError("duration must look like 1s, 10s, 1m, 10m, 1h")

    amount = float(match.group(1))
    unit = match.group(2) or "s"
    multiplier = {"s": 1, "m": 60, "h": 3600}[unit]
    seconds = amount * multiplier
    if seconds <= 0:
        raise argparse.ArgumentTypeError("duration must be greater than zero")
    return seconds


def number_from_sensor_line(line: str) -> float | None:
    match = re.search(r"([+-]?\d+(?:\.\d+)?)", line)
    return float(match.group(1)) if match else None


def read_snapshots(path: Path) -> list[Snapshot]:
    snapshots: list[Snapshot] = []
    current: Snapshot | None = None
    in_battery = False

    for raw_line in path.read_text(errors="replace").splitlines():
        line = raw_line.rstrip()
        match = SNAPSHOT_RE.match(line)
        if match:
            if current is not None:
                snapshots.append(current)
            current = Snapshot(timestamp=parse_timestamp(match.group(1)))
            in_battery = False
            continue

        if current is None:
            continue

        if line.startswith("-- "):
            in_battery = False

        if line == "[BAT0]":
            in_battery = True
            continue
        if line.startswith("[") and line.endswith("]") and line != "[BAT0]":
            in_battery = False
            continue

        if in_battery and "=" in line:
            key, value = [part.strip() for part in line.split("=", 1)]
            if key == "capacity":
                current.capacity = int(value)
                continue
            if key == "status":
                current.battery_status = value
                continue
            if key == "power_now":
                current.battery_power_uw = int(value)
                continue

        stripped = line.strip()
        if stripped.startswith("Tctl:"):
            current.cpu_c = number_from_sensor_line(stripped)
        elif stripped.startswith("edge:"):
            current.gpu_c = number_from_sensor_line(stripped)
        elif stripped.startswith("Composite:"):
            current.nvme_c = number_from_sensor_line(stripped)

    if current is not None:
        snapshots.append(current)

    return snapshots


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None

    sorted_values = sorted(values)
    if len(sorted_values) == 1:
        return sorted_values[0]

    rank = (len(sorted_values) - 1) * pct
    lower = int(rank)
    upper = min(lower + 1, len(sorted_values) - 1)
    fraction = rank - lower
    return (
        sorted_values[lower] + (sorted_values[upper] - sorted_values[lower]) * fraction
    )


def color_for_percentile(value: float | None, values: list[float]) -> str:
    if value is None or not values:
        return "dim"

    p75 = percentile(values, 0.75)
    p95 = percentile(values, 0.95)
    if p75 is None or p95 is None:
        return "green"
    if value > p95:
        return "red"
    if value > p75:
        return "yellow"
    return "green"


def color_for_battery(capacity: int | None) -> str:
    if capacity is None:
        return "dim"
    if 50 <= capacity <= 65:
        return "green"
    if 30 <= capacity < 80:
        return "yellow"
    return "red"


def markup(value: str, style: str) -> str:
    return f"[{style}]{value}[/{style}]"


def fmt_temp(value: float | None, baseline: list[float]) -> str:
    if value is None:
        return "[dim]unknown[/dim]"
    return markup(f"{value:.1f}°C", color_for_percentile(value, baseline))


def fmt_temp_range(values: list[float], *, compact: bool = False) -> str:
    if not values:
        return "[dim]unknown[/dim]"

    p25 = percentile(values, 0.25)
    p50 = percentile(values, 0.50)
    p75 = percentile(values, 0.75)
    p95 = percentile(values, 0.95)
    if p25 is None or p50 is None or p75 is None or p95 is None:
        return "[dim]unknown[/dim]"

    sep = "/" if compact else " | "
    parts = [
        markup(f"{p25:.1f}", color_for_percentile(p25, values)),
        markup(f"{p50:.1f}", color_for_percentile(p50, values)),
        markup(f"{p75:.1f}", color_for_percentile(p75, values)),
        markup(f"{p95:.1f}°C", color_for_percentile(p95, values)),
    ]
    return sep.join(parts)


def fmt_capacity(snapshot: Snapshot) -> str:
    if snapshot.capacity is None:
        return "[dim]unknown[/dim]"
    status = f" ({snapshot.battery_status})" if snapshot.battery_status else ""
    return markup(f"{snapshot.capacity}%{status}", color_for_battery(snapshot.capacity))


def fmt_capacity_range(values: list[int]) -> str:
    if not values:
        return "[dim]unknown[/dim]"
    min_value = min(values)
    max_value = max(values)
    return f"{markup(str(min_value), color_for_battery(min_value))}–{markup(f'{max_value}%', color_for_battery(max_value))}"


def fmt_power(value_uw: int | None, baseline_uw: list[int]) -> str:
    if value_uw is None:
        return "[dim]unknown[/dim]"
    power_w = value_uw / 1_000_000
    baseline_w = [value / 1_000_000 for value in baseline_uw]
    return markup(f"{power_w:.3f} W", color_for_percentile(power_w, baseline_w))


def fmt_power_max(values_uw: list[int], *, compact: bool = False) -> str:
    if not values_uw:
        return "[dim]unknown[/dim]"

    values_w = [value / 1_000_000 for value in values_uw]
    max_w = max(values_w)
    p50 = percentile(values_w, 0.50)
    p75 = percentile(values_w, 0.75)
    p95 = percentile(values_w, 0.95)
    if p50 is None or p75 is None or p95 is None:
        return "[dim]unknown[/dim]"

    sep = "/" if compact else " | "
    suffix = "W" if compact else " W"
    parts = [
        markup(f"{p50:.3f}", color_for_percentile(p50, values_w)),
        markup(f"{p75:.3f}", color_for_percentile(p75, values_w)),
        markup(f"{p95:.3f}", color_for_percentile(p95, values_w)),
        markup(f"{max_w:.3f}{suffix}", color_for_percentile(max_w, values_w)),
    ]
    return sep.join(parts)


def snapshots_since(snapshots: list[Snapshot], cutoff: dt.datetime) -> list[Snapshot]:
    return [snapshot for snapshot in snapshots if snapshot.timestamp >= cutoff]


def column_values(
    snapshots: list[Snapshot], *, compact: bool = False
) -> dict[str, str]:
    return {
        "samples": str(len(snapshots)),
        "battery": fmt_capacity_range(
            [s.capacity for s in snapshots if s.capacity is not None]
        ),
        "power": fmt_power_max(
            [s.battery_power_uw for s in snapshots if s.battery_power_uw is not None],
            compact=compact,
        ),
        "cpu": fmt_temp_range(
            [s.cpu_c for s in snapshots if s.cpu_c is not None], compact=compact
        ),
        "gpu": fmt_temp_range(
            [s.gpu_c for s in snapshots if s.gpu_c is not None], compact=compact
        ),
        "nvme": fmt_temp_range(
            [s.nvme_c for s in snapshots if s.nvme_c is not None], compact=compact
        ),
    }


def build_renderable(path: Path, short: bool, width: int | None = None) -> Panel:
    compact = width is not None and width < 160
    snapshots = read_snapshots(path)
    if not snapshots:
        return Panel(
            "No parseable snapshots found", title="X13 Flow health", border_style="red"
        )

    latest = snapshots[-1]
    now = dt.datetime.now(latest.timestamp.tzinfo)
    boot_cutoff = now - dt.timedelta(
        seconds=int(Path("/proc/uptime").read_text().split()[0].split(".")[0])
    )
    hour_snapshots = snapshots_since(snapshots, now - dt.timedelta(hours=1))
    day_snapshots = snapshots_since(snapshots, now - dt.timedelta(hours=24))
    boot_snapshots = snapshots_since(snapshots, boot_cutoff)

    hour = column_values(hour_snapshots, compact=compact)
    day = column_values(day_snapshots, compact=compact)
    boot = column_values(boot_snapshots, compact=compact)

    boot_power = [
        s.battery_power_uw for s in boot_snapshots if s.battery_power_uw is not None
    ]
    boot_cpu = [s.cpu_c for s in boot_snapshots if s.cpu_c is not None]
    boot_gpu = [s.gpu_c for s in boot_snapshots if s.gpu_c is not None]
    boot_nvme = [s.nvme_c for s in boot_snapshots if s.nvme_c is not None]

    title = f"X13 Flow health — latest {latest.timestamp.isoformat()}"
    table_title = "Stats"
    if not short:
        table_title += " (temps: p25/p50/p75/p95; draw: p50/p75/p95/max)"

    rows = [
        ("Samples", "latest", hour["samples"], day["samples"], boot["samples"]),
        (
            "Battery",
            fmt_capacity(latest),
            hour["battery"],
            day["battery"],
            boot["battery"],
        ),
        (
            "Battery draw",
            fmt_power(latest.battery_power_uw, boot_power),
            hour["power"],
            day["power"],
            boot["power"],
        ),
        ("CPU", fmt_temp(latest.cpu_c, boot_cpu), hour["cpu"], day["cpu"], boot["cpu"]),
        ("GPU", fmt_temp(latest.gpu_c, boot_gpu), hour["gpu"], day["gpu"], boot["gpu"]),
        (
            "NVMe",
            fmt_temp(latest.nvme_c, boot_nvme),
            hour["nvme"],
            day["nvme"],
            boot["nvme"],
        ),
    ]

    if compact and not short:
        table = Table(title=table_title, expand=True, show_lines=True)
        table.add_column("Metric", style="bold", no_wrap=True)
        table.add_column("Window", no_wrap=True)
        table.add_column("Value")
        windows = ("Now", "1h", "24h", "Boot")
        for metric, current, last_hour, last_day, since_boot in rows:
            for window, value in zip(
                windows, (current, last_hour, last_day, since_boot), strict=True
            ):
                table.add_row(metric, window, value)
        return Panel(table, title=title, border_style="green")

    table = Table(title=table_title, expand=True)
    table.add_column("Metric", style="bold")
    table.add_column("Current", style="green")

    if not short:
        table.add_column("Last 1h")
        table.add_column("Last 24h")
        table.add_column(f"Since boot ({boot_cutoff.strftime('%Y-%m-%d %H:%M:%S %Z')})")

    for row in rows:
        table.add_row(*row[:2] if short else row)

    return Panel(table, title=title, border_style="green")


async def build_renderable_async(
    path: Path, short: bool, width: int | None = None
) -> Panel:
    return await asyncio.to_thread(build_renderable, path, short, width)


@contextlib.contextmanager
def quiet_terminal_input():
    """Prevent accidental keypresses from echoing into Rich Live output.

    Ctrl-C still works because cbreak mode preserves terminal signals.
    """

    if not sys.stdin.isatty():
        yield
        return

    fd = sys.stdin.fileno()
    old_attrs = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        attrs = termios.tcgetattr(fd)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_attrs)


async def watch(
    path: Path, short: bool, console: Console, interval_seconds: float
) -> None:
    loading = Panel(
        "Loading first snapshot…", title="X13 Flow health", border_style="yellow"
    )

    with quiet_terminal_input():
        with Live(
            loading, console=console, refresh_per_second=1, screen=True, transient=False
        ) as live:
            while True:
                live.update(await build_renderable_async(path, short, console.width))
                await asyncio.sleep(interval_seconds)


async def async_main() -> None:
    parser = argparse.ArgumentParser(
        description="Show X13 Flow battery and temperature stats."
    )
    parser.add_argument("--log-file", type=Path, default=DEFAULT_LOG)
    parser.add_argument("--short", action="store_true", help="show current values only")
    parser.add_argument(
        "--watch",
        nargs="?",
        const="1m",
        metavar="INTERVAL",
        help="update in place every INTERVAL, e.g. 1s, 10s, 1m, 10m, 1h; default 1m to match hang-health-snapshot.timer",
    )
    args = parser.parse_args()

    console = Console()
    if not args.log_file.exists():
        console.print(f"[red]ERROR:[/red] cannot read {args.log_file}")
        raise SystemExit(1)

    if args.watch is not None:
        await watch(args.log_file, args.short, console, parse_duration(args.watch))
    else:
        console.print(
            await build_renderable_async(args.log_file, args.short, console.width)
        )


if __name__ == "__main__":
    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        pass
