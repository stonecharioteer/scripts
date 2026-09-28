# Laptop helper scripts

Reusable laptop helpers used with
[`distributed-dotfiles`](https://github.com/stonecharioteer/distributed-dotfiles).

## Split of responsibility

| Layer                  | Where                                                | What                                                                                                                           |
| ---------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Idempotent install** | Ansible `laptop-health` role in distributed-dotfiles | systemd units, sysctl, logind lid policy, battery charge thresholds, SSH keepalives, NVMe/hang timers, X13 display mitigations |
| **Runtime helpers**    | this tree                                            | panel control, health TSV logger, stats UI, one-shot repair/diagnostic scripts                                                 |
| **Manual fallbacks**   | this tree (`setup-*.sh`)                             | same installs as Ansible, for rescue when playbooks are unavailable                                                            |

Prefer Ansible on managed hosts. Use the shell installers only for bootstrapping or emergency repair.

## Layout

| Path                                | Purpose                                                                                            |
| ----------------------------------- | -------------------------------------------------------------------------------------------------- |
| [`thinkpads/`](thinkpads/README.md) | Headless ThinkPad helpers (T14, P1, …): health monitor, lid/battery/SSH setup scripts, diagnostics |
| [`x13-flow/`](x13-flow/README.md)   | ASUS ROG X13 Flow: screen keep-off runtime, hang stats UI, and X13-specific setup/repair scripts   |

## GUI lid and power policy

`lid-power-policy.py` lets a closed laptop stay awake on external power and
requests suspend after five continuous minutes closed on battery. Opening the
lid or restoring external power cancels the timer. Unplugging a closed laptop
starts a new timer. The default sensor interval is ten seconds.

Requirements: Linux ACPI lid state under `/proc/acpi/button/lid`, power-supply
state under `/sys/class/power_supply`, Python 3, and systemd. USB-C power supplies
are supported. Missing sensor data cancels the timer rather than suspending.
The delay uses a monotonic clock. After resume or a failed suspend request,
the helper waits a full delay before another request.

Ansible installs a root-owned copy and a system service wrapped with
`systemd-inhibit --what=handle-lid-switch`. This prevents logind from suspending
immediately. The desktop's separate lid actions must also be disabled; the
Ansible role supplies Cinnamon dconf policy and Xfce system property locks.
Restart the session after installing that policy. Manual suspend, critical-battery actions,
and unrelated idle-suspend settings are not overridden.

Read sensor state without changing power state:

```bash
python3 laptop/lid-power-policy.py --check
python3 -m unittest discover -s tests -p test_lid_power_policy.py -v
```

For a manual foreground test, after disabling the desktop's own lid actions:

```bash
sudo systemd-inhibit --what=handle-lid-switch --mode=block \
  python3 laptop/lid-power-policy.py --delay 300 --interval 10
```

This command can suspend the machine. Use Ansible for persistent installation.

## Related automation

```bash
# From distributed-dotfiles — headless ThinkPads / laptops group
./bootstrap headless -i inventory/hosts.yml -- --limit HOST --tags laptop

# GUI / X13 Flow style hosts
./bootstrap gui -i inventory/hosts.yml -- --limit HOST --tags laptop
```

Paths expected by Ansible after clone:

```text
~/code/checkouts/personal/scripts/laptop/thinkpads/headless-health-monitor.sh
~/code/checkouts/personal/scripts/laptop/x13-flow/screen.sh
```
