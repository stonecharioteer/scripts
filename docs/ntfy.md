# ntfy

## Purpose

Use the local self-hosted ntfy server (`ntfy.home.arpa`) from scripts, cron jobs, and coding agents without depending on Simplepush.

## Overview

`ntfy.sh` is publish-first. The fastest form sends a human-facing notification to the default `alerts` topic:

```bash
./ntfy.sh "Package arrived"
echo "Nightly backup completed" | ./ntfy.sh
```

Use `TOPIC MESSAGE` when you want a specific topic:

```bash
./ntfy.sh agents "Agent done: tests passed"
./ntfy.sh chores "Take out trash bins tonight"
```

By default it publishes to `http://ntfy.home.arpa` and uses `alerts` as the quick-send topic. Override with `NTFY_SERVER`, `NTFY_TOPIC`, or `--server` if needed.

## Requirements

- `curl`
- Optional: ntfy auth token or username/password if the server requires authentication

## Common Topics

- `alerts` - default quick-send topic for human-facing notifications
- `agents` - coding agents and automation can post completion/failure notifications here
- `chores` - household chore reminders

## Usage

### Publish a quick alert

```bash
./ntfy.sh "Package arrived"
echo "Nightly backup completed" | ./ntfy.sh
```

### Publish to a specific topic

```bash
./ntfy.sh agents "Agent done: updated ntfy script"
./ntfy.sh chores "Start the dishwasher"
```

### Publish with title, priority, and tags

```bash
./ntfy.sh send \
  --title "Agent done" \
  --priority high \
  --tags robot,white_check_mark \
  agents \
  "Finished README and docs updates"
```

### Pipe a message from stdin

```bash
echo "Nightly backup completed" | ./ntfy.sh agents
```

### Agent completion pattern

Agents can run this when they finish a task:

```bash
./ntfy.sh send -q \
  --title "Agent done" \
  --tags robot \
  agents \
  "Finished in $(basename "$PWD")"
```

Use `-q` to suppress the ntfy API response.

### Subscribe or poll

Publishing is the main use case, but the script can also read messages:

```bash
./ntfy.sh sub agents
./ntfy.sh poll --since all agents
```

### Health check

```bash
./ntfy.sh health
```

## Configuration

```bash
# Server override
export NTFY_SERVER="http://ntfy.home.arpa"

# Default quick-send topic override
export NTFY_TOPIC="alerts"

# Bearer token auth
export NTFY_TOKEN="your-token"

# Or basic auth
export NTFY_USER="your-user"
export NTFY_PASSWORD="your-password"
```

Fish examples:

```fish
set -Ux NTFY_SERVER http://ntfy.home.arpa
set -Ux NTFY_TOPIC alerts
set -Ux NTFY_TOKEN your-token
```

## Notes

- `simple-notify.sh` remains in the repository for now, but new notifications should use `ntfy.sh`.
- Topic names must be URL-safe: letters, numbers, dot, underscore, and hyphen.
