#!/usr/bin/env bash
# ==============================================================================
# MuseOS - AMD64 Multimedia OS QEMU Launch & GDB Debug Script
# ==============================================================================
# Launches QEMU with AMD64 hardware virtualization, 2GB RAM, Multiboot2 kernel,
# simulated DirectStorage NVMe controller, and optional GDB remote debugging.
# ==============================================================================

set -euo pipefail

# Configuration defaults
KERNEL_ELF="${KERNEL_ELF:-kernel/build/museos-kernel.elf}"
DISK_IMAGE="${DISK_IMAGE:-build/nvme_disk.img}"
MEMORY="${MEMORY:-2G}"
GDB_PORT="${GDB_PORT:-1234}"
WAIT_GDB=false
NOGRAPHIC=false

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -k, --kernel PATH    Path to compiled kernel ELF (default: ${KERNEL_ELF})
  -d, --disk PATH      Path to NVMe disk image (default: ${DISK_IMAGE})
  -m, --memory SIZE    Memory allocation for VM (default: ${MEMORY})
  -g, --gdb            Enable GDB server on port ${GDB_PORT} and wait for connection (-s -S)
  -n, --nographic      Disable graphical window, output to serial stdio
  -h, --help           Display this help message
EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--kernel) KERNEL_ELF="$2"; shift 2 ;;
        -d|--disk) DISK_IMAGE="$2"; shift 2 ;;
        -m|--memory) MEMORY="$2"; shift 2 ;;
        -g|--gdb) WAIT_GDB=true; shift ;;
        -n|--nographic) NOGRAPHIC=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Ensure build artifacts exist or notify user
if [[ ! -f "$KERNEL_ELF" ]]; then
    echo "[!] Warning: Kernel binary not found at $KERNEL_ELF"
    echo "[!] Run 'zig build' first to compile the kernel image."
fi

# Ensure disk image exists or create dummy NVMe image
if [[ ! -f "$DISK_IMAGE" ]]; then
    echo "[+] Creating empty 1GB NVMe storage image at $DISK_IMAGE..."
    mkdir -p "$(dirname "$DISK_IMAGE")"
    qemu-img create -f raw "$DISK_IMAGE" 1G
fi

# Base QEMU flags for AMD64 bare-metal execution
QEMU_ARGS=(
    -machine q35,accel=kvm:hvf:tcg
    -cpu qemu64,+pdpe1gb,+avx2,+bmi1,+bmi2,+smep,+smap
    -m "$MEMORY"
    -kernel "$KERNEL_ELF"
    -serial stdio
    -drive file="$DISK_IMAGE",if=none,id=nvm0,format=raw
    -device nvme,serial=MUSEOS_NVME_001,drive=nvm0
    -device virtio-gpu-pci
    -no-reboot
    -no-shutdown
)

# Append GDB debugging flags if requested
if [ "$WAIT_GDB" = true ]; then
    echo "[+] GDB Remote Debugging active on tcp::${GDB_PORT}. Waiting for debugger..."
    echo "[+] Connect using: gdb -ex 'target remote localhost:${GDB_PORT}' $KERNEL_ELF"
    QEMU_ARGS+=(-gdb "tcp::${GDB_PORT}" -S)
fi

# Graphics vs Nographic mode
if [ "$NOGRAPHIC" = true ]; then
    QEMU_ARGS+=(-nographic)
fi

echo "[+] Launching QEMU for MuseOS..."
echo "    Kernel : $KERNEL_ELF"
echo "    Memory : $MEMORY"
echo "    NVMe   : $DISK_IMAGE"
echo "------------------------------------------------------------"

exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
