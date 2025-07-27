#!/bin/bash

# Setup permanent mount for the repaired NTFS drive
set -euo pipefail

PARTITION="/dev/sdc1"
MOUNT_POINT="/media/stonecharioteer/nvme-disk"
UUID="1131CD845F46769F"

echo "=== Setup Permanent Mount ===="
echo "This will add your drive to /etc/fstab for automatic mounting"
echo ""

# Check if already in fstab
if grep -q "$UUID" /etc/fstab 2>/dev/null; then
    echo "⚠️  Drive already configured in /etc/fstab"
    echo "Current entry:"
    grep "$UUID" /etc/fstab
    exit 0
fi

echo "Adding fstab entry for automatic mounting..."
echo "UUID=$UUID $MOUNT_POINT ntfs-3g defaults,uid=1000,gid=1000,umask=022 0 0" | sudo tee -a /etc/fstab

echo ""
echo "✅ Permanent mount configured!"
echo ""
echo "Your drive will now:"
echo "  • Mount automatically at boot to $MOUNT_POINT"
echo "  • Be owned by your user (stonecharioteer)"
echo "  • Have full read/write permissions"
echo ""
echo "To mount it now: sudo mount $MOUNT_POINT"
echo "To unmount: sudo umount $MOUNT_POINT"
echo ""
echo "🎉 Drive repair and setup complete!"