#!/bin/bash

# Clear NTFS dirty bit and force mount
set -euo pipefail

PARTITION="/dev/sdc1"
MOUNT_POINT="/media/stonecharioteer/nvme-disk"
LOG_FILE="clear-dirty-bit-$(date +%Y%m%d-%H%M%S).log"

echo "=== Clear NTFS Dirty Bit ===" | tee "$LOG_FILE"
echo "Partition: $PARTITION" | tee -a "$LOG_FILE"
echo "Started at: $(date)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Function to log and execute commands
run_command() {
    local description="$1"
    shift
    echo ">>> $description" | tee -a "$LOG_FILE"
    echo "Command: $*" | tee -a "$LOG_FILE"
    
    if "$@" 2>&1 | tee -a "$LOG_FILE"; then
        echo "✓ Success" | tee -a "$LOG_FILE"
    else
        local exit_code=$?
        echo "✗ Failed (exit code: $exit_code)" | tee -a "$LOG_FILE"
        echo "ABORTING: Command failed - $description" | tee -a "$LOG_FILE"
        exit $exit_code
    fi
    echo "" | tee -a "$LOG_FILE"
}

echo "=== STEP 1: Clear Dirty Bit ===" | tee -a "$LOG_FILE"
echo "The drive has a 'dirty bit' set from improper Windows shutdown." | tee -a "$LOG_FILE"
echo "This is normal and can be safely cleared." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

run_command "Force NTFS repair to clear dirty bit" sudo ntfsfix -d "$PARTITION"

echo "=== STEP 2: Verify Fix ===" | tee -a "$LOG_FILE"
run_command "Check filesystem info after fix" sudo ntfsinfo -m "$PARTITION"

echo "=== STEP 3: Test Mount ===" | tee -a "$LOG_FILE"
run_command "Create mount directory" sudo mkdir -p "$MOUNT_POINT"
run_command "Mount with force option" sudo mount -t ntfs-3g -o force "$PARTITION" "$MOUNT_POINT"
run_command "List directory contents" ls -la "$MOUNT_POINT"
run_command "Check disk usage" df -h "$MOUNT_POINT"

echo "=== STEP 4: Test Write Access ===" | tee -a "$LOG_FILE"
if sudo touch "$MOUNT_POINT/test-write-$(date +%s).tmp" 2>&1 | tee -a "$LOG_FILE"; then
    echo "✓ Write test successful" | tee -a "$LOG_FILE"
    run_command "Remove test file" sudo rm "$MOUNT_POINT"/test-write-*.tmp
else
    echo "⚠ Write test failed - drive may be read-only" | tee -a "$LOG_FILE"
fi

echo "=== STEP 5: Cleanup ===" | tee -a "$LOG_FILE"
run_command "Unmount drive" sudo umount "$MOUNT_POINT"

echo "" | tee -a "$LOG_FILE"
echo "=== DIRTY BIT CLEARED SUCCESSFULLY ===" | tee -a "$LOG_FILE"
echo "✅ Your drive is now clean and ready for normal use!" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "To permanently mount it, add this line to /etc/fstab:" | tee -a "$LOG_FILE"
echo "UUID=1131CD845F46769F $MOUNT_POINT ntfs-3g defaults,uid=1000,gid=1000,umask=022 0 0" | tee -a "$LOG_FILE"