# env-diff.sh

Compare two `.env` files and render a readable diff table with [`gum`](https://github.com/charmbracelet/gum).

## Why

Environment files often contain repeated keys, local overrides, and secrets. This script shows what changed without dumping token-like values into terminal scrollback or logs.

## Requirements

- `bash`
- `awk`
- `sort`
- `gum`

## Usage

```bash
./env-diff.sh [OPTIONS] LEFT_ENV RIGHT_ENV
```

Options:

| Option | Description |
|--------|-------------|
| `-a`, `--all` | Include unchanged variables in the table |
| `--exit-code` | Exit `1` when differences are found |
| `--max-width WIDTH` | Limit displayed width for non-secret values, default `80` |
| `-h`, `--help` | Show help text |

## Examples

```bash
# Show only differences
./env-diff.sh .env .env.example

# Include unchanged variables too
./env-diff.sh --all .env.local .env.production

# Use in a check script
./env-diff.sh --exit-code .env.old .env.new
```

## Diff semantics

- Blank lines and comments are ignored.
- `export NAME=value` is accepted.
- Duplicate assignments in the same file use the last value encountered.
- Variables only in the right file are shown as `ADDED`.
- Variables only in the left file are shown as `REMOVED`.
- Variables in both files with different final values are shown as `CHANGED`.

## Secret redaction

Values are redacted when the variable name or value looks sensitive, including names containing `TOKEN`, `SECRET`, `PASSWORD`, `KEY`, credentials, auth/session/cookie fields, private-key blocks, common provider token prefixes, JWT-like values, long hex strings, and long high-entropy token-like strings.

Redacted values are displayed with per-run labels such as:

```text
<redacted #1 len=42>
<redacted #2 len=42>
```

The labels preserve equality/difference information without printing the secret itself.
