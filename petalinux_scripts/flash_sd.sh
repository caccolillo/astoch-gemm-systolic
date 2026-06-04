#!/usr/bin/env bash
# =============================================================================
# flash_sd.sh
# Partitions, formats, and flashes the SD card for the Ultra96-V2.
#
# Usage:
#   ./flash_sd.sh /dev/sdX
#
# WARNING: this ERASES the target device. Double-check with lsblk first.
# =============================================================================
set -euo pipefail

SD="${1:?Usage: ./flash_sd.sh /dev/sdX}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# IMAGES_DIR resolution -- in priority order:
#   1. Explicit override:  IMAGES_DIR=/path/to/images/linux ./flash_sd.sh /dev/sdX
#   2. Current directory contains the image files (run from images/linux)
#   3. Default: <script_dir>/gemm_linux/images/linux
if [[ -z "${IMAGES_DIR:-}" ]]; then
    if [[ -f "$(pwd)/BOOT.BIN" ]]; then
        IMAGES_DIR="$(pwd)"
    else
        IMAGES_DIR="$SCRIPT_DIR/gemm_linux/images/linux"
    fi
fi

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GRN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YLW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Safety checks.
[[ -b "$SD" ]]         || error "Not a block device: $SD"
[[ $EUID -eq 0 ]] || [[ $(id -u) -eq 0 ]] || \
    error "Run as root or with sudo: sudo ./flash_sd.sh $SD"

for f in BOOT.BIN image.ub boot.scr rootfs.ext4; do
    [[ -f "$IMAGES_DIR/$f" ]] || \
        error "Missing build output: $IMAGES_DIR/$f (run build_petalinux.sh first)"
done

# Confirm with user.
echo ""
warn "This will ERASE all data on $SD"
echo ""
lsblk "$SD"
echo ""
read -r -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { info "Aborted."; exit 0; }

# Unmount any existing partitions -- including automounted ones.
info "Unmounting any mounted partitions on $SD..."
# Ubuntu automounts SD cards under /media -- force unmount all of them.
for part in "${SD}"?*; do
    if mountpoint -q "$part" 2>/dev/null || grep -q "$part" /proc/mounts 2>/dev/null; then
        sudo umount -l "$part" 2>/dev/null || true
    fi
done
# Also unmount by mount path in case device node differs
grep "$SD" /proc/mounts | awk '{print $2}' | xargs -r sudo umount -l 2>/dev/null || true
sleep 1
for part in "${SD}"[0-9]*; do
    if mountpoint -q "$part" 2>/dev/null; then
        sudo umount "$part" || true
    fi
done
sync

# ---- Partition --------------------------------------------------------------
# IMPORTANT: Ultra96-V2 boot ROM requires MBR/DOS partition table.
# GPT will cause FSBL to hang (all LEDs on, no serial output).
info "Partitioning $SD (MBR/DOS -- required by Ultra96-V2)..."
sudo wipefs -a "$SD"
sudo dd if=/dev/zero of="$SD" bs=512 count=2048 2>/dev/null || true
sync

# MBR partition table:
#   p1: 512MB FAT32 LBA (type c), boot flag set
#   p2: remainder, Linux (type 83)
printf 'o\nn\np\n1\n\n+512M\nt\nc\na\n1\nn\np\n2\n\n\nw\n' | sudo fdisk "$SD"
sync

# Kernel needs a moment to re-read the partition table.
sleep 2
sudo partprobe "$SD" 2>/dev/null || true
sleep 1

# Determine partition suffix (sdX -> sdX1, mmcblkXp1 etc.)
if [[ "$SD" == *"mmcblk"* ]]; then
    PART1="${SD}p1"
    PART2="${SD}p2"
else
    PART1="${SD}1"
    PART2="${SD}2"
fi

# ---- Format -----------------------------------------------------------------
info "Formatting boot partition (FAT32)..."
sudo mkfs.vfat -F 32 -n BOOT "$PART1"

info "Formatting rootfs partition (EXT4)..."
sudo mkfs.ext4 -F -L rootfs "$PART2"

# ---- Copy boot files --------------------------------------------------------
info "Copying boot files to FAT32 partition..."
MOUNT_DIR=$(mktemp -d)
sudo mount "$PART1" "$MOUNT_DIR"
sudo cp "$IMAGES_DIR/BOOT.BIN" "$MOUNT_DIR/"
sudo cp "$IMAGES_DIR/image.ub" "$MOUNT_DIR/"
sudo cp "$IMAGES_DIR/boot.scr"  "$MOUNT_DIR/"
sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
info "Boot partition written"

# ---- Flash rootfs -----------------------------------------------------------
info "Flashing rootfs.ext4 (this may take a few minutes)..."
ROOTFS_SIZE=$(stat -c%s "$IMAGES_DIR/rootfs.ext4")
info "rootfs size: $(( ROOTFS_SIZE / 1024 / 1024 )) MB"

sudo dd \
    if="$IMAGES_DIR/rootfs.ext4" \
    of="$PART2" \
    bs=4M \
    status=progress \
    conv=fsync
sudo sync

info "SD card flashed successfully."
echo ""
echo "============================================================"
echo "  Insert the SD card into the Ultra96-V2 and power on."
echo "  Serial console: 115200 8N1 on the micro-USB debug port."
echo "  After boot, run: gemm-test"
echo "============================================================"
