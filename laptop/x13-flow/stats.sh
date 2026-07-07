#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/log/hang-health.log}"
SHORT=0
WATCH=0
WATCH_INTERVAL="1m"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --short)
      SHORT=1
      ;;
    --watch)
      WATCH=1
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        WATCH_INTERVAL="$2"
        shift
      fi
      ;;
    -h|--help)
      printf 'Usage: %s [--short] [--watch [INTERVAL]]\n' "$0"
      printf 'Examples: %s --watch, %s --watch 10s, %s --watch 1m\n' "$0" "$0" "$0"
      exit 0
      ;;
    *)
      printf 'Usage: %s [--short] [--watch [INTERVAL]]\n' "$0" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$WATCH" -eq 1 ]]; then
  if ! command -v uv >/dev/null; then
    printf 'ERROR: uv is required for --watch. Run: uv run stats.py --watch\n' >&2
    exit 1
  fi

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  args=(--watch "$WATCH_INTERVAL" --log-file "$LOG_FILE")
  [[ "$SHORT" -eq 1 ]] && args+=(--short)
  exec uv run "$script_dir/stats.py" "${args[@]}"
fi

if [[ ! -r "$LOG_FILE" ]]; then
  printf 'ERROR: cannot read %s\n' "$LOG_FILE" >&2
  exit 1
fi

if ! command -v gum >/dev/null; then
  printf 'ERROR: gum is required for this status view.\n' >&2
  exit 1
fi

now_epoch="$(date +%s)"
uptime_seconds="$(awk '{print int($1)}' /proc/uptime)"
boot_epoch="$((now_epoch - uptime_seconds))"
hour_epoch="$((now_epoch - 3600))"
day_epoch="$((now_epoch - 86400))"

rows_file="$(mktemp)"
trap 'rm -f "$rows_file"' EXIT

awk '
  function emit() {
    if (ts != "") {
      print ts "\t" cap "\t" status "\t" power "\t" cpu "\t" gpu "\t" nvme
    }
  }

  /===== snapshot/ {
    emit()
    ts=$3
    cap=status=power=cpu=gpu=nvme=""
    in_bat=0
    next
  }

  /^\[BAT0\]/ { in_bat=1; next }
  /^\[/ && $0 !~ /^\[BAT0\]/ { in_bat=0; next }

  in_bat && /status=/ { split($0, a, "="); status=a[2] }
  in_bat && /capacity=/ { split($0, a, "="); cap=a[2] }
  in_bat && /power_now=/ { split($0, a, "="); power=a[2] }

  /Tctl:/ { value=$2; gsub(/[^0-9.]/, "", value); cpu=value }
  /edge:/ { value=$2; gsub(/[^0-9.]/, "", value); gpu=value }
  /Composite:/ { value=$2; gsub(/[^0-9.]/, "", value); nvme=value }

  END { emit() }
' "$LOG_FILE" |
while IFS=$'\t' read -r ts cap status power cpu gpu nvme; do
  [[ -n "$ts" ]] || continue
  epoch="$(date -d "$ts" +%s 2>/dev/null || true)"
  [[ -n "$epoch" ]] || continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$epoch" "$ts" "${cap:-unknown}" "${status:-unknown}" "${power:-unknown}" \
    "${cpu:-unknown}" "${gpu:-unknown}" "${nvme:-unknown}"
done >"$rows_file"

if [[ ! -s "$rows_file" ]]; then
  printf 'ERROR: no parseable snapshots found in %s\n' "$LOG_FILE" >&2
  exit 1
fi

latest_line="$(tail -n 1 "$rows_file")"
IFS=$'\t' read -r _latest_epoch latest_ts latest_cap latest_status latest_power latest_cpu latest_gpu latest_nvme <<<"$latest_line"

stats_for_cutoff() {
  local cutoff="$1"
  awk -F '\t' -v cutoff="$cutoff" '
    $1 >= cutoff {
      n++
      cap=$3+0; power=$5+0; cpu=$6+0; gpu=$7+0; nvme=$8+0

      if (n == 1 || cap < cap_min) cap_min=cap
      if (n == 1 || cap > cap_max) cap_max=cap
      if (power > power_max) power_max=power

      if (n == 1 || cpu < cpu_min) cpu_min=cpu
      if (cpu > cpu_max) cpu_max=cpu
      if (n == 1 || gpu < gpu_min) gpu_min=gpu
      if (gpu > gpu_max) gpu_max=gpu
      if (n == 1 || nvme < nvme_min) nvme_min=nvme
      if (nvme > nvme_max) nvme_max=nvme
    }
    END {
      if (n == 0) {
        print "0\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown"
      } else {
        printf "%d\t%d\t%d\t%.3f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\n", \
          n, cap_min, cap_max, power_max / 1000000, cpu_min, cpu_max, gpu_min, gpu_max, nvme_min, nvme_max
      }
    }
  ' "$rows_file"
}

IFS=$'\t' read -r h_samples h_cap_min h_cap_max h_power_max h_cpu_min h_cpu_max h_gpu_min h_gpu_max h_nvme_min h_nvme_max <<<"$(stats_for_cutoff "$hour_epoch")"
IFS=$'\t' read -r d_samples d_cap_min d_cap_max d_power_max d_cpu_min d_cpu_max d_gpu_min d_gpu_max d_nvme_min d_nvme_max <<<"$(stats_for_cutoff "$day_epoch")"
IFS=$'\t' read -r b_samples b_cap_min b_cap_max b_power_max b_cpu_min b_cpu_max b_gpu_min b_gpu_max b_nvme_min b_nvme_max <<<"$(stats_for_cutoff "$boot_epoch")"

boot_time="$(date -d "@$boot_epoch" '+%Y-%m-%d %H:%M:%S %Z')"
latest_power_w="$(awk -v p="$latest_power" 'BEGIN { if (p == "unknown") print "unknown"; else printf "%.3f W", p / 1000000 }')"

gum style --border rounded --padding "0 1" --margin "0 0 1 0" \
  --border-foreground 42 --foreground 42 --bold \
  "X13 Flow health" \
  "Latest snapshot: $latest_ts"

gum style --foreground 212 --bold "Battery and temperature stats"

if [[ "$SHORT" -eq 1 ]]; then
  gum table --print --columns Metric,Current --separator $'\t' <<EOF
Battery	$latest_cap% ($latest_status)
Battery draw	$latest_power_w
CPU	$latest_cpu°C
GPU	$latest_gpu°C
NVMe	$latest_nvme°C
EOF
else
  gum table --print --columns Metric,Current,Last-1h,Last-24h,"Since-boot ($boot_time)" --separator $'\t' <<EOF
Samples	latest	$h_samples	$d_samples	$b_samples
Battery	$latest_cap% ($latest_status)	$h_cap_min–$h_cap_max%	$d_cap_min–$d_cap_max%	$b_cap_min–$b_cap_max%
Battery draw	$latest_power_w	max $h_power_max W	max $d_power_max W	max $b_power_max W
CPU	$latest_cpu°C	$h_cpu_min–$h_cpu_max°C	$d_cpu_min–$d_cpu_max°C	$b_cpu_min–$b_cpu_max°C
GPU	$latest_gpu°C	$h_gpu_min–$h_gpu_max°C	$d_gpu_min–$d_gpu_max°C	$b_gpu_min–$b_gpu_max°C
NVMe	$latest_nvme°C	$h_nvme_min–$h_nvme_max°C	$d_nvme_min–$d_nvme_max°C	$b_nvme_min–$b_nvme_max°C
EOF
fi
