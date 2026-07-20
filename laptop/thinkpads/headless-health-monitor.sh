#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR:-$HOME/headless-monitor}"
LOG_DIR="$BASE_DIR/logs"
INTERVAL="${INTERVAL:-60}"
BAT="${BAT:-BAT0}"
WIFI_IFACE="${WIFI_IFACE:-wlp0s20f3}"
MAX_LOG_MB="${MAX_LOG_MB:-25}"

mkdir -p "$LOG_DIR"

main_log="$LOG_DIR/health.tsv"
events_log="$LOG_DIR/events.log"
snapshot_log="$LOG_DIR/snapshot-$(date +%Y%m%d-%H%M%S).log"

rotate_if_large() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local size_mb
  size_mb=$(du -m "$file" | awk '{print $1}')
  if (( size_mb >= MAX_LOG_MB )); then
    mv "$file" "$file.$(date +%Y%m%d-%H%M%S).old"
  fi
}

read_file() { [[ -r "$1" ]] && tr -d '\n' < "$1" 2>/dev/null || printf 'NA'; }

battery_field() {
  local name="$1"
  read_file "/sys/class/power_supply/$BAT/$name"
}

battery_power_watts() {
  local p_now v_now c_now
  p_now=$(battery_field power_now)
  if [[ "$p_now" != "NA" ]]; then awk -v x="$p_now" 'BEGIN{printf "%.2f", x/1000000}'; return; fi
  v_now=$(battery_field voltage_now)
  c_now=$(battery_field current_now)
  if [[ "$v_now" != "NA" && "$c_now" != "NA" ]]; then awk -v v="$v_now" -v c="$c_now" 'BEGIN{printf "%.2f", (v*c)/1000000000000}'; return; fi
  printf 'NA'
}

temps_summary() {
  # compact thermal-zone summary, no extra tabs
  local out=""
  for z in /sys/class/thermal/thermal_zone*; do
    [[ -r "$z/temp" ]] || continue
    local type temp
    type=$(read_file "$z/type")
    temp=$(read_file "$z/temp")
    [[ "$temp" =~ ^[0-9]+$ ]] && temp=$(awk -v t="$temp" 'BEGIN{printf "%.1fC", t/1000}')
    out+="${type}:${temp} "
  done
  printf '%s' "${out:-NA}"
}

wifi_state() {
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS device show "$WIFI_IFACE" 2>/dev/null | tr '\n' ';' || true
  else
    printf 'NA'
  fi
}

write_header_if_needed() {
  if [[ ! -s "$main_log" ]]; then
    printf 'timestamp\tuptime_s\tload1\tbattery_status\tbattery_pct\tbattery_health_pct\tbattery_power_w\tcharge_start\tcharge_stop\tac_online\twifi\ttemps\n' >> "$main_log"
  fi
}

health_pct() {
  local full design
  full=$(battery_field energy_full)
  design=$(battery_field energy_full_design)
  if [[ "$full" == "NA" ]]; then full=$(battery_field charge_full); fi
  if [[ "$design" == "NA" ]]; then design=$(battery_field charge_full_design); fi
  if [[ "$full" != "NA" && "$design" != "NA" && "$design" != "0" ]]; then
    awk -v f="$full" -v d="$design" 'BEGIN{printf "%.1f", (f/d)*100}'
  else
    printf 'NA'
  fi
}

sample_once() {
  rotate_if_large "$main_log"
  rotate_if_large "$events_log"
  write_header_if_needed

  local ts uptime_s load1 status pct health power start stop ac wifi temps
  ts=$(date --iso-8601=seconds)
  uptime_s=$(awk '{printf "%.0f", $1}' /proc/uptime)
  load1=$(awk '{print $1}' /proc/loadavg)
  status=$(battery_field status)
  pct=$(battery_field capacity)
  health=$(health_pct)
  power=$(battery_power_watts)
  start=$(battery_field charge_control_start_threshold)
  [[ "$start" == "NA" ]] && start=$(battery_field charge_start_threshold)
  stop=$(battery_field charge_control_end_threshold)
  [[ "$stop" == "NA" ]] && stop=$(battery_field charge_stop_threshold)
  ac=$(read_file /sys/class/power_supply/AC/online)
  wifi=$(wifi_state | tr '\t' ' ')
  temps=$(temps_summary | tr '\t' ' ')

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$uptime_s" "$load1" "$status" "$pct" "$health" "$power" "$start" "$stop" "$ac" "$wifi" "$temps" >> "$main_log"
}

snapshot() {
  {
    echo "# snapshot $(date --iso-8601=seconds)"
    echo
    echo "## who/uptime"
    hostnamectl 2>/dev/null || true
    uptime || true
    who -b || true
    last -x reboot shutdown 2>/dev/null | head -20 || true
    echo
    echo "## battery"
    grep -H . /sys/class/power_supply/$BAT/* 2>/dev/null | sed 's/^/  /' || true
    echo
    echo "## AC"
    grep -H . /sys/class/power_supply/AC/* 2>/dev/null | sed 's/^/  /' || true
    echo
    echo "## network"
    ip addr || true
    ip route || true
    nmcli device status 2>/dev/null || true
    echo
    echo "## temperatures"
    for z in /sys/class/thermal/thermal_zone*; do grep -H . "$z/type" "$z/temp" 2>/dev/null; done
    command -v sensors >/dev/null 2>&1 && sensors || true
    echo
    echo "## failed services"
    systemctl --failed --no-pager 2>/dev/null || true
    echo
    echo "## current boot critical logs"
    journalctl -b -p warning..alert -n 200 --no-pager 2>/dev/null || true
    echo
    echo "## previous boot ending logs"
    journalctl -b -1 -n 200 --no-pager 2>/dev/null || true
  } | tee "$snapshot_log"
  echo "Wrote $snapshot_log"
}

case "${1:-monitor}" in
  once) sample_once ;;
  snapshot) snapshot ;;
  monitor)
    echo "Starting health monitor: interval=${INTERVAL}s logs=$LOG_DIR" | tee -a "$events_log"
    while true; do
      sample_once || echo "$(date --iso-8601=seconds) sample failed" >> "$events_log"
      sleep "$INTERVAL"
    done
    ;;
  *)
    echo "Usage: $0 [monitor|once|snapshot]"
    echo "Logs: $LOG_DIR"
    exit 2
    ;;
esac
