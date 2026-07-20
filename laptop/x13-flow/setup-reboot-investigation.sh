#!/usr/bin/env bash
set -euo pipefail

INSTALL_KDUMP="${INSTALL_KDUMP:-0}"
PSTORE_ARCHIVE_DIR="${PSTORE_ARCHIVE_DIR:-/var/log/pstore-archive}"

printf 'Installing sudden-reboot investigation tooling...\n'

printf '\n[1/5] Enabling stronger panic/reboot sysctls...\n'
sudo tee /etc/sysctl.d/98-reboot-investigation.conf >/dev/null <<'EOF'
# Reboot automatically after kernel failures so a headless machine does not stay wedged.
# These settings are intentionally diagnostic/mitigation-oriented.
kernel.panic = 30
kernel.panic_on_oops = 1
kernel.softlockup_panic = 1
kernel.hung_task_panic = 1
kernel.panic_on_warn = 0
EOF
sudo sysctl --system >/dev/null
sysctl kernel.panic kernel.panic_on_oops kernel.softlockup_panic kernel.hung_task_panic kernel.panic_on_warn

printf '\n[2/5] Ensuring pstore is mounted when available...\n'
sudo install -d -m 0755 /sys/fs/pstore || true
if ! mountpoint -q /sys/fs/pstore; then
  sudo mount -t pstore pstore /sys/fs/pstore 2>/dev/null || true
fi
if mountpoint -q /sys/fs/pstore; then
  printf 'pstore is mounted at /sys/fs/pstore\n'
else
  printf 'WARNING: pstore is not mounted/available. Firmware may not expose EFI pstore/ramoops.\n' >&2
fi

printf '\n[3/5] Installing pstore archive service...\n'
sudo install -d -m 0755 /usr/local/sbin "$PSTORE_ARCHIVE_DIR"
sudo tee /usr/local/sbin/archive-pstore >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

src=/sys/fs/pstore
dst="$PSTORE_ARCHIVE_DIR"

[ -d "\$src" ] || exit 0
mkdir -p "\$dst"

if ! find "\$src" -mindepth 1 -maxdepth 1 -type f -print -quit | grep -q .; then
  exit 0
fi

stamp="\$(date --iso-8601=seconds | tr ':' '-')"
out="\$dst/\$stamp"
mkdir -p "\$out"
cp -a "\$src"/* "\$out"/ 2>/dev/null || true

# Keep a lightweight index for quick post-reboot checks.
{
  echo "===== pstore archive \$stamp ====="
  find "\$out" -maxdepth 1 -type f -printf '%f %s bytes\\n' | sort
  echo
} >> "\$dst/index.log"
EOF
sudo chmod 0755 /usr/local/sbin/archive-pstore

sudo tee /etc/systemd/system/archive-pstore.service >/dev/null <<'EOF'
[Unit]
Description=Archive pstore crash logs after boot
DefaultDependencies=no
After=sysinit.target
Before=multi-user.target
ConditionPathExists=/sys/fs/pstore

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/archive-pstore

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable archive-pstore.service >/dev/null
sudo systemctl start archive-pstore.service || true
printf 'pstore archives will be saved under: %s\n' "$PSTORE_ARCHIVE_DIR"

printf '\n[4/5] De-phasing x13 screen keep-off timer if installed...\n'
if systemctl list-unit-files x13-screen-off.timer >/dev/null 2>&1; then
  sudo install -d -m 0755 /etc/systemd/system/x13-screen-off.timer.d
  sudo tee /etc/systemd/system/x13-screen-off.timer.d/10-dephase.conf >/dev/null <<'EOF'
[Timer]
# Avoid running at the exact same second as hang-health-snapshot.timer.
OnBootSec=
OnUnitActiveSec=
AccuracySec=
OnBootSec=45s
OnUnitActiveSec=65s
AccuracySec=5s
EOF
  sudo systemctl daemon-reload
  if systemctl is-enabled x13-screen-off.timer >/dev/null 2>&1; then
    sudo systemctl restart x13-screen-off.timer || true
  fi
  printf 'x13-screen-off.timer now runs offset from hang-health-snapshot.timer.\n'
else
  printf 'x13-screen-off.timer not installed; skipping.\n'
fi

printf '\n[5/5] Optional kdump/crash dump setup...\n'
if [[ "$INSTALL_KDUMP" == "1" ]]; then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y linux-crashdump kdump-tools
  printf 'kdump packages installed. Review /etc/default/kdump-tools and reboot when convenient.\n'
else
  printf 'Skipping kdump install by default. To install it, rerun with:\n'
  printf '  INSTALL_KDUMP=1 %s\n' "$0"
fi

printf '\nQuick hardware/firmware commands to run manually if reboots continue:\n'
printf '  sudo smartctl -a /dev/nvme0n1\n'
printf '  fwupdmgr get-updates\n'
printf '  memtest86+ / firmware memory diagnostics overnight\n'

printf '\nDone. After the next unexpected reboot, check:\n'
printf '  sudo find %s -maxdepth 2 -type f -print\n' "$PSTORE_ARCHIVE_DIR"
printf '  sudo grep -R . %s /sys/fs/pstore 2>/dev/null | less\n' "$PSTORE_ARCHIVE_DIR"
printf '  journalctl -b -1 -k --no-pager | tail -300\n'
