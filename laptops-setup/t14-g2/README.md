# T14 Gen 2 laptop setup scripts

Scripts collected from `~/` for setting up and maintaining this ThinkPad T14 Gen 2 as a mostly-headless laptop/server.

## Scripts

- `connect-wifi.sh` — prompts for a Wi-Fi SSID and password, then connects using NetworkManager (`nmcli`). Defaults to interface `wlp0s20f3`; pass another interface as the first argument if needed.
  ```bash
  ./connect-wifi.sh
  ./connect-wifi.sh wlan0
  ```

- `setup-headless-lid-battery.sh` — configures lid-close behavior for headless use and sets battery charge thresholds. Defaults: start at 55%, stop at 60%.
  ```bash
  ./setup-headless-lid-battery.sh
  START_THRESHOLD=50 STOP_THRESHOLD=70 ./setup-headless-lid-battery.sh
  ```

- `verify-headless-laptop.sh` — checks battery thresholds, lid config, Wi-Fi/static IP expectations, and basic reachability.
  ```bash
  ./verify-headless-laptop.sh
  EXPECTED_IP=192.168.100.189 ./verify-headless-laptop.sh
  ```

- `headless-health-monitor.sh` — records periodic health samples under `~/headless-monitor/logs/` and can write diagnostic snapshots.
  ```bash
  ./headless-health-monitor.sh once
  ./headless-health-monitor.sh snapshot
  ./headless-health-monitor.sh monitor
  ```

- `setup-headless-health-monitor.sh` — installs/enables the user systemd service for `headless-health-monitor.sh` from this directory.
  ```bash
  ./setup-headless-health-monitor.sh
  systemctl --user status headless-health-monitor.service
  journalctl --user -u headless-health-monitor.service -f
  ```

- `setup-ssh-long-lived.sh` — configures SSH client/server keepalives so long-running SSH sessions survive brief network interruptions.

- `free-dpkg-lock.sh` — safely finds and optionally terminates stale apt/dpkg lock holders, removes stale lock files, then runs package repair commands. Run with `sudo`.
  ```bash
  sudo ./free-dpkg-lock.sh
  sudo ./free-dpkg-lock.sh --force
  ```

- `install-fish-default-shell.sh` — installs fish if needed and sets it as the user's default shell.

- `investigate-partitions.sh` — non-destructive disk/partition/LVM/filesystem reporting tool. Reports are written to the current directory unless an output path is passed.
  ```bash
  ./investigate-partitions.sh
  ./investigate-partitions.sh reports/partition-report-$(hostname)-$(date +%Y%m%d-%H%M%S).txt
  ```

## Reports

- `reports/partition-report-*.txt` — saved outputs from earlier partition investigations.

## Installed service note

The running user service has been updated to use:

```text
/home/stonecharioteer/code/checkouts/personal/scripts/laptops-setup/t14-g2/headless-health-monitor.sh monitor
```

If it ever needs to be refreshed manually:

```bash
systemctl --user daemon-reload
systemctl --user restart headless-health-monitor.service
systemctl --user status headless-health-monitor.service
```
