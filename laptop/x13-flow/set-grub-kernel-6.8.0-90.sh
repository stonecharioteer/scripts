#!/usr/bin/env bash
set -euo pipefail

KERNEL="${1:-6.8.0-90-generic}"
GRUB_CFG="/boot/grub/grub.cfg"
GRUB_DEFAULT_FILE="/etc/default/grub"

printf 'Looking for non-recovery GRUB entry containing: %s\n' "$KERNEL"

ENTRY="$(
  sudo awk -v kernel="$KERNEL" '
    /^[[:space:]]*submenu / {
      if (match($0, /'"'"'[^'"'"']+'"'"'/)) {
        submenu = substr($0, RSTART + 1, RLENGTH - 2)
      }
      next
    }

    /^[[:space:]]*menuentry / {
      if (match($0, /'"'"'[^'"'"']+'"'"'/)) {
        entry = substr($0, RSTART + 1, RLENGTH - 2)
        if (index(entry, kernel) && entry !~ /recovery mode/) {
          if (submenu != "") {
            print submenu ">" entry
          } else {
            print entry
          }
          exit
        }
      }
    }
  ' "$GRUB_CFG"
)"

if [[ -z "$ENTRY" ]]; then
  printf 'ERROR: Could not find a non-recovery GRUB entry for %s\n' "$KERNEL" >&2
  printf 'Available matching entries:\n' >&2
  sudo awk -v kernel="$KERNEL" '
    /^[[:space:]]*menuentry / {
      if (match($0, /'"'"'[^'"'"']+'"'"'/)) {
        entry = substr($0, RSTART + 1, RLENGTH - 2)
        if (index(entry, kernel)) print "  " entry
      }
    }
  ' "$GRUB_CFG" >&2
  exit 1
fi

printf 'Selected GRUB entry:\n  %s\n' "$ENTRY"
printf 'Backing up %s...\n' "$GRUB_DEFAULT_FILE"
sudo cp -a "$GRUB_DEFAULT_FILE" "$GRUB_DEFAULT_FILE.bak.$(date +%Y%m%d%H%M%S)"

printf 'Setting GRUB_DEFAULT to selected entry...\n'
if sudo grep -q '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE"; then
  sudo sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$ENTRY\"|" "$GRUB_DEFAULT_FILE"
else
  printf 'GRUB_DEFAULT="%s"\n' "$ENTRY" | sudo tee -a "$GRUB_DEFAULT_FILE" >/dev/null
fi

printf 'Running update-grub...\n'
sudo update-grub

printf '\nDone. Reboot, then verify with:\n  uname -r\n\nExpected:\n  %s\n' "$KERNEL"
