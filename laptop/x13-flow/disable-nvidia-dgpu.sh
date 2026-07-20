#!/usr/bin/env bash
set -euo pipefail

printf 'Current PRIME mode: '
prime-select query || true

printf '\nSwitching to integrated-GPU mode (prime-select intel)...\n'
sudo prime-select intel

printf '\nDisabling NVIDIA persistence daemon...\n'
sudo systemctl disable --now nvidia-persistenced.service 2>/dev/null || true

printf '\nCurrent NVIDIA module/process state before reboot:\n'
lsmod | grep '^nvidia' || printf 'No NVIDIA kernel modules listed.\n'

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || true
else
    printf 'nvidia-smi not found.\n'
fi

printf '\nDone. Reboot when convenient for the PRIME mode change to fully take effect.\n'
printf 'After reboot, verify with:\n'
printf '  prime-select query\n'
printf '  lsmod | grep nvidia\n'
printf '  nvidia-smi\n'
