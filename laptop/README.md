# Laptop helper scripts

Reusable laptop helpers used with
[`distributed-dotfiles`](https://github.com/stonecharioteer/distributed-dotfiles).

## Split of responsibility

| Layer | Where | What |
|-------|--------|------|
| **Idempotent install** | Ansible `laptop-health` role in distributed-dotfiles | systemd units, sysctl, logind lid policy, battery charge thresholds, SSH keepalives, NVMe/hang timers, X13 display mitigations |
| **Runtime helpers** | this tree | panel control, health TSV logger, stats UI, one-shot repair/diagnostic scripts |
| **Manual fallbacks** | this tree (`setup-*.sh`) | same installs as Ansible, for rescue when playbooks are unavailable |

Prefer Ansible on managed hosts. Use the shell installers only for bootstrapping or emergency repair.

## Layout

| Path | Purpose |
|------|---------|
| [`thinkpads/`](thinkpads/README.md) | Headless ThinkPad helpers (T14, P1, …): health monitor, lid/battery/SSH setup scripts, diagnostics |
| [`x13-flow/`](x13-flow/README.md) | ASUS ROG X13 Flow: screen keep-off runtime, hang stats UI, and X13-specific setup/repair scripts |

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
