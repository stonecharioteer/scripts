# ThinkPad headless laptop helpers

Scripts for maintaining ThinkPads (T14, P1, etc.) as mostly-headless
laptop/servers.

Most install steps are now idempotent Ansible in the `laptop-health` role of
`distributed-dotfiles`. Keep these scripts for:

- one-shot manual setup/repair
- the continuous health monitor binary used by the user systemd unit
- diagnostics and verification

## Scripts

- `connect-wifi.sh` — prompts for a Wi-Fi SSID/password and connects with NetworkManager (`nmcli`).
  ```bash
  ./connect-wifi.sh
  ./connect-wifi.sh wlan0
  ```

- `setup-headless-lid-battery.sh` — lid-close ignore + battery charge thresholds (default 55–60%). Prefer the Ansible role when available.
  ```bash
  ./setup-headless-lid-battery.sh
  START_THRESHOLD=50 STOP_THRESHOLD=70 ./setup-headless-lid-battery.sh
  ```

- `verify-headless-laptop.sh` — checks battery thresholds, lid config, Wi-Fi/static IP expectations, and reachability.
  ```bash
  ./verify-headless-laptop.sh
  EXPECTED_IP=192.168.100.189 ./verify-headless-laptop.sh
  ```

- `headless-health-monitor.sh` — periodic health samples under `~/headless-monitor/logs/`.
  ```bash
  ./headless-health-monitor.sh once
  ./headless-health-monitor.sh snapshot
  ./headless-health-monitor.sh monitor
  ```

- `setup-headless-health-monitor.sh` — installs/enables the user systemd service for the monitor. Prefer Ansible `enable_headless_health_monitor`.
  ```bash
  ./setup-headless-health-monitor.sh
  systemctl --user status headless-health-monitor.service
  ```

- `setup-ssh-long-lived.sh` — SSH client/server keepalives. Prefer Ansible `enable_ssh_long_lived`.

- `free-dpkg-lock.sh` — find/clear stale apt/dpkg locks (run with `sudo`).

- `install-fish-default-shell.sh` — install fish and set as default shell (usually handled by distributed-dotfiles).

- `investigate-partitions.sh` — non-destructive disk/partition report.

## Ansible wiring

distributed-dotfiles expects:

```text
~/code/checkouts/personal/scripts/laptop/thinkpads/headless-health-monitor.sh
```

After moving paths, refresh the user unit with:

```bash
systemctl --user daemon-reload
systemctl --user restart headless-health-monitor.service
```
