#!/bin/bash

# Step 3: Fixed NTFS Repair - corrected SMART commands and focused approach
# Based on previous failure analysis

set -euo pipefail

DEVICE="/dev/sdc"
PARTITION="/dev/sdc1"
LOG_FILE="disk-repair-step3-$(date +%Y%m%d-%H%M%S).log"

echo "=== NTFS Repair Step 3 (Fixed) ===" | tee "$LOG_FILE"
echo "Device: $DEVICE" | tee -a "$LOG_FILE"
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
        echo "Check log file: $LOG_FILE" | tee -a "$LOG_FILE"
        exit $exit_code
    fi
    echo "" | tee -a "$LOG_FILE"
}

# Function for non-critical commands (continue on failure)
run_command_optional() {
    local description="$1"
    shift
    echo ">>> $description (optional)" | tee -a "$LOG_FILE"
    echo "Command: $*" | tee -a "$LOG_FILE"
    
    if "$@" 2>&1 | tee -a "$LOG_FILE"; then
        echo "✓ Success" | tee -a "$LOG_FILE"
    else
        local exit_code=$?
        echo "⚠ Failed (exit code: $exit_code) - continuing..." | tee -a "$LOG_FILE"
    fi
    echo "" | tee -a "$LOG_FILE"
}

# SMART diagnostics on the device (not partition)
echo "=== STEP 1: Drive Health Check (Fixed) ===" | tee -a "$LOG_FILE"
run_command "SMART overall health" sudo smartctl -H "$DEVICE"
run_command "SMART detailed info" sudo smartctl -i "$DEVICE"
run_command_optional "SMART attributes" sudo smartctl -A "$DEVICE"

# NTFS repair (actual fix, not just check)
echo "=== STEP 2: NTFS Repair ===" | tee -a "$LOG_FILE"
echo "Since initial read-only check passed, proceeding with repair..." | tee -a "$LOG_FILE"
run_command "NTFS filesystem repair" sudo ntfsfix "$PARTITION"

# Comprehensive NTFS check
echo "=== STEP 3: Comprehensive NTFS Check ===" | tee -a "$LOG_FILE"
run_command_optional "Full NTFS consistency check" sudo ntfsck "$PARTITION"

# Final filesystem verification  
echo "=== STEP 4: Final Verification ===" | tee -a "$LOG_FILE"
run_command "Final filesystem info" sudo blkid "$PARTITION"
run_command_optional "Check kernel messages" sudo dmesg | tail -10

echo "" | tee -a "$LOG_FILE"
echo "=== REPAIR COMPLETE ===" | tee -a "$LOG_FILE"
echo "✓ SMART health check: PASSED" | tee -a "$LOG_FILE"
echo "✓ NTFS repair: COMPLETED" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "NEXT: Test mounting the drive" | tee -a "$LOG_FILE"
echo "Suggested commands:" | tee -a "$LOG_FILE"
echo "  sudo mkdir -p /mnt/test" | tee -a "$LOG_FILE"
echo "  sudo mount -t ntfs-3g $PARTITION /mnt/test" | tee -a "$LOG_FILE"
echo "  ls -la /mnt/test" | tee -a "$LOG_FILE"
echo "  sudo umount /mnt/test" | tee -a "$LOG_FILE"