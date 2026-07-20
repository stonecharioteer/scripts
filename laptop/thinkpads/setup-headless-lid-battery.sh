#!/usr/bin/env bash
set -euo pipefail

BAT="${BAT:-BAT0}"
BAT_PATH="/sys/class/power_supply/${BAT}"
START_THRESHOLD="${START_THRESHOLD:-55}"
STOP_THRESHOLD="${STOP_THRESHOLD:-60}"

log() { printf '\n==> %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$BAT_PATH" ]] || err "Battery path not found: $BAT_PATH"
[[ -f "$BAT_PATH/charge_control_end_threshold" ]] || err "Battery charge threshold sysfs is not supported on this machine/kernel."

log "Configuring lid-close behavior for headless use"
sudo install -d -m 0755 /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/99-headless-lid.conf >/dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=no
EOF

log "Setting battery charge thresholds now: start=${START_THRESHOLD}%, stop=${STOP_THRESHOLD}%"
echo "$START_THRESHOLD" | sudo tee "$BAT_PATH/charge_control_start_threshold" >/dev/null
echo "$STOP_THRESHOLD" | sudo tee "$BAT_PATH/charge_control_end_threshold" >/dev/null

log "Persisting battery charge thresholds across boot/resume"
sudo tee /etc/systemd/system/battery-charge-threshold.service >/dev/null <<EOF
[Unit]
Description=Set battery charge threshold to ${STOP_THRESHOLD}%
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo ${START_THRESHOLD} > ${BAT_PATH}/charge_control_start_threshold; echo ${STOP_THRESHOLD} > ${BAT_PATH}/charge_control_end_threshold'

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now battery-charge-threshold.service

log "Applying lid config"
sudo systemctl restart systemd-logind

log "Current battery state"
grep -H . "$BAT_PATH"/{status,capacity,charge_control_start_threshold,charge_control_end_threshold} 2>/dev/null || true

log "Current lid config"
systemd-analyze cat-config systemd/logind.conf | grep -E 'HandleLidSwitch|LidSwitchIgnoreInhibited' || true
