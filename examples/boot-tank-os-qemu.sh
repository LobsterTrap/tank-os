#!/usr/bin/env bash
# boot-tank-os-qemu.sh - Launch tank-os disk image with QEMU
# Supports both KVM and TCG fallback for portability across different host systems

set -euo pipefail

# Configuration
DISK_IMAGE="${1:-.}"
DISK_PATH=""
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
SSH_PORT="${SSH_PORT:-2222}"
QEMU_MEM="${QEMU_MEM:-4096}"
QEMU_SMP="${QEMU_SMP:-2}"
OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS="${OVMF_VARS:-}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Resolve disk image path
if [[ -d "$DISK_IMAGE" ]]; then
    DISK_PATH="$DISK_IMAGE/qcow2/disk.qcow2"
elif [[ -f "$DISK_IMAGE" ]]; then
    DISK_PATH="$DISK_IMAGE"
else
    echo -e "${RED}ERROR: Disk image not found: $DISK_IMAGE${NC}"
    echo "Usage: $0 <path-to-disk-image-or-output-dir>"
    exit 1
fi

if [[ ! -f "$DISK_PATH" ]]; then
    echo -e "${RED}ERROR: Disk image not found: $DISK_PATH${NC}"
    exit 1
fi

echo -e "${GREEN}tank-os QEMU Launcher${NC}"
echo "-----------------------------------------------"
echo "Disk Image: $DISK_PATH"
echo "Memory: ${QEMU_MEM}M"
echo "CPU Cores: $QEMU_SMP"
echo "SSH Port: localhost:$SSH_PORT"
echo ""

# Check QEMU availability
if ! command -v "$QEMU_BIN" &> /dev/null; then
    echo -e "${RED}ERROR: $QEMU_BIN not found. Install QEMU and retry.${NC}"
    exit 1
fi

# Detect OVMF firmware files
detect_ovmf() {
    local code_fd=""
    local vars_fd=""

    # Prefer 4M variants (most common on modern systems)
    for path in /usr/share/OVMF /usr/share/ovmf /usr/share/edk2-ovmf; do
        if [[ -f "$path/OVMF_CODE_4M.fd" ]]; then
            code_fd="$path/OVMF_CODE_4M.fd"
            [[ -f "$path/OVMF_VARS_4M.fd" ]] && vars_fd="$path/OVMF_VARS_4M.fd"
            break
        elif [[ -f "$path/OVMF_CODE.fd" ]]; then
            code_fd="$path/OVMF_CODE.fd"
            [[ -f "$path/OVMF_VARS.fd" ]] && vars_fd="$path/OVMF_VARS.fd"
            break
        fi
    done

    if [[ -z "$code_fd" ]]; then
        echo -e "${RED}ERROR: OVMF firmware not found in standard locations${NC}"
        echo "Install OVMF (apt install ovmf or pacman -S edk2-ovmf) and retry."
        exit 1
    fi

    echo "$code_fd"
    echo "$vars_fd"
}

# Detect KVM support
detect_kvm() {
    if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
        return 0
    fi
    return 1
}

# Read OVMF paths unless they were provided by the caller.
if [[ -z "$OVMF_CODE" ]]; then
    mapfile -t _ovmf_paths < <(detect_ovmf)
    OVMF_CODE="${_ovmf_paths[0]}"
    OVMF_VARS="${_ovmf_paths[1]:-}"
fi
if [[ -z "$OVMF_VARS" ]]; then
    echo -e "${RED}ERROR: OVMF variables file not found. Set OVMF_VARS=/path/to/OVMF_VARS.fd and retry.${NC}"
    exit 1
fi
echo -e "${GREEN}OK: OVMF firmware: $(basename "$OVMF_CODE")${NC}"

# Determine acceleration
ACCEL="tcg"
if detect_kvm; then
    ACCEL="kvm"
    echo -e "${GREEN}OK: KVM available - using hardware acceleration${NC}"
else
    echo -e "${YELLOW}WARN: KVM unavailable - using TCG (software emulation)${NC}"
    echo "   Performance will be reduced. For production, use KVM-enabled host."
fi

# Prepare OVMF variables copy (must be writable)
WORK_DIR=$(dirname "$DISK_PATH")
OVMF_VARS_COPY="$WORK_DIR/$(basename "$OVMF_VARS")"

if [[ ! -f "$OVMF_VARS_COPY" ]]; then
    echo -e "${YELLOW}-> Copying OVMF variables to work directory${NC}"
    cp "$OVMF_VARS" "$OVMF_VARS_COPY"
fi

echo ""
echo -e "${GREEN}Launching QEMU...${NC}"
echo "-----------------------------------------------"
echo ""
echo "To access the VM:"
echo "  ssh -i ~/.ssh/id_ed25519 -p $SSH_PORT openclaw@localhost"
echo ""
echo "To view the dashboard from host:"
echo "  ssh -L 18789:127.0.0.1:18789 -p $SSH_PORT openclaw@localhost"
echo "  Then: http://127.0.0.1:18789"
echo ""
echo "Press Ctrl+A X to quit QEMU (or 'quit' in QEMU monitor)"
echo ""

# Launch QEMU
exec "$QEMU_BIN" \
    -machine q35,accel="$ACCEL" \
    -cpu max \
    -smp "$QEMU_SMP" \
    -m "$QEMU_MEM" \
    -drive file="$DISK_PATH",format=qcow2,if=virtio \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_COPY" \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
    -nographic
