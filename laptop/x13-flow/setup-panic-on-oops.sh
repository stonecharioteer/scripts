#!/usr/bin/env bash
set -euo pipefail

printf 'Installing kernel oops auto-reboot sysctl config...\n'

sudo tee /etc/sysctl.d/99-panic-on-oops.conf >/dev/null <<'EOF'
# Reboot automatically if the kernel hits an oops/panic.
# This is intended for headless/server use so the machine does not remain
# unreachable over SSH indefinitely after kernel memory corruption.
kernel.panic_on_oops = 1
kernel.panic = 30
EOF

sudo sysctl --system

printf '\nDone. Current values:\n'
sysctl kernel.panic_on_oops kernel.panic
