#!/usr/bin/env bash
set -euo pipefail

printf 'Installing LightDM login-screen display sleep config...\n'

sudo install -d -m 0755 /etc/lightdm/scripts /etc/lightdm/lightdm.conf.d

sudo tee /etc/lightdm/scripts/display-sleep.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set +e

# Run by LightDM after the X server starts. Applies to the login/greeter screen.
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-/var/run/lightdm/root/:0}"

# Blank screen after 5 min, DPMS standby after 5 min, suspend after 10 min, off after 15 min.
xset s blank
xset s 300 300
xset +dpms
xset dpms 300 600 900
EOF

sudo chmod 0755 /etc/lightdm/scripts/display-sleep.sh

sudo tee /etc/lightdm/lightdm.conf.d/99-display-sleep.conf >/dev/null <<'EOF'
[Seat:*]
# Apply once when the X server starts, then again after the greeter starts.
# Some greeters reset screensaver/DPMS settings, so both hooks are intentional.
display-setup-script=/etc/lightdm/scripts/display-sleep.sh
greeter-setup-script=/etc/lightdm/scripts/display-sleep.sh
EOF

printf 'Done. Takes effect after restarting LightDM or rebooting.\n'
printf 'To apply immediately, run from SSH/TTY only:\n'
printf '  sudo systemctl restart lightdm\n'
