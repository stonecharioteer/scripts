#!/usr/bin/env bash
set -euo pipefail

GRUB_DEFAULT_FILE="/etc/default/grub"
KERNEL_PARAM="pcie_aspm=off"

usage() {
  cat <<'EOF'
Usage: ./setup-pcie-aspm-mitigation.sh [COMMAND]

Mitigate suspected ASUS/AMD PCIe power-management hangs by adding
pcie_aspm=off to the GRUB kernel command line.

Commands:
  enable    Add pcie_aspm=off and run update-grub (default)
  disable   Remove pcie_aspm=off and run update-grub
  status    Show current config and running kernel command line
  -h, --help

After enable/disable, reboot manually and verify with:
  cat /proc/cmdline
EOF
}

require_root_tooling() {
  if [[ ! -r "$GRUB_DEFAULT_FILE" ]]; then
    printf 'ERROR: cannot read %s\n' "$GRUB_DEFAULT_FILE" >&2
    exit 1
  fi
  if ! command -v update-grub >/dev/null; then
    printf 'ERROR: update-grub not found\n' >&2
    exit 1
  fi
}

backup_grub() {
  local backup
  backup="$GRUB_DEFAULT_FILE.bak.$(date +%Y%m%d%H%M%S)"
  printf 'Backing up %s to %s\n' "$GRUB_DEFAULT_FILE" "$backup"
  sudo cp -a "$GRUB_DEFAULT_FILE" "$backup"
}

show_status() {
  printf 'Configured GRUB default cmdline:\n'
  if sudo grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_FILE"; then
    true
  else
    printf '  GRUB_CMDLINE_LINUX_DEFAULT is not set\n'
  fi

  printf '\nRunning kernel cmdline:\n'
  cat /proc/cmdline

  printf '\nMitigation configured in GRUB: '
  if sudo grep -Eq "^GRUB_CMDLINE_LINUX_DEFAULT=.*(^|[[:space:]])${KERNEL_PARAM}([[:space:]]|\")" "$GRUB_DEFAULT_FILE"; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi

  printf 'Mitigation active in current boot: '
  if grep -Eq "(^|[[:space:]])${KERNEL_PARAM}([[:space:]]|$)" /proc/cmdline; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi

  printf '\nNoisy bridge runtime PM, if present:\n'
  for path in \
    /sys/bus/pci/devices/0000:00:08.1/power/control \
    /sys/bus/pci/devices/0000:00:08.1/power/runtime_status; do
    if [[ -e "$path" ]]; then
      printf '  %s=' "$path"
      cat "$path"
    fi
  done
}

enable_mitigation() {
  require_root_tooling

  if sudo grep -Eq "^GRUB_CMDLINE_LINUX_DEFAULT=.*(^|[[:space:]])${KERNEL_PARAM}([[:space:]]|\")" "$GRUB_DEFAULT_FILE"; then
    printf '%s is already configured in %s\n' "$KERNEL_PARAM" "$GRUB_DEFAULT_FILE"
    show_status
    return 0
  fi

  backup_grub

  if sudo grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_FILE"; then
    sudo sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"(.*)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${KERNEL_PARAM}\"|" "$GRUB_DEFAULT_FILE"
  else
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$KERNEL_PARAM" | sudo tee -a "$GRUB_DEFAULT_FILE" >/dev/null
  fi

  printf 'Running update-grub...\n'
  sudo update-grub

  printf '\nDone. Reboot manually, then verify with:\n  cat /proc/cmdline\n\nExpected to include:\n  %s\n' "$KERNEL_PARAM"
}

disable_mitigation() {
  require_root_tooling

  if ! sudo grep -Eq "^GRUB_CMDLINE_LINUX_DEFAULT=.*(^|[[:space:]])${KERNEL_PARAM}([[:space:]]|\")" "$GRUB_DEFAULT_FILE"; then
    printf '%s is not configured in %s\n' "$KERNEL_PARAM" "$GRUB_DEFAULT_FILE"
    show_status
    return 0
  fi

  backup_grub
  sudo sed -i -E \
    -e "s/[[:space:]]+${KERNEL_PARAM}//g" \
    -e "s/${KERNEL_PARAM}[[:space:]]+//g" \
    -e "s/${KERNEL_PARAM}//g" \
    "$GRUB_DEFAULT_FILE"

  printf 'Running update-grub...\n'
  sudo update-grub

  printf '\nDone. Reboot manually, then verify with:\n  cat /proc/cmdline\n\nExpected not to include:\n  %s\n' "$KERNEL_PARAM"
}

command="${1:-enable}"
case "$command" in
  enable)
    enable_mitigation
    ;;
  disable)
    disable_mitigation
    ;;
  status)
    show_status
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
