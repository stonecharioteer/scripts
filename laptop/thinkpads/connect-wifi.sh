#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-wlp0s20f3}"

log() { printf '\n==> %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v nmcli >/dev/null 2>&1 || err "nmcli not found. Install/use NetworkManager first."

read -r -p "Wi-Fi SSID: " SSID
[[ -n "$SSID" ]] || err "SSID cannot be empty."

read -r -s -p "Wi-Fi password: " PASSWORD
printf '\n'
[[ -n "$PASSWORD" ]] || err "Password cannot be empty."

log "Connecting to '$SSID' on $IFACE"

if command -v rfkill >/dev/null 2>&1; then
  sudo rfkill unblock wifi || true
fi

nmcli networking on
nmcli radio wifi on
sudo ip link set "$IFACE" up || true
nmcli device set "$IFACE" managed yes || true

log "Scanning for Wi-Fi networks"
nmcli device wifi rescan ifname "$IFACE" || true
sleep 3

if ! nmcli -t -f SSID device wifi list ifname "$IFACE" | grep -Fxq "$SSID"; then
  err "Could not see SSID '$SSID' on $IFACE. Move closer, check spelling, or rerun."
fi

log "Saving connection and enabling autoconnect"
nmcli connection delete "$SSID" >/dev/null 2>&1 || true
nmcli device wifi connect "$SSID" password "$PASSWORD" ifname "$IFACE" name "$SSID"
nmcli connection modify "$SSID" connection.autoconnect yes

log "Connected status"
nmcli -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY device show "$IFACE"
