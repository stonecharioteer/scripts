# ai-usage-collect.py

Collect AI coding-agent usage from local and SSH-reachable machines into JSON, CSV, a static HTML dashboard, and a shareable PNG infographic.

Run it through the wrapper so uv resolves matplotlib for the infographic:

```bash
./ai-usage.sh            # equivalent to: uv run --script ai-usage-collect.py
```

The Python script's shebang is `#!/usr/bin/env -S uv run --script`, so `./ai-usage-collect.py` also works directly. Plain `python3 ai-usage-collect.py` works too but skips the infographic (matplotlib is imported lazily and remote hosts always run plain python3 over SSH).

## Why

Usage lives in ccusage-supported coding-agent history across tools. This script asks ccusage for unified daily usage and normalizes those records without copying prompts, responses, tool arguments, auth files, or raw transcripts.

Each host's cache is an **append-only ledger**: agents prune their local logs over time (Claude Code deletes old transcripts, reinstalls wipe history), so the collector merges every fresh collection into the cached ledger instead of replacing it. Records that vanish from a host's logs are retained from the ledger; when both sides have the same `(date, source, provider, model)` record, the one with more total tokens wins. An empty collection (for example a host whose ccusage install broke) can never erase history.

## Requirements

- `python3`
- `ssh` for remote hosts
- `ccusage` or `npx` for unified multi-agent usage and cost data. By default the script tries `npx --yes ccusage@latest`, then installed `ccusage`. Pin a version with `--ccusage-package ccusage@<version>`.

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
| `ai-usage-infographic.png` | Shareable 1080x1350 (Instagram portrait) infographic — stat tiles, log-scale daily token flow with estimated-cost overlay, provider mix, and top models; no tables or host detail |

All outputs cover the current calendar year by default (`--this-year`); pass `--no-this-year` for all-time. The per-host ledgers always keep full history regardless.
| `.ai-usage-cache/<host>.json` | Append-only usage ledger for each host, stored next to the script by default |

## Examples

```bash
# Collect this machine plus all hosts from ai-usage.hosts next to the script, when present
./ai-usage.sh

# Include prior years in the outputs (default is the current year only)
./ai-usage.sh --no-this-year

# Collect this machine only
./ai-usage.sh --inventory /dev/null

# Collect local plus two SSH hosts
./ai-usage-collect.py --host eqr5 --host macbook=stone@macbook.local

# Collect hosts one at a time instead of the default 4-way parallel SSH
./ai-usage-collect.py --parallel 1

# Align daily buckets across machines in different timezones
./ai-usage-collect.py --timezone Asia/Kolkata

# Keep hosts separate in the daily aggregate
./ai-usage-collect.py --daily-split-hosts

# Avoid npx and use an installed ccusage binary only
./ai-usage-collect.py --ccusage-runner ccusage

# Skip the dashboard when only machine-readable data is needed
./ai-usage-collect.py --no-html
```

When `--inventory` is not provided, the script looks for `ai-usage.hosts` in the same directory as `ai-usage-collect.py` and collects **every** host listed there. The local machine is included by default; inventory files are for additional SSH hosts. Hosts are collected concurrently (`--parallel`, default 4).

Inventory format:

```text
# label ssh-target optional key=value metadata
local local account=personal
eqr5 stone@eqr5.local account=personal
work-mac stone@work-mac.local account=work
```

Daily aggregates and the HTML dashboard merge hosts and accounts by default so the stats read as one person's usage. Raw records still retain host and account labels for auditing. Use `--daily-split-hosts` or `--daily-split-accounts` when you want those dimensions separated.

### Duplicate machine detection

Each payload records a stable machine ID (`/etc/machine-id` on Linux, `IOPlatformUUID` on macOS). If two inventory labels resolve to the same physical machine (an alias, an FQDN variant), the second one is skipped with a `duplicate` status so the same usage is never counted twice.

### Push-style collection

Instead of pulling over SSH, each host can push its own ledger on a cron into a synced directory (git repo, Syncthing, NFS):

```bash
# on each host, e.g. hourly cron
./ai-usage-collect.py --collect-local --host-label eqr5 --collect-output /synced/ai-usage-cache/eqr5.json
```

Point the aggregator's `--cache-dir` at that directory. Hosts that are unreachable over SSH fall back to their pushed ledger automatically, so laptops report whenever they are awake instead of needing to be reachable at collection time.

## HTML dashboard

The dashboard is a single self-contained file: CSS, aggregate data, and a pinned D3 build are all inlined, so it works offline (the D3 source is fetched once and cached in the cache directory; if that first fetch fails the file falls back to the CDN). It is responsive down to phone widths. It shows:

- headline stats led by estimated cost and output tokens (the honest "burn" metrics — raw totals are dominated by cheap cache reads), followed by input, cache, total, model count, and latest date
- a coverage banner when any host is missing or served from a stale ledger, so incomplete totals are never silent
- pill-style filters: All / 7D / 30D / 90D / 1Y presets, custom date range, and tap-friendly host chips (multi-select)
- D3-rendered daily token flow bars split by input/output/cache/reasoning, with a log/linear scale toggle and an overlaid estimated-cost curve with hover values, including provider-by-provider cost per date
- GitHub-style daily heatmaps for token volume and estimated cost
- provider mix grouped by inferred model family (Claude, OpenAI, Gemini, Grok, …) regardless of which agent routed the request
- a Tokenmaxxing panel with peak day, average tokens/day, cache multiplier, and output share
- a sortable, filterable model table (click headers to sort, type to filter by model/provider/agent/host), ranked by estimated cost by default
- host ledger status, including cached/offline hosts with their last-collected date

The HTML embeds only aggregate dashboard data, not raw prompts, responses, tool calls, or per-session records.

### Sharing

The headline stats and the model table are prerendered into the HTML itself, so viewers that block JavaScript (mail attachment previews, Drive/WhatsApp in-app viewers) still show real numbers with a `<noscript>` note instead of a blank page; a normal browser upgrades to the full interactive version.

For a picture instead of a page, share `ai-usage-infographic.png` — a dark-themed 4:5 summary rendered with matplotlib in the same ledger style (validated colorblind-safe palette, serif/mono typography, no default matplotlib colors or fonts). Skip it with `--no-infographic` or point it elsewhere with `--infographic PATH`.

## Sources

| Source | Command | Notes |
|--------|---------|-------|
| Unified default | `ccusage daily --json --by-agent` | Primary and only usage source for all ccusage-supported coding agents and costs |
| Runner selection | `--ccusage-runner auto\|npx\|ccusage` | `auto` prefers `npx ccusage@latest`, then installed `ccusage` |
| Version pinning | `--ccusage-package ccusage@17.2.0` | npm spec used by the npx runner |
| Timezone | `--timezone Asia/Kolkata` | Passed to ccusage so daily buckets align across hosts; defaults to each machine's local timezone |

The `source` column is the app that logged usage according to ccusage. The `service` column is inferred from provider/model names, so Grok used through pi appears as `source=pi` and `service=grok`. Reasoning tokens are recorded when ccusage reports them.

## Offline hosts

Remote collection streams this script over SSH and runs `python3 - --collect-local` on the target. When SSH fails, the script loads the host's ledger from `.ai-usage-cache/<host>.json` and marks those rows with `from_cache=true`; the dashboard flags them in the coverage banner with the ledger's last-collected date.

Hosts with no ledger and no successful SSH connection are skipped with a warning and surfaced in the coverage banner.

## Cost semantics

`cost_usd` is ccusage's **API-equivalent estimate** computed from public pricing — useful for trends, but not billed spend (subscription plans make the real number lower). The dashboard labels it "est. cost" throughout. Rows without cost data record `0` rather than an estimate.
