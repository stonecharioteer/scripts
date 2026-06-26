#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec uv run --project "$SCRIPT_DIR" python "$SCRIPT_DIR/check-pr.py" "$@"
