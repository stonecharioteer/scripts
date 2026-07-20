#!/usr/bin/env bash
set -uo pipefail

# Non-destructive partition/LVM/filesystem investigation script.
# It prints disk, partition, mount, filesystem, and LVM information.

OUT="${1:-partition-report-$(hostname)-$(date +%Y%m%d-%H%M%S).txt}"

run() {
  local title="$1"
  shift
  {
    echo
    echo "================================================================================"
    echo "$title"
    echo "Command: $*"
    echo "================================================================================"
  } | tee -a "$OUT"

  "$@" 2>&1 | tee -a "$OUT" || {
    local rc=$?
    echo "[command exited with status $rc]" | tee -a "$OUT"
  }
}

run_sh() {
  local title="$1"
  shift
  local cmd="$*"
  {
    echo
    echo "================================================================================"
    echo "$title"
    echo "Command: $cmd"
    echo "================================================================================"
  } | tee -a "$OUT"

  bash -lc "$cmd" 2>&1 | tee -a "$OUT" || {
    local rc=$?
    echo "[command exited with status $rc]" | tee -a "$OUT"
  }
}

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi

: > "$OUT"
echo "Partition investigation report" | tee -a "$OUT"
echo "Host: $(hostname)" | tee -a "$OUT"
echo "Date: $(date -Is)" | tee -a "$OUT"
echo "User: $(id)" | tee -a "$OUT"
echo "Output file: $OUT" | tee -a "$OUT"

run "Kernel and OS" uname -a
run_sh "OS release" 'test -r /etc/os-release && cat /etc/os-release || true'

run "Mounted filesystems, human-readable" df -hT
run "Mounted filesystems, inode usage" df -ihT
run "Block devices with filesystems" lsblk -o NAME,PATH,MAJ:MIN,RM,SIZE,RO,TYPE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS
run "Block device topology" lsblk -t
run "Findmnt tree" findmnt -R
run "Findmnt raw source/target/fstype/options" findmnt -rno SOURCE,TARGET,FSTYPE,OPTIONS

if command -v blkid >/dev/null 2>&1; then
  run "blkid" $SUDO blkid
fi

if command -v fdisk >/dev/null 2>&1; then
  run "fdisk partition table" $SUDO fdisk -l
fi

if command -v parted >/dev/null 2>&1; then
  run "parted machine-readable disk layout" $SUDO parted -lm
else
  echo "parted not installed; skipping parted output" | tee -a "$OUT"
fi

if command -v pvs >/dev/null 2>&1; then
  run "LVM physical volumes" $SUDO pvs -o+pv_used,pv_free,vg_uuid,pv_uuid
  run "LVM volume groups" $SUDO vgs -o+vg_uuid,vg_size,vg_free,vg_extent_size,vg_extent_count,vg_free_count
  run "LVM logical volumes" $SUDO lvs -a -o+devices,segtype,lv_size,data_percent,metadata_percent,lv_uuid
  run "LVM full PV display" $SUDO pvdisplay -m
  run "LVM full VG display" $SUDO vgdisplay
  run "LVM full LV display" $SUDO lvdisplay -m
else
  echo "LVM tools not installed or not in PATH; skipping LVM output" | tee -a "$OUT"
fi

run_sh "Filesystem usage summary for root" 'df -hT / && findmnt /'
run_sh "Boot entries/mounts" 'df -hT /boot /boot/efi 2>/dev/null || true; findmnt /boot /boot/efi 2>/dev/null || true'
run_sh "fstab" 'test -r /etc/fstab && cat /etc/fstab || true'
run_sh "Swap" 'swapon --show --bytes; test -r /proc/swaps && cat /proc/swaps || true'

cat <<EOF | tee -a "$OUT"

================================================================================
Quick interpretation hints
================================================================================
- Compare disk/partition size from lsblk/fdisk with LV size from lvs.
- If a large partition is TYPE=lvm and VG Free is large in vgs, the space is free inside LVM.
- To inspect without modifying anything, this script only runs read-only/reporting commands.
EOF

echo
printf 'Report written to: %s\n' "$OUT"
