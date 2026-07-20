#!/usr/bin/env bash
set -euo pipefail

printf 'Writing clean /etc/modprobe.d/blacklist-nouveau.conf...\n'
sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

printf 'Rebuilding initramfs...\n'
sudo update-initramfs -u

printf 'Done.\n'
