#!/bin/bash

# Step 2: NTFS Repair and Health Check
# Based on successful initial assessment

set -euo pipefail

PARTITION="/dev/sdc1"
LOG_FILE="disk-repair-step2-$(date +%Y%m%d-%H%M%S).log"

echo "=== NTFS Repair Step 2 ===" | tee "$LOG_FILE"
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

# Install missing tools first
echo "=== STEP 1: Install Missing Tools ===" | tee -a "$LOG_FILE"
run_command "Update package list" sudo apt update
run_command "Install smartmontools" sudo apt install -y smartmontools

# Now run SMART diagnostics
echo "=== STEP 2: Drive Health Check ===" | tee -a "$LOG_FILE"
run_command "SMART overall health" sudo smartctl -H "$PARTITION"
run_command "SMART short self-test" sudo smartctl -t short "$PARTITION"
echo "Waiting 2 minutes for short test to complete..." | tee -a "$LOG_FILE"
sleep 120
run_command "SMART test results" sudo smartctl -l selftest "$PARTITION"

# NTFS repair (actual fix, not just check)
echo "=== STEP 3: NTFS Repair ===" | tee -a "$LOG_FILE"
echo "Since read-only check passed, proceeding with repair..." | tee -a "$LOG_FILE"
run_command "NTFS filesystem repair" sudo ntfsfix "$PARTITION"

# Comprehensive NTFS check
echo "=== STEP 4: Comprehensive NTFS Check ===" | tee -a "$LOG_FILE"
run_command "Full NTFS consistency check" sudo ntfsck "$PARTITION"

# Check for bad sectors (this may take a while)
echo "=== STEP 5: Bad Sector Scan ===" | tee -a "$LOG_FILE"
echo "WARNING: This step may take 30+ minutes for a 1.8TB drive" | tee -a "$LOG_FILE"
echo "Press Ctrl+C to skip if you want to test mounting first" | tee -a "$LOG_FILE"
sleep 5
run_command "Bad sector scan (non-destructive)" sudo badblocks -v -s "$PARTITION"

# Final status
echo "=== STEP 6: Final Status ===" | tee -a "$LOG_FILE"
run_command "Check kernel messages" sudo dmesg | tail -20
run_command "Final filesystem info" sudo blkid "$PARTITION"

echo "" | tee -a "$LOG_FILE"
echo "=== REPAIR COMPLETE ===" | tee -a "$LOG_FILE"
echo "Next step: Try mounting the drive to test if repairs worked" | tee -a "$LOG_FILE"
echo "Suggested mount test: sudo mkdir -p /mnt/test && sudo mount -t ntfs-3g $PARTITION /mnt/test" | tee -a "$LOG_FILE"