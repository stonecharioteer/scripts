#!/usr/bin/env bash
set -u

BAT="${BAT:-BAT0}"
BAT_PATH="/sys/class/power_supply/${BAT}"
EXPECTED_START="${EXPECTED_START:-55}"
EXPECTED_STOP="${EXPECTED_STOP:-60}"
EXPECTED_IP="${EXPECTED_IP:-192.168.100.189}"
WIFI_IFACE="${WIFI_IFACE:-wlp0s20f3}"
CONNECTION="${CONNECTION:-NefariousNetwork}"

ok=0
fail=0
warn=0

pass() { printf 'PASS: %s\n' "$*"; ok=$((ok+1)); }
fail_msg() { printf 'FAIL: %s\n' "$*"; fail=$((fail+1)); }
warn_msg() { printf 'WARN: %s\n' "$*"; warn=$((warn+1)); }
section() { printf '\n== %s ==\n' "$*"; }

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label = $actual"
  else
    fail_msg "$label expected $expected, got ${actual:-<empty>}"
  fi
}

section "Battery charge thresholds"
if [[ -d "$BAT_PATH" ]]; then
  status="$(cat "$BAT_PATH/status" 2>/dev/null || true)"
  capacity="$(cat "$BAT_PATH/capacity" 2>/dev/null || true)"
  start="$(cat "$BAT_PATH/charge_control_start_threshold" 2>/dev/null || cat "$BAT_PATH/charge_start_threshold" 2>/dev/null || true)"
  stop="$(cat "$BAT_PATH/charge_control_end_threshold" 2>/dev/null || cat "$BAT_PATH/charge_stop_threshold" 2>/dev/null || true)"

  printf 'Battery: %s\nStatus: %s\nCapacity: %s%%\nStart threshold: %s%%\nStop threshold: %s%%\n' "$BAT" "${status:-unknown}" "${capacity:-unknown}" "${start:-unknown}" "${stop:-unknown}"
  check_eq "start threshold" "$EXPECTED_START" "$start"
  check_eq "stop threshold" "$EXPECTED_STOP" "$stop"
else
  fail_msg "battery path not found: $BAT_PATH"
fi

section "Persistence service"
if systemctl list-unit-files battery-charge-threshold.service >/dev/null 2>&1; then
  enabled="$(systemctl is-enabled battery-charge-threshold.service 2>/dev/null || true)"
  active="$(systemctl is-active battery-charge-threshold.service 2>/dev/null || true)"
  [[ "$enabled" == "enabled" ]] && pass "battery-charge-threshold.service enabled" || fail_msg "battery-charge-threshold.service enabled state: ${enabled:-unknown}"
  [[ "$active" == "active" || "$active" == "inactive" ]] && pass "battery-charge-threshold.service exists, active state: $active" || warn_msg "battery-charge-threshold.service active state: ${active:-unknown}"
else
  fail_msg "battery-charge-threshold.service not found"
fi

section "Lid-close behavior"
conf="$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null || true)"
for key in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
  value="$(printf '%s\n' "$conf" | awk -F= -v k="$key" '$1==k {v=$2} END {print v}')"
  check_eq "$key" "ignore" "$value"
done
if systemctl is-active --quiet systemd-logind; then
  pass "systemd-logind active"
else
  fail_msg "systemd-logind not active"
fi

section "Wi-Fi/static IP"
if command -v nmcli >/dev/null 2>&1; then
  state="$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null || true)"
  con="$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null || true)"
  ip4="$(nmcli -g IP4.ADDRESS device show "$WIFI_IFACE" 2>/dev/null | head -n1 | cut -d/ -f1 || true)"
  method="$(nmcli -g ipv4.method connection show "$CONNECTION" 2>/dev/null || true)"

  printf 'Interface: %s\nState: %s\nConnection: %s\nIPv4: %s\nIPv4 method: %s\n' "$WIFI_IFACE" "${state:-unknown}" "${con:-unknown}" "${ip4:-unknown}" "${method:-unknown}"
  [[ "$state" == *connected* || "$state" == "100 (connected)" ]] && pass "$WIFI_IFACE connected" || fail_msg "$WIFI_IFACE not connected: ${state:-unknown}"
  check_eq "connection" "$CONNECTION" "$con"
  check_eq "static IP" "$EXPECTED_IP" "$ip4"
  check_eq "IPv4 method" "manual" "$method"
else
  fail_msg "nmcli not found"
fi

section "Reachability"
ping -c 1 -W 2 192.168.100.1 >/dev/null 2>&1 && pass "gateway reachable" || fail_msg "gateway not reachable"
ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && pass "internet IP reachable" || warn_msg "internet IP ping failed"

section "Summary"
printf 'PASS=%d WARN=%d FAIL=%d\n' "$ok" "$warn" "$fail"
if (( fail > 0 )); then
  exit 1
fi
exit 0
