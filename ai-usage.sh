#!/usr/bin/env bash
# Run ai-usage-collect.py via uv so matplotlib is available for the infographic.
# All arguments pass through; runs from the script directory so the inventory,
# per-host ledgers, and generated outputs stay together.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: ai-usage.sh [OPTIONS]

Wrapper that runs ai-usage-collect.py through uv, which resolves matplotlib
for the shareable PNG infographic. All options are passed through; see
'ai-usage.sh --help-collector' or docs/ai-usage-collect.md for the full list.

Options handled by this wrapper:
  -h, --help          Show this help
  --help-collector    Show the collector's own --help
EOF
}

if ! command -v uv >/dev/null 2>&1; then
    echo "Error: uv is required (https://docs.astral.sh/uv/). Falling back is possible with: python3 ai-usage-collect.py --no-infographic" >&2
    exit 1
fi

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --help-collector) exec uv run --script "$SCRIPT_DIR/ai-usage-collect.py" --help ;;
    esac
done

cd "$SCRIPT_DIR"
exec uv run --script "$SCRIPT_DIR/ai-usage-collect.py" "$@"
