#!/usr/bin/env bash
# =============================================================================
# build_petalinux.sh
# Fully scripted PetaLinux 2022.2 build for the stochastic GEMM accelerator
# on the Avnet Ultra96-V2. No interactive menus -- everything is driven by
# config fragment files and command-line options.
#
# Usage:
#   chmod +x build_petalinux.sh
#   ./build_petalinux.sh  [--xsa PATH]  [--plnx PATH]  [--jobs N]
#
# Options:
#   --xsa   PATH   Path to gemm_accel.xsa  (default: ./gemm_accel.xsa)
#   --plnx  PATH   PetaLinux install dir   (default: ~/petalinux/2022.2)
#   --jobs  N      Parallel build jobs     (default: 4)
#
# What this script does, in order:
#   1.  Validate prerequisites
#   2.  Create the PetaLinux project
#   3.  Import the .xsa hardware description
#   4.  Apply system config fragments (UART, rootfs type, SD device)
#   5.  Apply kernel config fragments (DMA engine, UIO, ConfigFS)
#   6.  Install device tree files and system-user.dtsi
#   7.  Create BitBake recipe for the dma-proxy kernel module
#   8.  Create BitBake recipe for the gemm-test userspace application
#   9.  Enable modules and app in rootfs config
#  10.  Build everything (petalinux-build)
#  11.  Package boot image (BOOT.BIN + image.ub)
#  12.  Print SD card flashing instructions
#
# Outputs (in ./gemm_linux/images/linux/):
#   BOOT.BIN     bootloader + bitstream (FAT32 partition)
#   image.ub     kernel + dtb + rootfs  (FAT32 partition)
#   rootfs.ext4  root filesystem        (EXT4 partition, optional)
#
# =============================================================================
set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
XSA_PATH="./gemm_accel.xsa"
PLNX_PATH="$HOME/petalinux"
JOBS=4
PROJ_NAME="gemm_linux"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --xsa)   XSA_PATH="$2";  shift 2 ;;
        --plnx)  PLNX_PATH="$2"; shift 2 ;;
        --jobs)  JOBS="$2";      shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

XSA_PATH="$(realpath "$XSA_PATH")"
PROJ_DIR="$SCRIPT_DIR/$PROJ_NAME"

# ---- Colours ----------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GRN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YLW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${YLW}========================================${NC}"; \
          echo -e "${YLW} $*${NC}"; \
          echo -e "${YLW}========================================${NC}"; }

# =============================================================================
# STEP 1 — Validate prerequisites
# =============================================================================
step "1/12  Validating prerequisites"

[[ -f "$XSA_PATH" ]]        || error "XSA not found: $XSA_PATH"
[[ -d "$PLNX_PATH" ]]       || error "PetaLinux not found: $PLNX_PATH"
[[ -f "$PLNX_PATH/settings.sh" ]] || error "PetaLinux settings.sh not found"

# Source PetaLinux environment if not already sourced.
if ! command -v petalinux-create &>/dev/null; then
    info "Sourcing PetaLinux environment from $PLNX_PATH/settings.sh"
    # shellcheck source=/dev/null
    source "$PLNX_PATH/settings.sh"
fi
command -v petalinux-create &>/dev/null || error "petalinux-create not on PATH"

# Check required source files are present next to this script.
for f in stoch_gemm_uio.dtso gemm_test_uio.c; do
    [[ -f "$SCRIPT_DIR/$f" ]] || \
        error "Required file missing: $SCRIPT_DIR/$f"
done

info "XSA:       $XSA_PATH"
info "PetaLinux: $PLNX_PATH"
info "Project:   $PROJ_DIR"
info "Jobs:      $JOBS"

# =============================================================================
# STEP 2 — Create the PetaLinux project
# =============================================================================
step "2/12  Creating PetaLinux project"

if [[ -d "$PROJ_DIR" ]]; then
    warn "Project directory already exists: $PROJ_DIR"
    warn "Delete it and re-run, or set --proj to a different name."
    warn "Continuing with existing project..."
else
    petalinux-create \
        --type project \
        --template zynqMP \
        --name "$PROJ_NAME"
    info "Project created: $PROJ_DIR"
fi

cd "$PROJ_DIR"

# =============================================================================
# STEP 3 — Import the hardware description (.xsa)
# =============================================================================
step "3/12  Importing hardware description"

# --silentconfig skips the interactive menuconfig.
petalinux-config \
    --get-hw-description "$XSA_PATH" \
    --silentconfig

info "Hardware imported from: $XSA_PATH"

# =============================================================================
# STEP 4 — System-level configuration fragments
# =============================================================================
step "4/12  Applying system config fragments"

# PetaLinux stores its top-level config in
# project-spec/configs/config. We append fragments to override
# specific settings without needing interactive menuconfig.
#
# The fragment file uses Kconfig syntax.

SYSCFG_DIR="$PROJ_DIR/project-spec/configs"
SYSCFG_FRAG="$SYSCFG_DIR/config_fragment"

cat > "$SYSCFG_FRAG" << 'SYSCFG'
# -----------------------------------------------------------------------------
# System configuration fragment for gemm_accel on Ultra96-V2
# Applied non-interactively via --config-fragments
# -----------------------------------------------------------------------------

# Serial console: Ultra96-V2 debug UART is on PS UART1
CONFIG_SUBSYSTEM_SERIAL_PSU_UART_1_SELECT=y

# Root filesystem: EXT4 on the second SD card partition
CONFIG_SUBSYSTEM_ROOTFS_EXT4=y
CONFIG_SUBSYSTEM_SDROOT_DEV="/dev/mmcblk0p2"
CONFIG_SUBSYSTEM_RFS_FORMATS="ext4 ext4.gz"

# Boot args: console, root device, quiet boot
CONFIG_SUBSYSTEM_BOOTARGS_AUTO=n
CONFIG_SUBSYSTEM_BOOTARGS="earlycon console=ttyPS1,115200 root=/dev/mmcblk0p2 rw rootwait"

# Board hostname
CONFIG_SUBSYSTEM_HOSTNAME="ultra96-gemm"
CONFIG_SUBSYSTEM_PRODUCT="ultra96-gemm-accel"

# Machine name: tells DTG to use the Ultra96-V2 board device tree.
# Without this PetaLinux generates a generic DTS that lacks the SD
# 1.8V signalling config -- the board hangs reading the SD card after FSBL.
CONFIG_SUBSYSTEM_MACHINE_NAME="avnet-ultra96-rev1"
SYSCFG

# Re-run config with the fragment to apply it silently.
petalinux-config \
    --silentconfig \
    -- --fragment="$SYSCFG_FRAG" \
    2>/dev/null || \
petalinux-config --silentconfig  # fallback: re-apply without explicit fragment

info "System config fragments applied"

# =============================================================================
# STEP 5 — Kernel configuration fragments
# =============================================================================
step "5/12  Applying kernel config fragments"

# Kernel config fragments are placed in the meta-user layer and referenced
# by the linux-xlnx_%.bbappend recipe.

KERNEL_CFG_DIR="$PROJ_DIR/project-spec/meta-user/recipes-kernel/linux/linux-xlnx"
mkdir -p "$KERNEL_CFG_DIR"

cat > "$KERNEL_CFG_DIR/gemm_accel.cfg" << 'KCFG'
# -----------------------------------------------------------------------------
# Kernel config fragment for the GEMM accelerator on Ultra96-V2
# Enables: UIO, Xilinx DMA engine, ConfigFS for device tree overlays
# -----------------------------------------------------------------------------

# UIO -- userspace I/O driver for accelerator register access (no custom .ko)
CONFIG_UIO=y
CONFIG_UIO_PDRV_GENIRQ=y

# Xilinx DMA engine (for AXI DMA)
CONFIG_DMADEVICES=y
CONFIG_XILINX_DMA=y
CONFIG_XILINX_DPDMA=n

# ConfigFS -- needed for loading device tree overlays at runtime
CONFIG_CONFIGFS_FS=y

# Device tree overlays (needed for runtime dtbo loading)
CONFIG_OF_OVERLAY=y
CONFIG_OF_CONFIGFS=y
KCFG

# Create or append to the kernel bbappend to reference the fragment.
KERNEL_BBAPPEND="$PROJ_DIR/project-spec/meta-user/recipes-kernel/linux/linux-xlnx_%.bbappend"
cat > "$KERNEL_BBAPPEND" << 'BBAPPEND'
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
SRC_URI:append = " file://gemm_accel.cfg"
BBAPPEND

info "Kernel config fragment written: gemm_accel.cfg"

# =============================================================================
# STEP 6 — Device tree
# =============================================================================
step "6/12  Installing device tree files"

DT_DIR="$PROJ_DIR/project-spec/meta-user/recipes-bsp/device-tree/files"
mkdir -p "$DT_DIR"

# Copy the UIO-based overlay (uses generic-uio, no custom driver).
cp "$SCRIPT_DIR/stoch_gemm_uio.dtso" "$DT_DIR/stoch_gemm.dtso"
info "Copied stoch_gemm_uio.dtso -> stoch_gemm.dtso"

# Append the include to system-user.dtsi.
SYSTEM_USER_DTSI="$DT_DIR/system-user.dtsi"

# Write system-user.dtsi with:
#   - Correct console (UART1 = ttyPS1) and root device bootargs
#   - SD controller 1.8V fix (Ultra96-V2 hard-wires SD I/O to 1.8V;
#     without this U-Boot/kernel hangs on "Card did not respond to
#     voltage select!" and the board appears dead after FSBL)
#   - GEMM accelerator overlay include
cat > "$SYSTEM_USER_DTSI" << 'DTSI_BASE'
/include/ "system-conf.dtsi"

/ {
    chosen {
        bootargs = "earlycon console=ttyPS1,115200 root=/dev/mmcblk0p2 rw rootwait clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio";
        stdout-path = "serial1:115200n8";
    };
};

/*
 * Ultra96-V2 SD fix: the microSD slot (SD0) I/O bank is hard-wired to
 * 1.8V on this board. The default PetaLinux DTS tries 3.3V first and
 * then signals a switch to 1.8V -- but since the hardware is fixed at
 * 1.8V there is no regulator to switch, so the card never responds and
 * the kernel/U-Boot hangs. Setting no-1-8-v disables the voltage switch
 * attempt and the controller communicates at 1.8V from the start.
 *
 * Reference: Ultra96-V2 Hardware User Guide v1.3, section 3.4
 */
&sdhci0 {
    no-1-8-v;
    disable-wp;
    xlnx,mio-bank = <0>;
};

/*
 * AXI DMA interrupt fix.
 * In the Vivado block design, the DMA mm2s_introut and s2mm_introut
 * ports are left unconnected -- only the GEMM accelerator irq is wired
 * to pl_ps_irq0. Without interrupts the DMA transfer starts but the
 * kernel driver never receives completion, so gemm-test hangs.
 *
 * We wire both DMA interrupts to the PS here in the device tree.
 * IRQ numbers: pl_ps_irq0=89 (SPI89), so we use:
 *   mm2s: GIC SPI 90 (IRQ_TYPE_EDGE_RISING)
 *   s2mm: GIC SPI 91 (IRQ_TYPE_EDGE_RISING)
 * These are the next two available SPIs after the GEMM irq on SPI89.
 *
 * If the DMA still hangs after this, use polling mode by rebuilding
 * gemm_test_uio.c with DMA_POLL_MODE defined.
 */
&axi_dma_0 {
    interrupts = <0 90 4>, <0 91 4>;
    interrupt-parent = <&gic>;
};

/* Stochastic GEMM accelerator + AXI DMA nodes */
/include/ "stoch_gemm.dtso"
DTSI_BASE

info "system-user.dtsi written (SD 1.8V fix + GEMM overlay)"

# Register the files with the device-tree recipe.
DT_BBAPPEND="$PROJ_DIR/project-spec/meta-user/recipes-bsp/device-tree/device-tree.bbappend"
if ! grep -q "stoch_gemm.dtso" "$DT_BBAPPEND" 2>/dev/null; then
    cat >> "$DT_BBAPPEND" << 'DTBBAPPEND'

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://stoch_gemm.dtso \
                   file://system-user.dtsi"
DTBBAPPEND
    info "Updated device-tree.bbappend"
fi

# =============================================================================
# STEP 7 — gemm-test userspace application recipe
# (dma-proxy removed -- gemm_test_uio.c uses /dev/mem directly, no proxy needed)
# =============================================================================
step "7/12  Creating gemm-test application recipe"

GEMM_APP_DIR="$PROJ_DIR/project-spec/meta-user/recipes-apps/gemm-test"
GEMM_APP_FILES="$GEMM_APP_DIR/files"
mkdir -p "$GEMM_APP_FILES"

cp "$SCRIPT_DIR/gemm_test_uio.c" "$GEMM_APP_FILES/gemm-test.c"

cat > "$GEMM_APP_DIR/gemm-test.bb" << 'BB'
SUMMARY = "Stochastic GEMM accelerator userspace test (UIO + /dev/mem DMA)"
DESCRIPTION = "Tests stoch_gemm_axis via /dev/uio0 and /dev/dma_proxy_*"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "file://gemm-test.c"

S = "${WORKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -O2 -Wall \
        -o ${WORKDIR}/gemm-test ${WORKDIR}/gemm-test.c -lm
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/gemm-test ${D}${bindir}/gemm-test
}

FILES:${PN} += "${bindir}/gemm-test"
BB

info "gemm-test recipe created"

# =============================================================================
# STEP 9 — Enable packages in rootfs
# =============================================================================
step "9/12  Enabling packages in rootfs config"

ROOTFS_CFG="$PROJ_DIR/project-spec/meta-user/conf/user-rootfsconfig"

# Ensure the file exists.
mkdir -p "$(dirname "$ROOTFS_CFG")"
touch "$ROOTFS_CFG"

for pkg in gemm-test; do
    if ! grep -q "CONFIG_${pkg}" "$ROOTFS_CFG"; then
        echo "CONFIG_${pkg}=y" >> "$ROOTFS_CFG"
        info "Enabled package: $pkg"
    fi
done

# Enable packages directly in the PetaLinux rootfs config file.
# This avoids running silentconfig rootfs with a fragment (which fails
# if the recipes haven't been fully registered yet).
PLNX_ROOTFS_CFG="$PROJ_DIR/project-spec/configs/rootfs_config"

# Ensure the config file exists.
touch "$PLNX_ROOTFS_CFG"

for pkg in gemm-test devmem2 packagegroup-petalinux-utils; do
    if ! grep -q "CONFIG_${pkg}=y" "$PLNX_ROOTFS_CFG"; then
        echo "CONFIG_${pkg}=y" >> "$PLNX_ROOTFS_CFG"
        info "Added to rootfs_config: $pkg"
    fi
done

info "Rootfs config updated (skipping silentconfig to avoid early-registration error)"

# =============================================================================
# STEP 10 — Build
# =============================================================================
step "10/12  Building (this takes 45-90 minutes)"

START_TIME=$(date +%s)

petalinux-build 2>&1 | tee "$SCRIPT_DIR/petalinux_build.log"

BUILD_EXIT=${PIPESTATUS[0]}
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

if [[ $BUILD_EXIT -ne 0 ]]; then
    error "petalinux-build failed after ${ELAPSED_MIN}m${ELAPSED_SEC}s. \
Check: $SCRIPT_DIR/petalinux_build.log"
fi

info "Build completed in ${ELAPSED_MIN}m${ELAPSED_SEC}s"

# =============================================================================
# STEP 11 — Package boot image
# =============================================================================
step "11/12  Packaging boot image"

IMAGES_DIR="$PROJ_DIR/images/linux"

# Verify all required files are present before packaging.
# NOTE: pmufw.elf is MANDATORY on ZynqMP -- FSBL hangs at startup without it.
for f in zynqmp_fsbl.elf system.bit u-boot.elf pmufw.elf; do
    [[ -f "$IMAGES_DIR/$f" ]] || \
        error "Missing build artifact: $IMAGES_DIR/$f"
done

petalinux-package \
    --boot \
    --fsbl   "$IMAGES_DIR/zynqmp_fsbl.elf" \
    --fpga   "$IMAGES_DIR/system.bit" \
    --u-boot  "$IMAGES_DIR/u-boot.elf" \
    --pmufw  "$IMAGES_DIR/pmufw.elf" \
    --force

info "Boot image packaged successfully."
echo ""
info "Output files:"
ls -lh "$IMAGES_DIR/BOOT.BIN" \
       "$IMAGES_DIR/image.ub" \
       "$IMAGES_DIR/rootfs.ext4" 2>/dev/null || true

# =============================================================================
# STEP 12 — SD card flashing (interactive) + instructions
# =============================================================================
step "12/12  SD card flashing"

# Offer to flash now if a flash script is available.
if [[ -f "$SCRIPT_DIR/flash_sd.sh" ]]; then
    echo ""
    warn "Would you like to flash the SD card now?"
    echo "  Insert the micro SD card into your PC first."
    echo ""
    lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | grep -v loop || lsblk
    echo ""
    read -r -p "Enter SD card device (e.g. /dev/sdb) or press Enter to skip: " SD_DEV
    if [[ -n "$SD_DEV" ]]; then
        if [[ -b "$SD_DEV" ]]; then
            sudo bash "$SCRIPT_DIR/flash_sd.sh" "$SD_DEV"
        else
            warn "Device $SD_DEV not found -- skipping. Flash manually with:"
            warn "  sudo ./flash_sd.sh /dev/sdX"
        fi
    else
        info "Skipping SD flash. Run manually when ready:"
        info "  sudo ./flash_sd.sh /dev/sdX"
    fi
fi

# Print full instructions regardless.
cat << 'INSTRUCTIONS'

============================================================
  BUILD COMPLETE
============================================================

Output files (copy these to your SD card):
  images/linux/BOOT.BIN     <- bootloader + bitstream (FAT32 partition)
  images/linux/image.ub     <- kernel + device tree   (FAT32 partition)
  images/linux/rootfs.ext4  <- root filesystem        (EXT4 partition)

============================================================
  HOW TO FLASH THE MICRO SD CARD
============================================================

STEP 1 — Find your SD card device
----------------------------------
Insert the micro SD into your PC, then run:

  lsblk

Look for a device matching your SD card size. It will be
something like /dev/sdb or /dev/mmcblk0. NEVER use your
hard drive (usually /dev/sda with hundreds of GB).

Example lsblk output:
  NAME   SIZE  MODEL
  sda    500G  Samsung SSD    <- hard drive, DO NOT USE
  sdb     32G  SD Card        <- this is your SD card

STEP 2 — Run the flash script
------------------------------
  sudo ./flash_sd.sh /dev/sdX     # replace sdX with your device

The script will:
  - Show you the device details and ask you to type YES
  - Create two partitions: 512 MB FAT32 (BOOT) + rest EXT4 (rootfs)
  - Copy BOOT.BIN and image.ub to the FAT32 partition
  - Flash rootfs.ext4 to the EXT4 partition with dd

Expected time: 5-10 minutes depending on SD card speed.

STEP 3 — OR flash manually (without the script)
-------------------------------------------------
  # Partition with MBR/DOS (REQUIRED -- Ultra96-V2 boot ROM needs MBR,
  # NOT GPT. GPT causes FSBL to hang with all LEDs on):
  printf 'o\nn\np\n1\n\n+512M\nt\nc\na\n1\nn\np\n2\n\n\nw\n' | sudo fdisk /dev/sdX
  sudo partprobe /dev/sdX
  sleep 2

  # Format:
  sudo mkfs.vfat -F 32 -n BOOT    /dev/sdX1
  sudo mkfs.ext4 -F  -L rootfs    /dev/sdX2

  # Copy boot files to FAT32 partition:
  sudo mount /dev/sdX1 /mnt
  sudo cp images/linux/BOOT.BIN images/linux/image.ub /mnt/
  sudo umount /mnt

  # Flash root filesystem:
  sudo dd if=images/linux/rootfs.ext4 \
          of=/dev/sdX2 bs=4M status=progress conv=fsync
  sudo sync

============================================================
  ULTRA96-V2 BOOT SWITCH SETTINGS
============================================================

Set the DIP switches on SW6 to boot from SD card:

  SW6:  1=ON   2=OFF   3=OFF   4=OFF
        [ON]  [OFF]  [OFF]  [OFF]

(If the board is currently set to JTAG boot, change this first)

============================================================
  FIRST BOOT
============================================================

1. Insert the micro SD card into the Ultra96-V2
   (slot is on the underside of the board)

2. Connect the micro-USB debug cable to your PC

3. Open a serial terminal (115200 baud, 8N1, no flow control):
     screen /dev/ttyUSB1 115200
   or:
     minicom -D /dev/ttyUSB1 -b 115200
   or use PuTTY/TeraTerm on Windows

4. Power on the Ultra96-V2

5. Expected boot sequence (takes ~30 seconds):
     Xilinx First Stage Boot Loader
     PMU Firmware
     U-Boot 2021.07
     Starting kernel ...
     [    0.000000] Linux version 5.15.36
     ...
     ultra96-gemm login:

6. Login as root (no password by default)

============================================================
  VERIFY THE ACCELERATOR
============================================================

After logging in:

  # 1. Check the UIO device is present:
  cat /sys/class/uio/uio0/name
  # Expected: stoch_gemm_axis_wrapper

  # 2. Check the AXI DMA is present:
  ls /sys/bus/platform/devices/ | grep a0010000

  # 3. Verify the bitstream loaded (read INFO register):
  devmem2 0xA000000C w
  # Expected: 0x1C1A1008  (N=8 KW=16 CNTW=26 RESW=28)
  # If you get 0xFFFFFFFF: bitstream not loaded
  # If you get 0x00000000: AXI path not working

  # 4. Run the test:
  gemm-test
  # Expected: PSNR ~30 dB for tile 0 at STREAM_LEN=1024

============================================================
  TROUBLESHOOTING
============================================================

Board won't boot / stuck at U-Boot:
  -> Check SW6 boot switches (1=ON, rest OFF)
  -> Check BOOT.BIN was built with the correct .xsa

/dev/uio0 not present:
  -> dmesg | grep -i uio
  -> cat /sys/bus/platform/devices/a0000000.*/of_node/compatible
     (must show: generic-uio)

gemm-test fails with devmem error:
  -> Run as root: sudo gemm-test
  -> Check /dev/mem is accessible

PSNR very low or zero:
  -> devmem2 0xA0000014 w   (ICOUNT, expect 144)
  -> devmem2 0xA0000018 w   (OCOUNT, expect 64)
  -> devmem2 0xA0000004 w   (STATUS, expect 0x2 = DONE)

============================================================
INSTRUCTIONS
