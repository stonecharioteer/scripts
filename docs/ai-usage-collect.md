# ai-usage-collect.py

Collect AI coding-agent usage from local and SSH-reachable machines into JSON and CSV files.

## Why

Usage lives in different places depending on the tool: Claude Code JSONL, Codex session files, pi session files, and opencode SQLite. This script normalizes those records without copying prompts, responses, tool arguments, auth files, or raw transcripts.

It keeps a per-host cache, so an offline host does not erase its last known usage.

## Requirements

- `python3`
- `ssh` for remote hosts
- `ccusage` or `npx` for Claude Code cost data. By default the script tries installed `ccusage`, then `npx --yes ccusage@latest`, then falls back to raw Claude JSONL tokens.

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
| `.ai-usage-cache/<host>.json` | Last successful snapshot for each host |

## Examples

```bash
# Collect this machine only
./ai-usage-collect.py

# Collect local plus two SSH hosts
./ai-usage-collect.py --host eqr5 --host macbook=stone@macbook.local

# Use an inventory file
./ai-usage-collect.py --inventory ai-usage.hosts

# Keep hosts separate in the daily aggregate
./ai-usage-collect.py --daily-split-hosts

# Avoid network calls for Claude Code and parse raw JSONL only
./ai-usage-collect.py --claude-cost-source raw
```

Inventory format:

```text
# label ssh-target optional key=value metadata
local local account=personal
eqr5 stone@eqr5.local account=personal
work-mac stone@work-mac.local account=work
```

Daily aggregates merge hosts and accounts by default so the stats read as one person's usage. Raw records still retain host and account labels for auditing. Use `--daily-split-hosts` or `--daily-split-accounts` when you want those dimensions separated.

## Sources

| Source | Local data read | Notes |
|--------|-----------------|-------|
| Claude Code | `~/.claude/projects/**/*.jsonl`, `~/.claude/transcripts/*.jsonl`, or `ccusage daily --json` | `ccusage` provides cost data when available |
| Codex | `~/.codex/sessions/**/*.jsonl`, `~/.codex/archived_sessions/*.jsonl` | Uses latest `token_count` event per session |
| pi | `~/.pi/agent/sessions/**/*.jsonl` | Includes Grok when pi logs `provider=xai-*` and `model=grok-*` |
| opencode | `~/.local/share/opencode/opencode.db` | Reads session token and cost totals from a temporary SQLite backup |

The `source` column is the app that logged usage. The `service` column is inferred from provider/model names, so Grok used through pi appears as `source=pi` and `service=grok`.

## Offline hosts

Remote collection streams this script over SSH and runs `python3 - --collect-local` on the target. When SSH fails, the script loads `.ai-usage-cache/<host>.json` if it exists and marks those rows with `from_cache=true`.

Hosts with no cache and no successful SSH connection are skipped with a warning.

## Cost semantics

Costs are recorded when the local source reports them:

- Claude Code: from `ccusage` when available.
- pi: from the session usage object.
- opencode: from the session table.
- Codex native session files: token counts are available, but dollar cost is usually not present.

For sources without cost data, `cost_usd` is `0` rather than an estimate.
