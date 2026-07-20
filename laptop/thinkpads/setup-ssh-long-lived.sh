#!/usr/bin/env bash
set -euo pipefail

log() { printf '\n==> %s\n' "$*"; }

log "Configuring this user's SSH client keepalives"
install -d -m 0700 "$HOME/.ssh"
touch "$HOME/.ssh/config"
chmod 0600 "$HOME/.ssh/config"

if ! grep -q '^Host \*$' "$HOME/.ssh/config" 2>/dev/null; then
  cat >> "$HOME/.ssh/config" <<'EOF'

Host *
  ServerAliveInterval 30
  ServerAliveCountMax 240
  TCPKeepAlive yes
EOF
else
  printf 'Host * already exists in ~/.ssh/config; not editing it automatically. Ensure it contains:\n'
  printf '  ServerAliveInterval 30\n  ServerAliveCountMax 240\n  TCPKeepAlive yes\n'
fi

log "Configuring sshd for long-lived incoming sessions to this laptop"
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/99-long-lived-sessions.conf >/dev/null <<'EOF'
# Keep incoming SSH sessions alive for headless/server use.
ClientAliveInterval 30
ClientAliveCountMax 240
TCPKeepAlive yes
EOF

log "Validating sshd config"
sudo sshd -t

log "Reloading sshd"
sudo systemctl reload ssh.service 2>/dev/null || sudo systemctl reload sshd.service

log "Done"
printf 'Incoming SSH sessions can now survive roughly %s minutes of missing client replies.\n' "$((30 * 240 / 60))"
