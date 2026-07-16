# ai-usage-collect.py

Collect AI coding-agent usage from local and SSH-reachable machines into JSON, CSV, and a static HTML dashboard.

## Why

Usage lives in ccusage-supported coding-agent history across tools. This script asks ccusage for unified daily usage and normalizes those records without copying prompts, responses, tool arguments, auth files, or raw transcripts.

It keeps a per-host cache, so an offline host does not erase its last known usage.

## Requirements

- `python3`
- `ssh` for remote hosts
- `ccusage` or `npx` for unified multi-agent usage and cost data. By default the script tries `npx --yes ccusage@latest`, then installed `ccusage`.

No Python packages are required.

## Usage

```bash
./ai-usage-collect.py [OPTIONS]
```

Default outputs:

| File | Description |
|------|-------------|
| `ai-usage.json` | Raw normalized records from every collected host |
| `ai-usage.csv` | CSV version of raw records |
| `ai-usage-daily.json` | Daily per-model aggregates |
| `ai-usage-daily.csv` | CSV version of daily aggregates |
| `ai-usage.html` | Self-contained static dashboard refreshed on each run |
| `.ai-usage-cache/<host>.json` | Last successful snapshot for each host, stored next to the script by default |

## Examples

```bash
# Collect this machine plus hosts from ai-usage.hosts next to the script, when present
./ai-usage-collect.py

# Collect this machine only
./ai-usage-collect.py --inventory /dev/null

# Collect local plus two SSH hosts
./ai-usage-collect.py --host eqr5 --host macbook=stone@macbook.local

# Use an inventory file
./ai-usage-collect.py --inventory ai-usage.hosts

# Keep hosts separate in the daily aggregate
./ai-usage-collect.py --daily-split-hosts

# Avoid npx and use an installed ccusage binary only
./ai-usage-collect.py --ccusage-runner ccusage

# Skip the dashboard when only machine-readable data is needed
./ai-usage-collect.py --no-html
```

When `--inventory` is not provided, the script looks for `ai-usage.hosts` in the same directory as `ai-usage-collect.py`. The local machine is included by default; inventory files are for additional SSH hosts.

Inventory format:

```text
# label ssh-target optional key=value metadata
local local account=personal
eqr5 stone@eqr5.local account=personal
work-mac stone@work-mac.local account=work
```

Daily aggregates and the HTML dashboard merge hosts and accounts by default so the stats read as one person's usage. Raw records still retain host and account labels for auditing. Use `--daily-split-hosts` or `--daily-split-accounts` when you want those dimensions separated.

## HTML dashboard

The dashboard is a single file with embedded CSS, JavaScript, and aggregate data. It shows:

- total, input, output, cache, cost, model count, and latest date
- an All / 7D / 30D / 90D / 1Y / custom date selector plus a host filter defaulting to all hosts
- daily token flow bars split by input/output/cache/reasoning, with a left token Y axis and log/linear scale toggle
- an overlaid reported-cost curve on the same date axis, with a right cost Y axis using the same scale mode
- GitHub-style daily heatmaps for token volume and reported cost, with month markers and hover values
- provider mix grouped by model provider family, including Grok usage logged through pi
- a Tokenmaxxing panel with peak day, average tokens/day, cache multiplier, and output share
- top models by token volume
- host cache status, including cached/offline hosts

The HTML embeds only aggregate dashboard data, not raw prompts, responses, tool calls, or per-session records.

## Sources

| Source | Command | Notes |
|--------|---------|-------|
| Unified default | `ccusage daily --json --by-agent` | Primary and only usage source for all ccusage-supported coding agents and costs |
| Runner selection | `--ccusage-runner auto\|npx\|ccusage` | `auto` prefers `npx ccusage@latest`, then installed `ccusage` |

The `source` column is the app that logged usage according to ccusage. The `service` column is inferred from provider/model names, so Grok used through pi appears as `source=pi` and `service=grok`.

## Offline hosts

Remote collection streams this script over SSH and runs `python3 - --collect-local` on the target. When SSH fails, the script loads `.ai-usage-cache/<host>.json` next to the script by default if it exists and marks those rows with `from_cache=true`.

Hosts with no cache and no successful SSH connection are skipped with a warning.

## Cost semantics

Costs are recorded exactly as reported by `ccusage daily --json --by-agent`. For ccusage-supported rows without cost data, `cost_usd` is `0` rather than an estimate.
