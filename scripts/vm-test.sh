#!/usr/bin/env bash
# vm-test.sh — Automated VM test for WarmShower OS package repository.
#
# Boots a minimal Arch Linux VM (via QEMU), adds the WarmShower repository,
# installs the keyring + mirrorlist, and verifies the full package pipeline
# works end-to-end.
#
# Requirements:
#   - QEMU (qemu-system-x86_64)
#   - An Arch Linux cloud image (see --image flag)
#   - sshpass (for non-interactive SSH)
#
# Usage:
#   scripts/vm-test.sh [--repo-dir <dir>] [--image <img>] [--arch <arch>]
#
# Options:
#   --repo-dir   Local repository root (default: /tmp/ws-repo)
#   --image      Path to Arch Linux cloud image .qcow2 (default: auto-download)
#   --arch       Target architecture (default: x86_64)
#   --no-kvm     Disable KVM acceleration (slower, but works without /dev/kvm)
#
# The script:
#   1. Starts a QEMU VM with a temporary disk (copy-on-write over base image)
#   2. Waits for SSH to be available
#   3. Copies the local repository to the VM via 9p (virtio-fs) mount
#   4. Installs warmshower-keyring
#   5. Adds [warmshower] to pacman.conf
#   6. Installs warmshower-mirrorlist
#   7. Runs pacman -Syu
#   8. Verifies signatures
#   9. Shuts down the VM and reports results
#
# Notes:
#   - The VM state is discarded after every run (ephemeral).
#   - Use libvirt/virsh for persistent VM environments (see docs/).

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_DIR="/tmp/ws-repo"
ARCH="x86_64"
VM_MEM="1G"
VM_CPUS="2"
VM_PORT="10022"
VM_IMAGE=""
USE_KVM=true
IMAGE_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
IMAGE_DIR="${HOME}/.cache/warmshower-vm"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)     REPO_DIR="$2"; shift 2 ;;
        --repo-dir=*)   REPO_DIR="${1#*=}"; shift ;;
        --image)        VM_IMAGE="$2"; shift 2 ;;
        --image=*)      VM_IMAGE="${1#*=}"; shift ;;
        --arch)         ARCH="$2"; shift 2 ;;
        --arch=*)       ARCH="${1#*=}"; shift ;;
        --no-kvm)       USE_KVM=false; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)              echo "Unknown argument: $1"; exit 1 ;;
    esac
done

ARCH_DIR="${REPO_DIR}/${ARCH}"

echo "=== WarmShower VM Test ==="
echo "Repo dir:   ${ARCH_DIR}"
echo "KVM:        ${USE_KVM}"
echo ""

# ── Preflight checks ─────────────────────────────────────────────────────────
echo "--- Preflight: checking dependencies ---"
MISSING_TOOLS=0
for tool in qemu-system-x86_64 qemu-img ssh sshpass; do
    if command -v "$tool" &>/dev/null; then
        echo "  OK: $tool ($(command -v "$tool"))"
    else
        echo "  MISSING: $tool"
        MISSING_TOOLS=$((MISSING_TOOLS + 1))
    fi
done

if [ "$MISSING_TOOLS" -gt 0 ]; then
    echo ""
    echo "ERROR: $MISSING_TOOLS required tool(s) not found."
    echo ""
    echo "Install on Arch Linux:"
    echo "  sudo pacman -S qemu-base qemu-img openssh sshpass"
    echo ""
    echo "Install on Debian/Ubuntu:"
    echo "  sudo apt install qemu-system-x86 qemu-utils openssh-client sshpass"
    exit 1
fi
echo ""

# ── Check repository has packages ────────────────────────────────────────────
echo "--- Checking local repository ---"
if [ ! -d "$ARCH_DIR" ]; then
    echo "ERROR: Repository not found: ${ARCH_DIR}"
    echo "Run: scripts/bootstrap-repo.sh --repo-dir ${REPO_DIR}"
    exit 1
fi

KEYRING_PKG=$(find "$ARCH_DIR" -name "warmshower-keyring-*.pkg.tar.zst" | head -1)
MIRRORLIST_PKG=$(find "$ARCH_DIR" -name "warmshower-mirrorlist-*.pkg.tar.zst" | head -1)

if [ -z "$KEYRING_PKG" ]; then
    echo "ERROR: warmshower-keyring package not found in ${ARCH_DIR}"
    echo "Build it with: wsync build warmshower-keyring-pkg"
    exit 1
fi
if [ -z "$MIRRORLIST_PKG" ]; then
    echo "ERROR: warmshower-mirrorlist package not found in ${ARCH_DIR}"
    echo "Build it with: wsync build warmshower-mirrorlist-pkg"
    exit 1
fi
echo "  OK: keyring   — $(basename "$KEYRING_PKG")"
echo "  OK: mirrorlist — $(basename "$MIRRORLIST_PKG")"
echo ""

# ── Download/cache base image ─────────────────────────────────────────────────
echo "--- Base image ---"
mkdir -p "$IMAGE_DIR"
BASE_IMAGE="${IMAGE_DIR}/arch-cloudimg.qcow2"

if [ -n "$VM_IMAGE" ]; then
    BASE_IMAGE="$VM_IMAGE"
    echo "  Using provided image: ${BASE_IMAGE}"
elif [ -f "$BASE_IMAGE" ]; then
    echo "  Using cached image: ${BASE_IMAGE}"
else
    echo "  Downloading Arch Linux cloud image (this may take a while)..."
    echo "  URL: ${IMAGE_URL}"
    curl -L --progress-bar -o "$BASE_IMAGE" "$IMAGE_URL"
    echo "  Downloaded: ${BASE_IMAGE}"
fi
echo ""

# ── Create ephemeral overlay disk ─────────────────────────────────────────────
echo "--- Creating ephemeral VM disk ---"
EPHEMERAL_DISK=$(mktemp "${IMAGE_DIR}/ws-vm-XXXXXX.qcow2")
qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$EPHEMERAL_DISK" 8G
echo "  Overlay disk: ${EPHEMERAL_DISK}"
echo ""

# ── cloud-init seed ───────────────────────────────────────────────────────────
# Create a minimal cloud-init seed ISO so the VM gets an SSH key on first boot.
echo "--- Preparing cloud-init seed ---"
SEED_DIR=$(mktemp -d)
SSH_KEY_FILE="${IMAGE_DIR}/vm-test-id_ed25519"
if [ ! -f "$SSH_KEY_FILE" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "warmshower-vm-test"
fi
SSH_PUB_KEY=$(cat "${SSH_KEY_FILE}.pub")

cat > "${SEED_DIR}/user-data" << CLOUDINIT
#cloud-config
users:
  - name: arch
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}
password: warmshower
chpasswd:
  expire: false
runcmd:
  - systemctl enable sshd
  - systemctl start sshd
CLOUDINIT

cat > "${SEED_DIR}/meta-data" << METAEOF
instance-id: warmshower-vm-test
local-hostname: warmshower-vm
METAEOF

SEED_ISO="${IMAGE_DIR}/seed.iso"
# Create ISO with genisoimage or mkisofs
if command -v genisoimage &>/dev/null; then
    genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock \
        "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
elif command -v mkisofs &>/dev/null; then
    mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock \
        "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
elif command -v cloud-localds &>/dev/null; then
    cloud-localds "$SEED_ISO" "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data"
else
    echo "ERROR: Need genisoimage, mkisofs, or cloud-localds for cloud-init seed."
    exit 1
fi
echo "  Seed ISO: ${SEED_ISO}"
echo ""

# ── Start QEMU VM ─────────────────────────────────────────────────────────────
echo "--- Starting VM ---"
KVM_FLAGS=""
if [ "$USE_KVM" = "true" ] && [ -w /dev/kvm ]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

# Share the local repository directory into the VM via virtio-9p
QEMU_CMD=(
    qemu-system-x86_64
    $KVM_FLAGS
    -m "$VM_MEM"
    -smp "$VM_CPUS"
    -nographic
    -serial none
    -monitor none
    -drive "file=${EPHEMERAL_DISK},if=virtio,format=qcow2"
    -drive "file=${SEED_ISO},if=virtio,format=raw,readonly=on"
    -virtfs "local,path=${REPO_DIR},mount_tag=wsrepo,security_model=mapped-xattr,readonly=on"
    -netdev "user,id=net0,hostfwd=tcp::${VM_PORT}-:22"
    -device "virtio-net-pci,netdev=net0"
)

# Launch in background
"${QEMU_CMD[@]}" &
VM_PID=$!
echo "  VM PID: ${VM_PID}"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
echo "--- Waiting for VM SSH ---"
MAX_WAIT=120
ELAPSED=0
while ! sshpass -p "warmshower" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o UserKnownHostsFile=/dev/null \
        -p "$VM_PORT" arch@localhost "echo ready" &>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "  Waiting... (${ELAPSED}s / ${MAX_WAIT}s)"
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo "ERROR: VM did not become reachable within ${MAX_WAIT}s."
        kill "$VM_PID" 2>/dev/null || true
        rm -f "$EPHEMERAL_DISK"
        exit 1
    fi
done
echo "  VM is up."
echo ""

# SSH helper
vm_ssh() {
    ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY_FILE" \
        -p "$VM_PORT" \
        arch@localhost "$@"
}

# ── Mount shared repository inside VM ────────────────────────────────────────
echo "--- Mounting shared repository ---"
vm_ssh "sudo mkdir -p /mnt/wsrepo && sudo mount -t 9p -o trans=virtio wsrepo /mnt/wsrepo"
echo "  Mounted /mnt/wsrepo"
echo ""

TEST_FAILURES=0

# ── Test 1: Install warmshower-keyring ───────────────────────────────────────
echo "--- Test 1: Install warmshower-keyring ---"
KEYRING_FILENAME=$(basename "$KEYRING_PKG")
if vm_ssh "sudo pacman -U --noconfirm /mnt/wsrepo/${ARCH}/${KEYRING_FILENAME}"; then
    echo "  PASS: warmshower-keyring installed"
    vm_ssh "sudo pacman-key --populate warmshower" && echo "  PASS: pacman-key populated"
else
    echo "  FAIL: warmshower-keyring install failed"
    TEST_FAILURES=$((TEST_FAILURES + 1))
fi
echo ""

# ── Test 2: Configure pacman.conf ────────────────────────────────────────────
echo "--- Test 2: Configure pacman.conf ---"
vm_ssh "sudo bash -c 'printf \"\n[warmshower]\nServer = file:///mnt/wsrepo/${ARCH}\n\" >> /etc/pacman.conf'"
echo "  PASS: pacman.conf updated"
echo ""

# ── Test 3: Sync and install mirrorlist ──────────────────────────────────────
echo "--- Test 3: Sync and install warmshower-mirrorlist ---"
if vm_ssh "sudo pacman -Sy --noconfirm && sudo pacman -S --noconfirm warmshower-mirrorlist"; then
    echo "  PASS: warmshower-mirrorlist installed"
else
    echo "  FAIL: warmshower-mirrorlist install failed"
    TEST_FAILURES=$((TEST_FAILURES + 1))
fi
echo ""

# ── Test 4: Full upgrade ──────────────────────────────────────────────────────
echo "--- Test 4: pacman -Syu ---"
if vm_ssh "sudo pacman -Syu --noconfirm"; then
    echo "  PASS: pacman -Syu succeeded"
else
    echo "  FAIL: pacman -Syu failed"
    TEST_FAILURES=$((TEST_FAILURES + 1))
fi
echo ""

# ── Test 5: Verify package integrity ─────────────────────────────────────────
echo "--- Test 5: pacman -Qkk verification ---"
if vm_ssh "pacman -Qkk warmshower-keyring warmshower-mirrorlist"; then
    echo "  PASS: Package integrity verified"
else
    echo "  FAIL: Package integrity check failed"
    TEST_FAILURES=$((TEST_FAILURES + 1))
fi
echo ""

# ── Cleanup ───────────────────────────────────────────────────────────────────
echo "--- Shutting down VM ---"
vm_ssh "sudo poweroff" || true
wait "$VM_PID" || true
rm -f "$EPHEMERAL_DISK"
rm -rf "$SEED_DIR"
echo "  VM stopped and disk cleaned up."
echo ""

# ── Result ────────────────────────────────────────────────────────────────────
echo "=== VM Test Result ==="
if [ "$TEST_FAILURES" -eq 0 ]; then
    echo "PASS — All VM tests passed."
    exit 0
else
    echo "FAIL — ${TEST_FAILURES} VM test(s) failed."
    exit 1
fi
