# Simple Notify

## Purpose

I wanted a tiny command-line wrapper for Simplepush so shell scripts and one-off terminal commands can send phone notifications with a single command.

## Overview

`simple-notify.sh` sends a JSON payload to `https://api.simplepush.io/send` using your `SIMPLE_PUSH_KEY` environment variable.

Payload format:

```json
{"key":"<SIMPLE_PUSH_KEY>","msg":"<message>"}
```

## Requirements

- `curl`
- A Simplepush key exported as `SIMPLE_PUSH_KEY`

## Fish Setup

Set your key once in fish:

```fish
set -Ux SIMPLE_PUSH_KEY your-simplepush-key
```

Or for the current session only:

```fish
set -x SIMPLE_PUSH_KEY your-simplepush-key
```

## Usage

```bash
./simple-notify.sh "Build finished"
./simple-notify.sh Deploy completed successfully

echo "Nightly backup is done" | ./simple-notify.sh
```

## Features

- **Simple setup**: only needs `curl` and `SIMPLE_PUSH_KEY`
- **JSON payload**: sends the expected `key` and `msg` fields
- **Flexible input**: accepts message text as arguments or from stdin
- **Helpful errors**: validates missing key, empty message, and missing dependencies

## Options

```text
-h, --help     Show help
-q, --quiet    Suppress API response output
-u, --url URL  Override the endpoint
```

## Installation

You can run it directly:

```bash
chmod +x simple-notify.sh
./simple-notify.sh "Hello"
```

Or symlink it as `simple-notify`:

```bash
ln -s /path/to/simple-notify.sh ~/.local/bin/simple-notify
simple-notify "Hello"
```

## Troubleshooting

### `SIMPLE_PUSH_KEY is not set`

Export your key before running the script:

```fish
set -Ux SIMPLE_PUSH_KEY your-simplepush-key
```

### `curl is required but not installed`

Install curl with your system package manager.

### Request failed

Check that:
- your key is valid
- you have network access
- the Simplepush API is reachable
