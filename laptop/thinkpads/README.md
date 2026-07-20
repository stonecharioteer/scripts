# ThinkPad headless laptop helpers

Scripts for maintaining ThinkPads (T14, P1, etc.) as mostly-headless
laptop/servers.

Part of the unified [`laptop/`](../README.md) tree alongside
[`x13-flow/`](../x13-flow/README.md).

## Prefer Ansible

Most install steps are idempotent Ansible in the `laptop-health` role of
[`distributed-dotfiles`](https://github.com/stonecharioteer/distributed-dotfiles).

Keep these scripts for:

- the continuous health monitor binary referenced by the user systemd unit
- one-shot manual setup/repair when playbooks are unavailable
- diagnostics and verification

```bash
# Preferred
./bootstrap headless -i inventory/hosts.yml -- --limit HOST --tags laptop
```

| Inventory flag | Manual script counterpart |
|----------------|---------------------------|
| `enable_laptop_lid_ignore` | `setup-headless-lid-battery.sh` (lid section) |
| `enable_battery_charge_thresholds` | `setup-headless-lid-battery.sh` (battery section) |
| `enable_headless_health_monitor` | `setup-headless-health-monitor.sh` + `headless-health-monitor.sh` |
| `enable_ssh_long_lived` | `setup-ssh-long-lived.sh` |
| fish default shell (base playbook) | `install-fish-default-shell.sh` |

## Runtime / always useful

### `headless-health-monitor.sh`

Periodic health samples under `~/headless-monitor/logs/`.

```bash
./headless-health-monitor.sh once
./headless-health-monitor.sh snapshot
./headless-health-monitor.sh monitor
```

Ansible wires a user systemd unit to:

```text
~/code/checkouts/personal/scripts/laptop/thinkpads/headless-health-monitor.sh monitor
```

### `verify-headless-laptop.sh`

Checks battery thresholds, lid config, Wi-Fi/static IP expectations, and reachability.

```bash
./verify-headless-laptop.sh
EXPECTED_IP=192.168.100.189 ./verify-headless-laptop.sh
```

## Manual install / repair scripts

| Script | Purpose |
|--------|---------|
| `setup-headless-lid-battery.sh` | lid-close ignore + battery charge thresholds (default 55–60%) |
| `setup-headless-health-monitor.sh` | user systemd unit for the health monitor (+ linger hint) |
| `setup-ssh-long-lived.sh` | SSH client/server keepalives for long sessions |
| `install-fish-default-shell.sh` | install fish and set as login shell |
| `connect-wifi.sh` | interactive NetworkManager Wi-Fi connect |
| `free-dpkg-lock.sh` | clear stale apt/dpkg locks (`sudo`) |
| `investigate-partitions.sh` | non-destructive disk/partition report |

```bash
./setup-headless-lid-battery.sh
START_THRESHOLD=50 STOP_THRESHOLD=70 ./setup-headless-lid-battery.sh

./setup-headless-health-monitor.sh
systemctl --user status headless-health-monitor.service

./connect-wifi.sh
./connect-wifi.sh wlan0

sudo ./free-dpkg-lock.sh
./investigate-partitions.sh reports/partition-report-$(hostname)-$(date +%Y%m%d-%H%M%S).txt
```


## After path moves

If a machine still has a user unit pointing at the old
`laptops-setup/t14-g2/` path, refresh via Ansible laptop tags or:

```bash
systemctl --user daemon-reload
systemctl --user restart headless-health-monitor.service
systemctl --user status headless-health-monitor.service
```
