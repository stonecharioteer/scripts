#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${SUDO_USER:-$USER}"
FISH_PATH="${FISH_PATH:-}"

log() { printf '\n==> %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ -z "$FISH_PATH" ]]; then
  FISH_PATH="$(command -v fish || true)"
fi

if [[ -z "$FISH_PATH" ]]; then
  log "Installing fish shell"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y fish
  else
    err "apt-get not found. Install fish manually, then rerun with FISH_PATH=/path/to/fish"
  fi
  FISH_PATH="$(command -v fish || true)"
fi

[[ -n "$FISH_PATH" ]] || err "fish was not found after install"
[[ -x "$FISH_PATH" ]] || err "fish path is not executable: $FISH_PATH"

log "Ensuring $FISH_PATH is listed in /etc/shells"
if ! grep -Fxq "$FISH_PATH" /etc/shells; then
  echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
fi

log "Changing default shell for $USER_NAME to $FISH_PATH"
sudo chsh -s "$FISH_PATH" "$USER_NAME"

log "Done"
printf 'User: %s\nFish: %s\nCurrent passwd shell: %s\n' \
  "$USER_NAME" \
  "$FISH_PATH" \
  "$(getent passwd "$USER_NAME" | awk -F: '{print $7}')"

printf '\nLog out and back in for the default shell change to take effect.\n'
