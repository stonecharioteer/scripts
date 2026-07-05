#!/usr/bin/env bash
set -euo pipefail

# Safely free apt/dpkg frontend locks.
# Usage:
#   sudo ./free-dpkg-lock.sh          # interactive
#   sudo ./free-dpkg-lock.sh --force  # terminate lock holders without prompting

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 ${1:-}" >&2
  exit 1
fi

LOCKS=(
  /var/lib/dpkg/lock-frontend
  /var/lib/dpkg/lock
  /var/cache/apt/archives/lock
  /var/lib/apt/lists/lock
)

holders() {
  local lock="$1"
  [[ -e "$lock" ]] || return 0
  if command -v fuser >/dev/null 2>&1; then
    fuser "$lock" 2>/dev/null || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -t "$lock" 2>/dev/null || true
  fi
}

all_pids=()
for lock in "${LOCKS[@]}"; do
  mapfile -t pids < <(holders "$lock" | tr ' ' '\n' | sed '/^$/d' | sort -u)
  if ((${#pids[@]})); then
    echo "Lock holder(s) for $lock: ${pids[*]}"
    ps -fp "$(IFS=,; echo "${pids[*]}")" || true
    all_pids+=("${pids[@]}")
  fi
done

mapfile -t unique_pids < <(printf '%s\n' "${all_pids[@]:-}" | sed '/^$/d' | sort -u)

if ((${#unique_pids[@]})); then
  echo
  echo "These processes are using apt/dpkg locks: ${unique_pids[*]}"
  if ((FORCE == 0)); then
    read -r -p "Terminate them? Only do this if you are sure no install/update should be running. [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
  fi

  echo "Sending SIGTERM..."
  kill "${unique_pids[@]}" 2>/dev/null || true
  sleep 5

  still_running=()
  for pid in "${unique_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      still_running+=("$pid")
    fi
  done

  if ((${#still_running[@]})); then
    echo "Still running: ${still_running[*]}"
    if ((FORCE == 0)); then
      read -r -p "Send SIGKILL? [y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted before SIGKILL."; exit 1; }
    fi
    kill -9 "${still_running[@]}" 2>/dev/null || true
    sleep 2
  fi
fi

# Remove stale lock files only when no process currently holds them.
for lock in "${LOCKS[@]}"; do
  [[ -e "$lock" ]] || continue
  if [[ -z "$(holders "$lock" | tr -d '[:space:]')" ]]; then
    echo "Removing stale lock: $lock"
    rm -f "$lock"
  else
    echo "Still held, not removing: $lock" >&2
  fi
done

echo "Reconfiguring interrupted packages..."
dpkg --configure -a

echo "Repairing dependency state..."
apt-get -f install

echo "Done."
