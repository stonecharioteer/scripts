# X13 Flow laptop helper scripts

Runtime helpers for using the ASUS ROG X13 Flow as a mostly headless/tent-mode Linux server.

Installation steps such as systemd units, sysctl files, LightDM configuration, lid handling, and GPU/display mitigation are managed by the `laptop-health` role in [`distributed-dotfiles`](https://github.com/stonecharioteer/distributed-dotfiles). This directory keeps the reusable scripts that should not live in the Qtile dotfiles repository.

## Scripts

### `screen.sh`

Controls the laptop panel/backlight and the `x13-screen-off.timer` keep-off unit installed by Ansible.

```bash
./screen.sh --status
./screen.sh --off
./screen.sh --on
```

The Ansible role installs systemd units that call:

```bash
~/code/checkouts/personal/scripts/laptop/x13-flow/screen.sh --apply-off
```

### `stats.sh`

Summarizes `/var/log/hang-health.log`, which is produced by the `laptop-health` role.

```bash
./stats.sh
./stats.sh --short
./stats.sh --watch 10s
```

Requirements:

- `gum` for the table/status UI
- `uv` for `--watch`, which runs `stats.py`

### `stats.py`

Rich live dashboard for hang-health snapshots. Normally launched through:

```bash
./stats.sh --watch
```

### `laptop-hang-rca.md`

RCA notes and post-incident investigation checklist for previous X13 Flow hangs/reboots.

## Related automation

Run the distributed-dotfiles playbook/shortcut for the laptop to install the system-level pieces:

```bash
just bootstrap x13-flow.home.arpa
```

Relevant inventory flags live in `distributed-dotfiles`:

- `enable_laptop_health_monitoring`
- `enable_laptop_lid_ignore`
- `enable_x13_screen_keepoff`
- `enable_lightdm_display_sleep`
- `enable_laptop_panic_reboot`
- `enable_nouveau_blacklist_fix`
- `enable_nvidia_integrated_mode`
