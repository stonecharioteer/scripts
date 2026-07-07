#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCREEN_SH="$SCRIPT_DIR/screen.sh"
SERVICE_NAME="x13-screen-off.service"
TIMER_NAME="x13-screen-off.timer"

if [[ ! -x "$SCREEN_SH" ]]; then
  printf 'ERROR: %s is not executable or does not exist\n' "$SCREEN_SH" >&2
  exit 1
fi

printf 'Installing %s and %s...\n' "$SERVICE_NAME" "$TIMER_NAME"

sudo tee "/etc/systemd/system/$SERVICE_NAME" >/dev/null <<EOF
[Unit]
Description=Force ASUS X13 laptop panel off for headless/tent mode
Documentation=file://$SCREEN_SH

[Service]
Type=oneshot
ExecStart=$SCREEN_SH --apply-off
EOF

sudo tee "/etc/systemd/system/$TIMER_NAME" >/dev/null <<EOF
[Unit]
Description=Keep ASUS X13 laptop panel off for headless/tent mode

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=$SERVICE_NAME
Persistent=false

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload

printf '\nInstalled. The timer is not enabled until you run:\n'
printf '  %s --off\n' "$SCREEN_SH"
printf '\nTo disable keep-off and restore screen:\n'
printf '  %s --on\n' "$SCREEN_SH"
printf '\nStatus:\n'
printf '  %s --status\n' "$SCREEN_SH"
