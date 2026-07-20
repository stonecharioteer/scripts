#!/usr/bin/env bash
set -euo pipefail

# Install ASUS Linux graphics tooling on Linux Mint 22.x.
#
# Installs from upstream source because the old ASUS Linux OBS apt repo does
# not currently publish xUbuntu_24.04 packages.
#
# Default behavior is conservative/idempotent:
#   - install missing build dependencies only
#   - install supergfxctl only if missing
#   - install asusctl only if missing and INSTALL_ASUSCTL=1
#   - do not git pull/rebuild already-installed tools unless --update is passed
#
# Usage:
#   ./install-asus-linux-tools.sh
#   ./install-asus-linux-tools.sh --update
#
# Set INSTALL_ASUSCTL=0 to skip asusctl/asusd.

SRC_ROOT="${SRC_ROOT:-$HOME/.local/src/asus-linux}"
INSTALL_ASUSCTL="${INSTALL_ASUSCTL:-1}"
UPDATE=0

for arg in "$@"; do
  case "$arg" in
    --update) UPDATE=1 ;;
    -h|--help)
      sed -n '1,35p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--update]" >&2
      exit 2
      ;;
  esac
done

have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_pkg() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

install_missing_pkgs() {
  local missing=()
  for pkg in "$@"; do
    if ! have_pkg "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    printf 'All required apt packages already installed.\n'
    return 0
  fi

  printf 'Installing missing apt packages: %s\n' "${missing[*]}"
  sudo apt update
  sudo apt install -y "${missing[@]}"
}

clone_or_update() {
  local repo_url="$1"
  local dest="$2"

  if [ -d "$dest/.git" ]; then
    if [ "$UPDATE" = "1" ]; then
      git -C "$dest" pull --ff-only
    else
      printf 'Source checkout exists, not updating without --update: %s\n' "$dest"
    fi
  else
    git clone "$repo_url" "$dest"
  fi
}

printf 'Cleaning any failed ASUS Linux OBS apt repo entries...\n'
sudo rm -f /etc/apt/sources.list.d/asus-linux.list /etc/apt/trusted.gpg.d/asus-linux.gpg

printf 'Checking build prerequisites...\n'
install_missing_pkgs git curl build-essential pkg-config make libudev-dev

if ! have_cmd cargo || ! have_cmd rustc; then
  printf '\nRust/cargo not found. Install Rust first, then rerun this script:\n'
  printf '  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh\n'
  printf '  source ~/.cargo/env\n'
  exit 1
fi

mkdir -p "$SRC_ROOT"

if have_cmd supergfxctl && [ "$UPDATE" = "0" ]; then
  printf '\nsupergfxctl already installed; skipping rebuild. Use --update to rebuild/update.\n'
else
  printf '\nInstalling/updating supergfxctl from source...\n'
  clone_or_update https://gitlab.com/asus-linux/supergfxctl.git "$SRC_ROOT/supergfxctl"
  make -C "$SRC_ROOT/supergfxctl"
  sudo make -C "$SRC_ROOT/supergfxctl" install
fi

sudo systemctl daemon-reload
sudo systemctl enable --now supergfxd

if [ "$INSTALL_ASUSCTL" = "1" ]; then
  if have_cmd asusctl && systemctl list-unit-files asusd.service >/dev/null 2>&1 && [ "$UPDATE" = "0" ]; then
    printf '\nasusctl/asusd already installed; skipping rebuild. Use --update to rebuild/update.\n'
    sudo systemctl enable --now asusd || true
  else
    printf '\nInstalling/updating asusctl/asusd from source...\n'
    install_missing_pkgs libclang-dev libudev-dev libfontconfig-dev cmake libxkbcommon-dev
    clone_or_update https://gitlab.com/asus-linux/asusctl.git "$SRC_ROOT/asusctl"
    make -C "$SRC_ROOT/asusctl"
    sudo make -C "$SRC_ROOT/asusctl" install
    sudo systemctl daemon-reload
    sudo systemctl enable --now asusd
  fi
else
  printf '\nSkipping asusctl/asusd because INSTALL_ASUSCTL=0.\n'
fi

printf '\nInstalled status:\n'
SYSTEMD_PAGER=cat systemctl --no-pager --full status supergfxd 2>/dev/null | sed -n '1,60p' || true
if [ "$INSTALL_ASUSCTL" = "1" ]; then
  SYSTEMD_PAGER=cat systemctl --no-pager --full status asusd 2>/dev/null | sed -n '1,60p' || true
fi

printf '\nGraphics mode:\n'
# supergfxctl can occasionally block while the daemon is probing PCI state; don't let
# the installer appear hung just because status probing is slow.
timeout 10s supergfxctl -g || printf 'supergfxctl -g did not return within 10s; check later with: supergfxctl -g\n'

printf '\nUseful commands:\n'
printf '  supergfxctl -g                  # get current graphics mode\n'
printf '  sudo supergfxctl -m Integrated  # switch to integrated-only mode\n'
printf '  sudo supergfxctl -m Hybrid      # switch back to hybrid\n'
printf '  supergfxctl --help\n'
printf '  asusctl --help                  # if asusctl was installed\n'
printf '\nBasic kernel platform profile fan/performance controls:\n'
printf '  cat /sys/firmware/acpi/platform_profile_choices\n'
printf '  cat /sys/firmware/acpi/platform_profile\n'
printf '  echo quiet | sudo tee /sys/firmware/acpi/platform_profile\n'
printf '  echo balanced | sudo tee /sys/firmware/acpi/platform_profile\n'
printf '  echo performance | sudo tee /sys/firmware/acpi/platform_profile\n'
printf '\nReboot after changing graphics mode.\n'
