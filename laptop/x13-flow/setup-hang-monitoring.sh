#!/usr/bin/env bash
set -euo pipefail

printf 'Installing system hang/health monitor...\n'

sudo install -d -m 0755 /usr/local/sbin
sudo tee /usr/local/sbin/hang-health-snapshot >/dev/null <<'EOF'
#!/usr/bin/env bash
set +e
LOG=/var/log/hang-health.log
{
  echo '===== snapshot' "$(date --iso-8601=seconds)" '====='
  echo '-- uptime/load --'
  uptime
  cat /proc/loadavg

  echo '-- memory --'
  free -h
  awk '/MemAvailable|MemFree|SwapFree|Dirty|Writeback/ {print}' /proc/meminfo

  echo '-- disk --'
  df -h / /boot /home 2>/dev/null

  echo '-- battery/ac --'
  for ps in /sys/class/power_supply/*; do
    [ -d "$ps" ] || continue
    name=$(basename "$ps")
    echo "[$name]"
    for f in type status capacity charge_control_end_threshold online energy_now energy_full power_now voltage_now; do
      [ -r "$ps/$f" ] && printf '  %s=%s\n' "$f" "$(cat "$ps/$f" 2>/dev/null)"
    done
  done

  echo '-- thermal zones --'
  for z in /sys/class/thermal/thermal_zone*; do
    [ -r "$z/temp" ] || continue
    type=$(cat "$z/type" 2>/dev/null)
    temp=$(cat "$z/temp" 2>/dev/null)
    printf '%s %s %sC\n' "$(basename "$z")" "$type" "$((temp/1000))"
  done

  if command -v sensors >/dev/null 2>&1; then
    echo '-- sensors --'
    sensors 2>/dev/null | sed -n '1,120p'
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    echo '-- nvidia --'
    nvidia-smi --query-gpu=name,pstate,temperature.gpu,power.draw,utilization.gpu,memory.used --format=csv 2>&1
  fi

  echo '-- top cpu --'
  ps -eo pid,ppid,stat,pcpu,pmem,comm,args --sort=-pcpu | head -15

  echo '-- top mem --'
  ps -eo pid,ppid,stat,pcpu,pmem,comm,args --sort=-pmem | head -15

  echo '-- recent kernel warnings/errors --'
  journalctl -k -p warning..alert --since '5 minutes ago' --no-pager 2>/dev/null | tail -80

  echo
} >> "$LOG"
EOF
sudo chmod 0755 /usr/local/sbin/hang-health-snapshot

sudo tee /etc/systemd/system/hang-health-snapshot.service >/dev/null <<'EOF'
[Unit]
Description=Collect a health snapshot for debugging hangs

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hang-health-snapshot
EOF

sudo tee /etc/systemd/system/hang-health-snapshot.timer >/dev/null <<'EOF'
[Unit]
Description=Run hang health snapshot every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

printf 'Ensuring persistent journald storage...\n'
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal || true

printf 'Enabling SysRq for emergency diagnostics/reboot...\n'
echo 'kernel.sysrq = 1' | sudo tee /etc/sysctl.d/99-sysrq.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-sysrq.conf >/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable --now hang-health-snapshot.timer
sudo systemctl start hang-health-snapshot.service || true

printf '\nDone. Logs will be written to:\n  /var/log/hang-health.log\n\nCheck timer with:\n  systemctl status hang-health-snapshot.timer\n\nIf it hard-hangs again, after reboot inspect:\n  journalctl -b -1 -p warning..alert\n  tail -300 /var/log/hang-health.log\n'
