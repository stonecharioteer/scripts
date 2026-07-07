# Agent Notes for `laptop/x13-flow`

This folder contains RCA notes and utility scripts for running the ASUS ROG X13 Flow (`rog-x13-flow`) as a mostly headless/tent-mode server.

## Current state

- Current mitigation kernel: `6.8.0-90-generic`
- Problem kernel: `6.8.0-110-generic`
- GRUB default was changed with `./set-grub-kernel-6.8.0-90.sh`.
- Kernel oops auto-reboot was enabled with `./setup-panic-on-oops.sh`:
  - `kernel.panic_on_oops = 1`
  - `kernel.panic = 30`
- NVIDIA dGPU should remain disabled for server use.
- `supergfxctl` graphics mode should be `Integrated`.
- LightDM/display manager may be disabled; machine may run in `multi-user.target`.

## Important files

- `laptop-hang-rca.md` — primary RCA/timeline; update this after meaningful findings.
- `screen.sh` — headless/tent-mode panel control:
  - `./screen.sh --off`
  - `./screen.sh --on`
  - `./screen.sh --status`
- `setup-hang-monitoring.sh` — installs `/var/log/hang-health.log` collection.
- `setup-panic-on-oops.sh` — configures auto-reboot after kernel oops/panic.
- `set-grub-kernel-6.8.0-90.sh` — sets GRUB default to older stable-test kernel.

## Investigation pattern after a hang/reboot

Run:

```bash
last -x | head -30
journalctl --list-boots --no-pager | tail
journalctl -b -1 -p warning..alert --no-pager | tail -300
journalctl -b -1 -k --no-pager | tail -300
tail -500 /var/log/hang-health.log
uname -r
prime-select query 2>/dev/null || true
supergfxctl -g 2>/dev/null || true
lsmod | grep '^nvidia' || true
nvidia-smi || true
```

Interpretation notes:

- `kmem_cache_alloc`, `anon_vma_*`, `copy_process`, `kernel_clone`, fork/exec faults point to kernel VM/slab corruption or RAM/hardware instability.
- Normal health snapshots before failure plus no OOM/thermal spike makes thermal/OOM unlikely.
- SSH can fail even while console logging works if fork/exec/memory allocation paths are corrupted.
- If `6.8.0-90-generic` stays stable, suspect `6.8.0-110-generic` regression.
- If the issue recurs across kernels, recommend overnight memtest/hardware diagnostics.

## Be careful

- Do not assume display sleep is the root cause; the 2026-06-23 incident was a kernel oops/VM corruption pattern.
- Do not re-enable NVIDIA/dGPU unless explicitly needed.
- Prefer updating `laptop-hang-rca.md` with dates/timeline when new evidence is found.
