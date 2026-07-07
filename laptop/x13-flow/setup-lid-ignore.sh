#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="/etc/systemd/logind.conf.d"
CONF_FILE="$CONF_DIR/zz-lid-server.conf"

printf 'Configuring logind to ignore laptop lid close for server/headless mode...\n'

sudo install -d -m 0755 "$CONF_DIR"

sudo tee "$CONF_FILE" >/dev/null <<'EOF'
[Login]
# Server/headless mode: keep the machine awake when the lid is closed.
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
EOF

# Remove older script-created files if present. Ignore failures because this
# is only cleanup and they may not exist.
sudo rm -f "$CONF_DIR/lid-server.conf" "$CONF_DIR/99-lid-server.conf"

printf 'Installed: %s\n' "$CONF_FILE"
printf '\nEffective lid-related config files:\n'
grep -R "^HandleLidSwitch" /etc/systemd/logind.conf "$CONF_DIR" 2>/dev/null || true

printf '\nRestarting systemd-logind to apply changes...\n'
printf 'Warning: this can disrupt local graphical/login sessions. SSH usually survives, but have physical access if possible.\n'
sudo systemctl restart systemd-logind

printf '\nDone. Lid close should now be ignored.\n'
printf 'Verify later with:\n'
printf '  grep -R "^HandleLidSwitch" /etc/systemd/logind.conf /etc/systemd/logind.conf.d 2>/dev/null\n'
