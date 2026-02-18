#!/usr/bin/env python3
"""Convert *-ccusage.json files to a combined CSV with hostname column."""

import sys
from pathlib import Path

import polars as pl
from rich.console import Console
from rich.table import Table


def main():
    if len(sys.argv) < 2:
        print("Usage: ccusage.py <file1-ccusage.json> [file2-ccusage.json ...]", file=sys.stderr)
        sys.exit(1)

    frames = []
    hostnames = []
    for path_str in sys.argv[1:]:
        path = Path(path_str)
        hostname = path.name.removesuffix("-ccusage.json")
        hostnames.append(hostname)

        raw = pl.read_json(path)
        # The JSON has a top-level "daily" key containing the array
        daily = raw.explode("daily").unnest("daily")

        daily = daily.select(
            pl.col("date"),
            pl.col("modelsUsed").alias("models"),
            pl.col("inputTokens").alias("input"),
            pl.col("outputTokens").alias("output"),
            pl.col("cacheCreationTokens").alias("cache_create"),
            pl.col("cacheReadTokens").alias("cache_read"),
            pl.col("totalTokens").alias("total_tokens"),
            pl.col("totalCost").alias("cost_usd"),
            pl.lit(hostname).alias("hostname"),
        )
        frames.append(daily)

    combined = pl.concat(frames).sort("date", "hostname")
    # Convert models list to comma-separated string for CSV
    combined = combined.with_columns(
        pl.col("models").list.join(", ")
    )

    console = Console()
    table = Table(title="Claude Code Usage", show_lines=True, expand=False)
    for col in combined.columns:
        table.add_column(col, justify="right" if combined[col].dtype in (pl.Int64, pl.Float64) else "left", no_wrap=True, overflow="ellipsis")
    for row in combined.iter_rows():
        table.add_row(*[str(v) for v in row])
    with console.pager(styles=True):
        console.print(table)

    outfile = "-".join(hostnames) + "-ccusage.csv"
    combined.write_csv(outfile)
    console.print(f"\nWritten to {outfile}")


if __name__ == "__main__":
    main()
