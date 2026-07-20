#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/log/nvme-health.log}"
DEVICE_SMARTCTL="${DEVICE_SMARTCTL:-/dev/nvme0n1}"
DEVICE_NVME="${DEVICE_NVME:-/dev/nvme0}"

printf 'Installing daily NVMe health monitoring...\n'

sudo install -d -m 0755 /usr/local/sbin

sudo tee /usr/local/sbin/nvme-health-snapshot >/dev/null <<EOF
#!/usr/bin/env bash
set +e

LOG_FILE="$LOG_FILE"
DEVICE_SMARTCTL="$DEVICE_SMARTCTL"
DEVICE_NVME="$DEVICE_NVME"

{
  echo '===== nvme health snapshot' "\$(date --iso-8601=seconds)" '====='
  echo '-- devices --'
  lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS 2>&1
  echo

  echo '-- smartctl summary --'
  if command -v smartctl >/dev/null 2>&1; then
    smartctl -H "\$DEVICE_SMARTCTL" 2>&1
    echo
    smartctl -a "\$DEVICE_SMARTCTL" 2>&1 | sed -n '/SMART overall-health/,/Error Information/p; /Critical Warning/p; /Temperature:/p; /Available Spare:/p; /Percentage Used:/p; /Data Units Read:/p; /Data Units Written:/p; /Host Read Commands:/p; /Host Write Commands:/p; /Controller Busy Time:/p; /Power Cycles:/p; /Power On Hours:/p; /Unsafe Shutdowns:/p; /Media and Data Integrity Errors:/p; /Error Information Log Entries:/p'
  else
    echo 'smartctl not installed. Install smartmontools for SMART health details.'
  fi
  echo

  echo '-- nvme smart-log --'
  if command -v nvme >/dev/null 2>&1; then
    nvme smart-log "\$DEVICE_NVME" 2>&1
  else
    echo 'nvme CLI not installed. Install nvme-cli for NVMe smart-log details.'
  fi
  echo

  echo '-- recent nvme/kernel storage warnings, last 24h --'
  journalctl -k --since '24 hours ago' --no-pager 2>/dev/null \
    | grep -Ei 'nvme|I/O error|blk_update_request|timeout|reset|abort|media error|critical warning' \
    | tail -200 || true
  echo
} >> "\$LOG_FILE"
EOF

sudo chmod 0755 /usr/local/sbin/nvme-health-snapshot

sudo tee /etc/systemd/system/nvme-health-snapshot.service >/dev/null <<'EOF'
[Unit]
Description=Collect daily NVMe SMART health snapshot

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvme-health-snapshot
EOF

sudo tee /etc/systemd/system/nvme-health-snapshot.timer >/dev/null <<'EOF'
[Unit]
Description=Run daily NVMe SMART health snapshot

[Timer]
OnBootSec=5min
OnUnitActiveSec=1d
AccuracySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo touch "$LOG_FILE"
sudo chmod 0644 "$LOG_FILE"

sudo systemctl daemon-reload
sudo systemctl enable --now nvme-health-snapshot.timer
sudo systemctl start nvme-health-snapshot.service || true

printf '\nDone. Daily NVMe health snapshots will be written to:\n  %s\n' "$LOG_FILE"
printf '\nCheck status with:\n  systemctl status nvme-health-snapshot.timer\n'
printf '\nRead latest snapshots with:\n  tail -200 %s\n' "$LOG_FILE"
printf '\nIf output says tools are missing, install them with:\n  sudo apt install smartmontools nvme-cli\n'
