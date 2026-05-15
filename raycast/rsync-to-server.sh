#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Rsync Clipboard File or Image
# @raycast.mode silent

# Arguments:
# @raycast.argument1 { "type": "text", "placeholder": "SSH Host" }
# @raycast.argument2 { "type": "text", "placeholder": "/tmp", "optional": true }

set -euo pipefail

REMOTE_HOST="$1"
REMOTE_DIR="${2:-/tmp}"

CLIPBOARD_TEXT="$(pbpaste || true)"
LOCAL_PATH=""

# Case 1: clipboard is a file path
if [[ -n "$CLIPBOARD_TEXT" ]]; then
  if [[ "$CLIPBOARD_TEXT" =~ ^file:// ]]; then
    LOCAL_PATH="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1][7:]))' "$CLIPBOARD_TEXT")"
  else
    LOCAL_PATH="${CLIPBOARD_TEXT/#\~/$HOME}"
  fi
fi

# Case 2: clipboard is image data
if [[ -z "$LOCAL_PATH" || ! -f "$LOCAL_PATH" ]]; then
  if ! command -v pngpaste >/dev/null 2>&1; then
    osascript -e 'display notification "Install pngpaste: brew install pngpaste" with title "Rsync Clipboard"'
    exit 1
  fi

  LOCAL_PATH="/tmp/clipboard-image-$(date +%Y%m%d-%H%M%S).png"

  if ! pngpaste "$LOCAL_PATH" >/dev/null 2>&1; then
    osascript -e 'display notification "Clipboard is not a file path or image" with title "Rsync Clipboard"'
    exit 1
  fi
fi

FILENAME="$(basename "$LOCAL_PATH")"
REMOTE_PATH="${REMOTE_DIR}/${FILENAME}"

rsync -avz "$LOCAL_PATH" "${REMOTE_HOST}:${REMOTE_PATH}"

echo -n "${REMOTE_HOST}:${REMOTE_PATH}" | pbcopy

osascript -e "display notification \"Copied ${REMOTE_HOST}:${REMOTE_PATH}\" with title \"Rsync Complete\""
