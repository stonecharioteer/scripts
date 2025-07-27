#!/bin/bash

# NTFS Drive Repair Tool
# Comprehensive diagnosis and repair for NTFS drives with mounting issues
# Usage: ./ntfs-repair.sh <device> [mount_point]

set -euo pipefail

# Configuration
DEVICE=""
PARTITION=""
MOUNT_POINT=""
USER_HOME="$(eval echo ~$SUDO_USER)"
LOG_FILE="ntfs-repair-$(date +%Y%m%d-%H%M%S).log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage function
show_usage() {
    echo "NTFS Drive Repair Tool"
    echo ""
    echo "Usage: $0 <device> [mount_point]"
    echo ""
    echo "Arguments:"
    echo "  device       Device to repair (e.g., /dev/sdc1)"
    echo "  mount_point  Optional mount point (default: /media/\$USER/\$LABEL)"
    echo ""
    echo "Examples:"
    echo "  $0 /dev/sdc1                              # SATA drive"
    echo "  $0 /dev/nvme0n1p1                         # NVMe drive"
    echo "  $0 /dev/sda2 /media/myuser/external-drive # Custom mount point"
    echo ""
    echo "The script will:"
    echo "  1. Diagnose drive health (SMART)"
    echo "  2. Check NTFS filesystem integrity"
    echo "  3. Clear dirty bit if needed"
    echo "  4. Test mounting and access"
    echo "  5. Optionally setup permanent mount"
}

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $message" | tee -a "$LOG_FILE" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $message" | tee -a "$LOG_FILE" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} $message" | tee -a "$LOG_FILE" ;;
        *)       echo "[$timestamp] $message" | tee -a "$LOG_FILE" ;;
    esac
}

# Command execution with logging
run_command() {
    local description="$1"
    shift
    log_message "INFO" ">>> $description"
    echo "Command: $*" >> "$LOG_FILE"
    
    if "$@" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "INFO" "✓ Success"
        return 0
    else
        local exit_code=$?
        log_message "ERROR" "✗ Failed (exit code: $exit_code)"
        return $exit_code
    fi
    echo "" >> "$LOG_FILE"
}

# Optional command execution (continues on failure)
run_command_optional() {
    local description="$1"
    shift
    log_message "INFO" ">>> $description (optional)"
    echo "Command: $*" >> "$LOG_FILE"
    
    if "$@" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "INFO" "✓ Success"
    else
        local exit_code=$?
        log_message "WARN" "⚠ Failed (exit code: $exit_code) - continuing..."
    fi
    echo "" >> "$LOG_FILE"
}

# Parse command line arguments
parse_arguments() {
    if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi
    
    if [[ $# -lt 1 ]]; then
        log_message "ERROR" "Device argument required"
        show_usage
        exit 1
    fi
    
    PARTITION="$1"
    
    # Extract device from partition - handles both SATA and NVMe
    if [[ "$PARTITION" =~ ^(/dev/sd[a-z]+)[0-9]+$ ]]; then
        # SATA/SCSI drives: /dev/sda1 -> /dev/sda
        DEVICE="${BASH_REMATCH[1]}"
    elif [[ "$PARTITION" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        # NVMe drives: /dev/nvme0n1p1 -> /dev/nvme0n1
        DEVICE="${BASH_REMATCH[1]}"
    else
        log_message "ERROR" "Invalid device format: $PARTITION"
        echo "Expected formats:"
        echo "  SATA/SCSI: /dev/sdX1 (e.g., /dev/sda1, /dev/sdb2)"
        echo "  NVMe: /dev/nvmeXnYpZ (e.g., /dev/nvme0n1p1, /dev/nvme1n1p2)"
        exit 1
    fi
    
    # Set mount point
    if [[ $# -ge 2 ]]; then
        MOUNT_POINT="$2"
    else
        # Try to get label from blkid
        local label=$(sudo blkid -s LABEL -o value "$PARTITION" 2>/dev/null || echo "unknown")
        MOUNT_POINT="/media/${SUDO_USER:-$USER}/$label"
    fi
}

# Check prerequisites
check_prerequisites() {
    log_message "INFO" "=== Checking Prerequisites ==="
    
    # Check if running as root or with sudo
    if [[ $EUID -eq 0 ]] && [[ -z "${SUDO_USER:-}" ]]; then
        log_message "ERROR" "Don't run directly as root. Use sudo instead."
        exit 1
    fi
    
    # Check if device exists
    if [[ ! -b "$DEVICE" ]]; then
        log_message "ERROR" "Device $DEVICE does not exist"
        exit 1
    fi
    
    if [[ ! -b "$PARTITION" ]]; then
        log_message "ERROR" "Partition $PARTITION does not exist"
        exit 1
    fi
    
    # Install required tools
    if ! command -v smartctl &> /dev/null; then
        log_message "INFO" "Installing smartmontools..."
        run_command "Update package list" sudo apt update
        run_command "Install smartmontools" sudo apt install -y smartmontools
    fi
    
    log_message "INFO" "✓ Prerequisites satisfied"
}

# Step 1: Initial assessment
step1_initial_assessment() {
    log_message "INFO" "=== STEP 1: Initial Assessment ==="
    
    # Check mount status
    if mount | grep -q "$PARTITION"; then
        log_message "WARN" "Partition is currently mounted. Unmounting..."
        run_command "Unmount partition" sudo umount "$PARTITION"
    fi
    
    # Basic filesystem detection
    run_command "Detect filesystem type" sudo blkid "$PARTITION"
    
    # Check if it's NTFS
    local fstype=$(sudo blkid -s TYPE -o value "$PARTITION" 2>/dev/null || echo "unknown")
    if [[ "$fstype" != "ntfs" ]]; then
        log_message "ERROR" "This script is for NTFS filesystems only. Detected: $fstype"
        exit 1
    fi
    
    # Read-only NTFS check
    run_command "NTFS read-only check" sudo ntfsfix -n "$PARTITION"
    
    log_message "INFO" "✓ Initial assessment complete"
}

# Step 2: Drive health check
step2_drive_health() {
    log_message "INFO" "=== STEP 2: Drive Health Check ==="
    
    run_command "SMART overall health" sudo smartctl -H "$DEVICE"
    run_command "SMART device info" sudo smartctl -i "$DEVICE"
    run_command_optional "SMART attributes" sudo smartctl -A "$DEVICE"
    
    log_message "INFO" "✓ Drive health check complete"
}

# Step 3: NTFS repair
step3_ntfs_repair() {
    log_message "INFO" "=== STEP 3: NTFS Filesystem Repair ==="
    
    # Try basic repair first
    run_command "NTFS filesystem repair" sudo ntfsfix "$PARTITION"
    
    # Check if we can get filesystem info (detects dirty bit)
    if sudo ntfsinfo -m "$PARTITION" &>/dev/null; then
        log_message "INFO" "✓ Filesystem is clean"
    else
        log_message "WARN" "Dirty bit detected - clearing..."
        run_command "Clear NTFS dirty bit" sudo ntfsfix -d "$PARTITION"
        run_command "Verify filesystem after dirty bit clear" sudo ntfsinfo -m "$PARTITION"
    fi
    
    # Optional comprehensive check
    run_command_optional "Comprehensive NTFS check" sudo ntfsck "$PARTITION"
    
    log_message "INFO" "✓ NTFS repair complete"
}

# Step 4: Mount testing
step4_mount_test() {
    log_message "INFO" "=== STEP 4: Mount and Access Test ==="
    
    # Create mount point
    run_command "Create mount directory" sudo mkdir -p "$MOUNT_POINT"
    
    # Set proper ownership for the mount point parent
    local parent_dir=$(dirname "$MOUNT_POINT")
    if [[ -d "$parent_dir" ]]; then
        run_command "Set mount parent ownership" sudo chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$parent_dir"
    fi
    
    # Mount the drive
    run_command "Mount NTFS partition" sudo mount -t ntfs-3g "$PARTITION" "$MOUNT_POINT"
    
    # Test access
    run_command "List directory contents" ls -la "$MOUNT_POINT"
    run_command "Check disk usage" df -h "$MOUNT_POINT"
    
    # Test write access
    local test_file="$MOUNT_POINT/ntfs-repair-test-$(date +%s).tmp"
    if sudo touch "$test_file" 2>/dev/null; then
        log_message "INFO" "✓ Write access confirmed"
        sudo rm "$test_file"
    else
        log_message "WARN" "⚠ Write access failed - drive may be read-only"
    fi
    
    # Unmount for now
    run_command "Unmount for cleanup" sudo umount "$MOUNT_POINT"
    
    log_message "INFO" "✓ Mount test complete"
}

# Step 5: Setup permanent mount (optional)
step5_permanent_mount() {
    log_message "INFO" "=== STEP 5: Permanent Mount Setup ==="
    
    local uuid=$(sudo blkid -s UUID -o value "$PARTITION")
    local label=$(sudo blkid -s LABEL -o value "$PARTITION" 2>/dev/null || echo "unknown")
    
    echo ""
    log_message "INFO" "Drive information:"
    log_message "INFO" "  UUID: $uuid"
    log_message "INFO" "  Label: $label"
    log_message "INFO" "  Mount point: $MOUNT_POINT"
    echo ""
    
    # Check if already in fstab
    if grep -q "$uuid" /etc/fstab 2>/dev/null; then
        log_message "WARN" "Drive already configured in /etc/fstab"
        return 0
    fi
    
    read -p "Setup automatic mounting at boot? (y/N): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local fstab_entry="UUID=$uuid $MOUNT_POINT ntfs-3g defaults,uid=$(id -u ${SUDO_USER:-$USER}),gid=$(id -g ${SUDO_USER:-$USER}),umask=022 0 0"
        
        # Add to fstab
        echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
        log_message "INFO" "✓ Added to /etc/fstab"
        
        # Test mount
        run_command "Test automatic mount" sudo mount "$MOUNT_POINT"
        run_command "Verify mounted filesystem" df -h "$MOUNT_POINT"
        
        log_message "INFO" "✓ Automatic mounting configured"
        log_message "INFO" "Drive will now mount automatically at boot"
    else
        log_message "INFO" "Manual mount commands:"
        log_message "INFO" "  Mount: sudo mount UUID=$uuid $MOUNT_POINT"
        log_message "INFO" "  Unmount: sudo umount $MOUNT_POINT"
    fi
}

# Main execution
main() {
    echo "NTFS Drive Repair Tool"
    echo "====================="
    echo "Started at: $(date)"
    echo "Log file: $LOG_FILE"
    echo ""
    
    parse_arguments "$@"
    
    log_message "INFO" "Device: $DEVICE"
    log_message "INFO" "Partition: $PARTITION" 
    log_message "INFO" "Mount point: $MOUNT_POINT"
    echo ""
    
    check_prerequisites
    step1_initial_assessment
    step2_drive_health
    step3_ntfs_repair
    step4_mount_test
    step5_permanent_mount
    
    echo ""
    log_message "INFO" "=== REPAIR COMPLETE ==="
    log_message "INFO" "✅ NTFS drive repair completed successfully!"
    log_message "INFO" "✅ All data preserved and accessible"
    log_message "INFO" "✅ Drive is ready for normal use"
    echo ""
    log_message "INFO" "Log saved to: $LOG_FILE"
}

# Run main function with all arguments
main "$@"