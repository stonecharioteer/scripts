#!/bin/bash

# Disk Check and Repair Script for /dev/sdc (NTFS)
# This script performs systematic checks and repairs on the NTFS partition

set -euo pipefail

DEVICE="/dev/sdc"
PARTITION="/dev/sdc1"
LOG_FILE="disk-repair-$(date +%Y%m%d-%H%M%S).log"

echo "=== Disk Check and Repair Script ===" | tee "$LOG_FILE"
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
        echo "✗ Failed (exit code: $?)" | tee -a "$LOG_FILE"
    fi
    echo "" | tee -a "$LOG_FILE"
}

# Check if device exists and is accessible
echo "=== STEP 1: Basic Device Checks ===" | tee -a "$LOG_FILE"
run_command "Check if device exists" test -b "$DEVICE"
run_command "Check if partition exists" test -b "$PARTITION"

# Check current mount status
echo "=== STEP 2: Mount Status Check ===" | tee -a "$LOG_FILE"
run_command "Check if partition is mounted" mount | grep "$PARTITION" || echo "Partition not mounted" | tee -a "$LOG_FILE"

# Basic disk information
echo "=== STEP 3: Disk Information ===" | tee -a "$LOG_FILE"
run_command "SMART status check" sudo smartctl -H "$DEVICE"
run_command "Detailed SMART attributes" sudo smartctl -A "$DEVICE"

# Check filesystem type and basic info
echo "=== STEP 4: Filesystem Information ===" | tee -a "$LOG_FILE"
run_command "Filesystem type detection" sudo blkid "$PARTITION"
run_command "NTFS filesystem info" sudo ntfsinfo "$PARTITION"

# NTFS-specific checks (read-only first)
echo "=== STEP 5: NTFS Read-Only Checks ===" | tee -a "$LOG_FILE"
run_command "NTFS filesystem check (read-only)" sudo ntfsfix -n "$PARTITION"

echo "=== INITIAL ASSESSMENT COMPLETE ===" | tee -a "$LOG_FILE"
echo "Please review the output above and provide it to determine next steps." | tee -a "$LOG_FILE"
echo "Log saved to: $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Pause here for user review before proceeding with any repairs
echo "NEXT STEPS (run manually if needed):" | tee -a "$LOG_FILE"
echo "1. If no critical errors found, run: sudo ntfsfix $PARTITION" | tee -a "$LOG_FILE"
echo "2. For comprehensive check: sudo ntfsck $PARTITION" | tee -a "$LOG_FILE"
echo "3. For bad sector scan: sudo badblocks -v -s $PARTITION" | tee -a "$LOG_FILE"
echo "4. Check dmesg for kernel messages: sudo dmesg | tail -20" | tee -a "$LOG_FILE"