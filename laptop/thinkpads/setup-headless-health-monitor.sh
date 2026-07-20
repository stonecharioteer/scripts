#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/headless-health-monitor.sh"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/headless-health-monitor.service"

log() { printf '\n==> %s\n' "$*"; }

[[ -x "$SCRIPT" ]] || chmod +x "$SCRIPT"
mkdir -p "$UNIT_DIR"

log "Installing user systemd service"
cat > "$UNIT" <<EOF
[Unit]
Description=Headless laptop health monitor
After=default.target

[Service]
Type=simple
ExecStart=$SCRIPT monitor
Restart=always
RestartSec=10
Environment=INTERVAL=60

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now headless-health-monitor.service

log "Status"
systemctl --user --no-pager status headless-health-monitor.service || true

cat <<EOF

Logs are in:
  $HOME/headless-monitor/logs/health.tsv
  $HOME/headless-monitor/logs/events.log

Useful commands:
  $SCRIPT snapshot
  tail -f $HOME/headless-monitor/logs/health.tsv
  systemctl --user status headless-health-monitor.service
  journalctl --user -u headless-health-monitor.service -f

Optional, recommended for starting this monitor even before you SSH in after boot:
  sudo loginctl enable-linger $USER
EOF
