#!/usr/bin/env bash
set -euo pipefail

BACKLIGHT="${BACKLIGHT:-/sys/class/backlight/amdgpu_bl1}"
FB_BLANK="${FB_BLANK:-/sys/class/graphics/fb0/blank}"

SERVICE_NAME="${SERVICE_NAME:-x13-screen-off.timer}"

usage() {
  cat <<EOF
Usage: $0 --off|--on|--status|--apply-off

Controls the laptop panel/backlight for headless/tent mode.

Flags:
  --off        Turn the screen off and enable the keep-off systemd timer.
  --on         Disable the keep-off systemd timer and turn the screen on.
  --status     Show current screen state and keep-off timer state.
  --apply-off  Internal: turn the screen off without touching systemd.
               Used by the systemd service to avoid dependency loops.

Environment overrides:
  BACKLIGHT=$BACKLIGHT
  FB_BLANK=$FB_BLANK
  SERVICE_NAME=$SERVICE_NAME
EOF
}

write_sysfs() {
  local value="$1"
  local path="$2"

  if [[ ! -e "$path" ]]; then
    printf 'Warning: %s does not exist; skipping\n' "$path" >&2
    return 0
  fi

  if [[ ${EUID} -eq 0 ]]; then
    printf '%s\n' "$value" >"$path"
  else
    printf '%s\n' "$value" | sudo tee "$path" >/dev/null
  fi
}

enable_keep_off() {
  if command -v systemctl >/dev/null; then
    if [[ ${EUID} -eq 0 ]]; then
      systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1
    else
      sudo systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1
    fi
  fi
}

disable_keep_off() {
  if command -v systemctl >/dev/null; then
    if [[ ${EUID} -eq 0 ]]; then
      systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
      sudo systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
  fi
}

apply_off() {
  write_sysfs 4 "$BACKLIGHT/bl_power"
  write_sysfs 0 "$BACKLIGHT/brightness"
  write_sysfs 1 "$FB_BLANK"
}

screen_off() {
  apply_off
  enable_keep_off
  status
}

screen_on() {
  local max_brightness=255

  disable_keep_off

  if [[ -r "$BACKLIGHT/max_brightness" ]]; then
    max_brightness="$(<"$BACKLIGHT/max_brightness")"
  fi

  write_sysfs 0 "$FB_BLANK"
  write_sysfs 0 "$BACKLIGHT/bl_power"
  write_sysfs "$max_brightness" "$BACKLIGHT/brightness"
  status
}

print_status_header() {
  local screen_state="$1"
  local keepoff_state="$2"

  if command -v gum >/dev/null; then
    gum style --border rounded --padding "0 1" --margin "0 0 1 0" \
      --border-foreground "${status_color:-212}" --foreground "${status_color:-212}" --bold \
      "Screen: $screen_state" \
      "Keep-off service: $keepoff_state"
  else
    printf 'Screen: %s\n' "$screen_state"
    printf 'Keep-off service: %s\n' "$keepoff_state"
  fi
}

print_status_details() {
  if command -v gum >/dev/null; then
    gum style --foreground "${status_color:-244}" --bold "Details"
    gum format <<EOF
- **Backlight device:** \`$BACKLIGHT\`
- **bl_power:** \`$bl_power\` ($bl_power_label)
- **brightness:** \`$brightness / $max_brightness\`
- **actual_brightness:** \`$actual_brightness\`
- **framebuffer blank:** \`$fb_blank\`
- **timer:** \`$SERVICE_NAME\`
- **timer enabled:** \`$timer_enabled\`
- **timer active:** \`$timer_active\`
EOF
  else
    printf '\nDetails:\n'
    printf '  Backlight device: %s\n' "$BACKLIGHT"
    printf '  bl_power: %s (%s)\n' "$bl_power" "$bl_power_label"
    printf '  brightness: %s / %s\n' "$brightness" "$max_brightness"
    printf '  actual_brightness: %s\n' "$actual_brightness"
    printf '  framebuffer blank: %s\n' "$fb_blank"
    printf '  timer: %s\n' "$SERVICE_NAME"
    printf '  timer enabled: %s\n' "$timer_enabled"
    printf '  timer active: %s\n' "$timer_active"
  fi
}

status() {
  local bl_power="unknown"
  local brightness="unknown"
  local actual_brightness="unknown"
  local max_brightness="unknown"
  local fb_blank="unknown"
  local timer_enabled="unknown"
  local timer_active="unknown"
  local screen_state="unknown"
  local keepoff_state="unknown"
  local bl_power_label="unknown"
  local status_color="244"

  [[ -r "$BACKLIGHT/bl_power" ]] && bl_power="$(<"$BACKLIGHT/bl_power")"
  [[ -r "$BACKLIGHT/brightness" ]] && brightness="$(<"$BACKLIGHT/brightness")"
  [[ -r "$BACKLIGHT/actual_brightness" ]] && actual_brightness="$(<"$BACKLIGHT/actual_brightness")"
  [[ -r "$BACKLIGHT/max_brightness" ]] && max_brightness="$(<"$BACKLIGHT/max_brightness")"
  [[ -r "$FB_BLANK" ]] && fb_blank="$(<"$FB_BLANK")"
  [[ -z "$fb_blank" ]] && fb_blank="unknown"

  if [[ "$bl_power" == "4" ]]; then
    bl_power_label="off"
  elif [[ "$bl_power" == "0" ]]; then
    bl_power_label="on"
  fi

  if [[ "$bl_power" == "4" && "$actual_brightness" == "0" ]]; then
    screen_state="off / backlight disabled"
    status_color="42"
  elif [[ "$bl_power" == "0" && "$actual_brightness" != "0" && "$actual_brightness" != "unknown" ]]; then
    screen_state="on / backlight active"
    status_color="196"
  elif [[ "$brightness" == "0" || "$actual_brightness" == "0" ]]; then
    screen_state="mostly off / brightness is zero"
    status_color="42"
  else
    screen_state="unknown"
    status_color="244"
  fi

  if command -v systemctl >/dev/null; then
    timer_enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    timer_active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  fi

  if [[ "$timer_enabled" == "enabled" && "$timer_active" == "active" ]]; then
    keepoff_state="enabled and running"
  elif [[ "$timer_enabled" == "enabled" ]]; then
    keepoff_state="enabled but not currently active"
  elif [[ "$timer_enabled" == "disabled" ]]; then
    keepoff_state="disabled"
  elif [[ "$timer_enabled" == "not-found" ]]; then
    keepoff_state="not installed"
  else
    keepoff_state="$timer_enabled/$timer_active"
  fi

  print_status_header "$screen_state" "$keepoff_state"
  print_status_details
}

case "${1:-}" in
  --off)
    screen_off
    ;;
  --on)
    screen_on
    ;;
  --status)
    status
    ;;
  --apply-off)
    apply_off
    ;;
  -h|--help|'')
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
