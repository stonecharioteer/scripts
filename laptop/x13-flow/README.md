# X13 Flow laptop helper scripts

Runtime helpers and manual installers for the ASUS ROG X13 Flow as a mostly
headless / tent-mode Linux machine.

Part of the unified [`laptop/`](../README.md) tree alongside
[`thinkpads/`](../thinkpads/README.md).

## Prefer Ansible

System pieces (systemd units, sysctl, LightDM hooks, lid handling, GPU mode,
nouveau blacklist, hang/NVMe timers) are managed by the `laptop-health` role in
[`distributed-dotfiles`](https://github.com/stonecharioteer/distributed-dotfiles).

Scripts named `setup-*.sh` / `install-*.sh` / `enable-*.sh` / `fix-*.sh` /
`disable-*.sh` are **manual fallbacks** that mirror that role. Use them when
you cannot run the playbook; do not treat them as a second source of truth on
already-Ansible-managed hosts.

```bash
# Preferred
./bootstrap gui -i inventory/hosts.yml -- --limit x13-flow.home.arpa --tags laptop
```

Inventory flags (distributed-dotfiles):

| Flag | Manual script counterpart |
|------|---------------------------|
| `enable_laptop_health_monitoring` | `setup-hang-monitoring.sh`, `setup-reboot-investigation.sh` |
| `enable_laptop_lid_ignore` | `setup-lid-ignore.sh` |
| `enable_laptop_panic_reboot` | `setup-panic-on-oops.sh`, `setup-reboot-investigation.sh` |
| `enable_nvme_health_monitoring` | `setup-nvme-health-monitoring.sh` |
| `enable_x13_screen_keepoff` | `install-screen-keepoff-service.sh` (+ runtime `screen.sh`) |
| `enable_lightdm_display_sleep` | `enable-lightdm-display-sleep.sh` |
| `enable_nvidia_integrated_mode` | `disable-nvidia-dgpu.sh` |
| `enable_nouveau_blacklist_fix` | `fix-blacklist-nouveau.sh` |

## Runtime helpers (keep using these)

### `screen.sh`

Controls the laptop panel/backlight and cooperates with the
`x13-screen-off.timer` unit installed by Ansible (or
`install-screen-keepoff-service.sh`).

```bash
./screen.sh --status
./screen.sh --off
./screen.sh --on
./screen.sh --apply-off   # used by the systemd unit
```

Ansible units call:

```bash
~/code/checkouts/personal/scripts/laptop/x13-flow/screen.sh --apply-off
```

### `stats.sh` / `stats.py`

Summarize `/var/log/hang-health.log` from the hang-health monitor.

```bash
./stats.sh
./stats.sh --short
./stats.sh --watch 10s    # needs uv; runs stats.py
```

Requirements: `gum`; `uv` for `--watch`.

### `laptop-hang-rca.md`

RCA timeline and post-incident checklist for prior X13 hangs/reboots. Update
this when new evidence shows up.

### `agents.md`

Operator/agent notes: current mitigation kernel, investigation commands, and
careful-ops guidance.

## Manual install / repair scripts

| Script | Purpose |
|--------|---------|
| `setup-lid-ignore.sh` | logind: ignore lid close (headless/server) |
| `setup-hang-monitoring.sh` | periodic hang/health snapshots → `/var/log/hang-health.log` |
| `setup-nvme-health-monitoring.sh` | daily NVMe SMART snapshots |
| `setup-panic-on-oops.sh` | `kernel.panic_on_oops` + timed reboot after oops |
| `setup-reboot-investigation.sh` | stronger panic sysctls + pstore helpers |
| `install-screen-keepoff-service.sh` | systemd service/timer that runs `screen.sh --apply-off` |
| `enable-lightdm-display-sleep.sh` | LightDM greeter DPMS/blanking hooks |
| `disable-nvidia-dgpu.sh` | `prime-select intel`, stop nvidia-persistenced |
| `fix-blacklist-nouveau.sh` | clean nouveau blacklist + `update-initramfs` |
| `install-asus-linux-tools.sh` | build/install `supergfxctl` (optional `asusctl`) from source |
| `set-grub-kernel-6.8.0-90.sh` | pin GRUB default to mitigation kernel `6.8.0-90-generic` |

## Related docs

- [`agents.md`](agents.md) — live ops notes for this machine class
- [`laptop-hang-rca.md`](laptop-hang-rca.md) — incident history
