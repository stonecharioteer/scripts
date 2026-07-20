# Laptop helper scripts

Reusable laptop helpers used with
[`distributed-dotfiles`](https://github.com/stonecharioteer/distributed-dotfiles).

System installation (systemd units, sysctl, lid handling, battery thresholds,
GPU/display mitigations) lives in the Ansible `laptop-health` role. This tree
keeps the scripts themselves.

## Layout

| Path | Purpose |
|------|---------|
| [`thinkpads/`](thinkpads/README.md) | Headless ThinkPad helpers (health monitor, lid/battery setup scripts, SSH keepalives, diagnostics) |
| [`x13-flow/`](x13-flow/README.md) | ASUS ROG X13 Flow screen keep-off and hang-health stats helpers |

## Related automation

```bash
# From distributed-dotfiles
./bootstrap headless -i inventory/hosts.yml -- --limit HOST --tags laptop
```
