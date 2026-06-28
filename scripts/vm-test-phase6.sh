#!/usr/bin/env bash
# vm-test-phase6.sh — Phase 6 first-boot validation for WarmShower OS.
#
# Works in two modes:
#
#   LOCAL mode  (default, no live repo required)
#     Mounts a local repository built with bootstrap-repo.sh + wsync publish.
#     Use this until repo.warmshower.ai is live (WS-001 + WS-036 complete).
#
#   HOSTED mode (requires repo.warmshower.ai to be live)
#     Pulls packages from the live CDN.  Use this for final Phase 6 sign-off.
#
# Validation checks (both modes):
#   1.  warmshower-keyring installs and pacman-key populates
#   2.  pacman.conf contains [warmshower] and no [cachyos]
#   3.  pacman -Sy downloads warmshower.db successfully
#   4.  warmshower-mirrorlist installs (signed in hosted; local file in local)
#   5.  warmshower-settings installs
#   6.  warmshower-hooks installs; hook files use warmshower- prefix
#   7.  mkinitcpio -P builds initramfs without error
#   8.  pacman -Syu succeeds (update cycle)
#   9.  pacman -Qkk passes for all warmshower-* packages
#   10. pacman -Dk passes (database consistency)
#   11. Branding audit: no CachyOS strings in /etc /usr/bin /usr/share/libalpm
#   12. Kernel check: if linux-warmshower is in repo, installs and uname verified
#
# LOCAL mode pre-conditions:
#   scripts/bootstrap-repo.sh --repo-dir /tmp/ws-repo
#   wsync build warmshower-keyring-pkg  [--sign if key available]
#   wsync build warmshower-mirrorlist-pkg --sign
#   wsync build warmshower-settings-pkg --sign
#   wsync build warmshower-hooks --sign
#   wsync build mkinitcpio --sign
#   wsync publish --repo-dir /tmp/ws-repo
#   Then: scripts/vm-test-phase6.sh --repo-dir /tmp/ws-repo
#
# HOSTED mode pre-conditions:
#   WS-001, WS-002, WS-036 complete; all bootstrap packages published.
#   Then: scripts/vm-test-phase6.sh --repo-url https://repo.warmshower.ai
#
# Requirements (both modes):
#   qemu-system-x86_64, qemu-img, ssh, sshpass
#   genisoimage or cloud-localds (for cloud-init seed)
#
# Usage:
#   scripts/vm-test-phase6.sh [--repo-dir <dir>] [--repo-url <url>]
#                              [--arch <arch>] [--no-kvm] [--skip-kernel-test]

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_DIR=""
REPO_URL=""
ARCH="x86_64"
VM_MEM="2G"
VM_CPUS="2"
VM_PORT="10024"
USE_KVM=true
SKIP_KERNEL_TEST=false
IMAGE_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
IMAGE_DIR="${HOME}/.cache/warmshower-vm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)          REPO_DIR="$2"; shift 2 ;;
        --repo-dir=*)        REPO_DIR="${1#*=}"; shift ;;
        --repo-url)          REPO_URL="$2"; shift 2 ;;
        --repo-url=*)        REPO_URL="${1#*=}"; shift ;;
        --arch)              ARCH="$2"; shift 2 ;;
        --arch=*)            ARCH="${1#*=}"; shift ;;
        --no-kvm)            USE_KVM=false; shift ;;
        --skip-kernel-test)  SKIP_KERNEL_TEST=true; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Determine mode ────────────────────────────────────────────────────────────
if [ -n "$REPO_URL" ]; then
    MODE="hosted"
    REPO_SERVER="${REPO_URL}/${ARCH}"
elif [ -n "$REPO_DIR" ]; then
    MODE="local"
    REPO_SERVER="file:///mnt/wsrepo/${ARCH}"
    ARCH_DIR="${REPO_DIR}/${ARCH}"
else
    echo "ERROR: Specify either --repo-dir <dir> (local mode) or --repo-url <url> (hosted mode)."
    echo ""
    echo "Examples:"
    echo "  Local:   scripts/vm-test-phase6.sh --repo-dir /tmp/ws-repo"
    echo "  Hosted:  scripts/vm-test-phase6.sh --repo-url https://repo.warmshower.ai"
    exit 1
fi

echo "=== WarmShower OS — Phase 6 Bootstrap Validation ==="
echo "Mode:       ${MODE}"
[ "$MODE" = "local" ]  && echo "Repo dir:   ${REPO_DIR}" || echo "Repo URL:   ${REPO_URL}"
echo "Arch:       ${ARCH}"
echo "KVM:        ${USE_KVM}"
echo ""

# ── Preflight checks ──────────────────────────────────────────────────────────
echo "--- Preflight: checking host dependencies ---"
MISSING=0
for tool in qemu-system-x86_64 qemu-img ssh sshpass; do
    command -v "$tool" &>/dev/null \
        && echo "  OK: $tool" \
        || { echo "  MISSING: $tool"; MISSING=$((MISSING + 1)); }
done
[ "$MISSING" -gt 0 ] && {
    echo ""
    echo "Install on Arch: sudo pacman -S qemu-base openssh sshpass"
    echo "Install on Debian: sudo apt install qemu-system-x86 openssh-client sshpass"
    exit 1
}

if [ "$MODE" = "local" ]; then
    echo ""
    echo "--- Preflight: checking local repository ---"
    [ ! -d "$ARCH_DIR" ] && {
        echo "ERROR: Repository not found: ${ARCH_DIR}"
        echo "Run: scripts/bootstrap-repo.sh --repo-dir ${REPO_DIR}"
        exit 1
    }
    DB="${ARCH_DIR}/warmshower.db.tar.gz"
    [ ! -f "$DB" ] && {
        echo "ERROR: warmshower.db.tar.gz not found in ${ARCH_DIR}"
        echo "Run: wsync publish --repo-dir ${REPO_DIR}"
        exit 1
    }
    PKG_COUNT=$(find "$ARCH_DIR" -name "*.pkg.tar.zst" | wc -l)
    echo "  Packages found: ${PKG_COUNT}"
    [ "$PKG_COUNT" -lt 2 ] && {
        echo "ERROR: Fewer than 2 packages in repo. Build and publish bootstrap packages first."
        echo "  wsync build warmshower-keyring-pkg"
        echo "  wsync build warmshower-mirrorlist-pkg --sign"
        echo "  wsync publish --repo-dir ${REPO_DIR}"
        exit 1
    }
    # List what's in the repo
    find "$ARCH_DIR" -name "*.pkg.tar.zst" -exec basename {} \; | sed 's/^/  Found: /'
fi

if [ "$MODE" = "hosted" ]; then
    echo ""
    echo "--- Preflight: checking repo.warmshower.ai ---"
    curl -fsS --max-time 10 "${REPO_URL}/${ARCH}/warmshower.db" -o /dev/null \
        && echo "  OK: warmshower.db reachable at ${REPO_URL}/${ARCH}/" \
        || {
            echo "  FAIL: Cannot reach ${REPO_URL}/${ARCH}/warmshower.db"
            echo "        Complete WS-001 + WS-036 before running hosted mode."
            exit 1
        }
fi
echo ""

# ── Download/cache base image ─────────────────────────────────────────────────
mkdir -p "$IMAGE_DIR"
BASE_IMAGE="${IMAGE_DIR}/arch-cloudimg.qcow2"
if [ ! -f "$BASE_IMAGE" ]; then
    echo "--- Downloading Arch Linux cloud image (first run only) ---"
    curl -L --progress-bar -o "$BASE_IMAGE" "$IMAGE_URL"
fi

# ── Ephemeral disk ────────────────────────────────────────────────────────────
EPHEMERAL=$(mktemp "${IMAGE_DIR}/phase6-XXXXXX.qcow2")
qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$EPHEMERAL" 20G
echo "Ephemeral disk: ${EPHEMERAL}"

# ── cloud-init seed ───────────────────────────────────────────────────────────
SEED_DIR=$(mktemp -d)
SSH_KEY="${IMAGE_DIR}/phase6-id_ed25519"
[ ! -f "$SSH_KEY" ] && ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "ws-phase6" -q
SSH_PUB=$(cat "${SSH_KEY}.pub")

cat > "${SEED_DIR}/user-data" << CLOUDINIT
#cloud-config
users:
  - name: arch
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_PUB}
password: warmshower
chpasswd:
  expire: false
runcmd:
  - systemctl enable sshd --now
CLOUDINIT
printf 'instance-id: ws-phase6\nlocal-hostname: warmshower-phase6\n' > "${SEED_DIR}/meta-data"

SEED_ISO="${IMAGE_DIR}/phase6-seed.iso"
if command -v genisoimage &>/dev/null; then
    genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock \
        "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" 2>/dev/null
elif command -v cloud-localds &>/dev/null; then
    cloud-localds "$SEED_ISO" "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data"
else
    echo "ERROR: Need genisoimage or cloud-localds"; exit 1
fi

# ── Start VM ──────────────────────────────────────────────────────────────────
KVM_FLAGS=""
[ "$USE_KVM" = "true" ] && [ -w /dev/kvm ] && KVM_FLAGS="-enable-kvm -cpu host"

QEMU_ARGS=(
    qemu-system-x86_64
    $KVM_FLAGS
    -m "$VM_MEM" -smp "$VM_CPUS"
    -nographic -serial none -monitor none
    -drive "file=${EPHEMERAL},if=virtio,format=qcow2"
    -drive "file=${SEED_ISO},if=virtio,format=raw,readonly=on"
    -netdev "user,id=net0,hostfwd=tcp::${VM_PORT}-:22"
    -device "virtio-net-pci,netdev=net0"
)

# In local mode: share the repo directory into the VM via 9P
if [ "$MODE" = "local" ]; then
    QEMU_ARGS+=(
        -virtfs "local,path=${REPO_DIR},mount_tag=wsrepo,security_model=mapped-xattr,readonly=on"
    )
fi

echo "--- Starting VM (PID will be shown) ---"
"${QEMU_ARGS[@]}" &
VM_PID=$!
echo "  VM PID: ${VM_PID}"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
echo "--- Waiting for VM SSH (max 120s) ---"
for i in $(seq 1 24); do
    sleep 5
    sshpass -p warmshower ssh \
        -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -o UserKnownHostsFile=/dev/null \
        -p "$VM_PORT" arch@localhost "echo ready" &>/dev/null && break
    echo "  Waiting... ($((i*5))s)"
    if [ "$i" -eq 24 ]; then
        echo "ERROR: VM did not become reachable."
        kill "$VM_PID" 2>/dev/null; rm -f "$EPHEMERAL"; exit 1
    fi
done
echo "  VM is up."

# SSH helper — always uses key auth after first connection
vm_ssh() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$SSH_KEY" -p "$VM_PORT" arch@localhost "$@"; }

# ── Mount local repo (local mode only) ───────────────────────────────────────
if [ "$MODE" = "local" ]; then
    vm_ssh "sudo mkdir -p /mnt/wsrepo && sudo mount -t 9p -o trans=virtio wsrepo /mnt/wsrepo"
    echo "  Mounted /mnt/wsrepo inside VM"
fi
echo ""

# ── Test scaffolding ──────────────────────────────────────────────────────────
PASS=0; FAIL=0
declare -a RESULTS=()

record() {
    local name="$1" status="$2" detail="${3:-}"
    RESULTS+=("${status}|${name}|${detail}")
    if [ "$status" = "PASS" ]; then
        PASS=$((PASS + 1))
        echo "  [PASS] ${name}${detail:+ — ${detail}}"
    else
        FAIL=$((FAIL + 1))
        echo "  [FAIL] ${name}${detail:+ — ${detail}}"
    fi
}

run_test() {
    local name="$1"; shift
    if vm_ssh "$@" &>/dev/null 2>&1; then
        record "$name" "PASS"
    else
        record "$name" "FAIL"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 1: Install warmshower-keyring ==="
# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "local" ]; then
    KEYRING_FILE=$(find "$ARCH_DIR" -name "warmshower-keyring-*.pkg.tar.zst" | head -1)
    [ -z "$KEYRING_FILE" ] && { record "warmshower-keyring package present in local repo" "FAIL" "not found in ${ARCH_DIR}"; }
    if [ -n "$KEYRING_FILE" ]; then
        KEYRING_VM="/mnt/wsrepo/${ARCH}/$(basename "$KEYRING_FILE")"
        if vm_ssh "sudo pacman -U --noconfirm '${KEYRING_VM}'" 2>&1; then
            record "warmshower-keyring installs (local)" "PASS"
        else
            record "warmshower-keyring installs (local)" "FAIL"
        fi
    fi
else
    # hosted mode: install directly from URL (unsigned bootstrap — standard pacman pattern)
    KR_PKG=$(curl -fsS "${REPO_URL}/${ARCH}/warmshower.db" | tar -tz 2>/dev/null | \
              grep '^warmshower-keyring-' | head -1 | sed 's|/.*||')
    KR_URL="${REPO_URL}/${ARCH}/${KR_PKG}.pkg.tar.zst"
    run_test "warmshower-keyring installs from repo.warmshower.ai" \
        "sudo pacman -U --noconfirm '${KR_URL}'"
fi

# pacman-key populate (both modes)
if vm_ssh "sudo pacman-key --populate warmshower" 2>&1; then
    record "pacman-key --populate warmshower" "PASS"
else
    record "pacman-key --populate warmshower" "FAIL" \
        "warmshower.gpg may be placeholder key — complete WS-001+WS-002 for real keyring"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 2: Configure pacman.conf ==="
# ══════════════════════════════════════════════════════════════════════════════
vm_ssh "sudo bash -c 'cat >> /etc/pacman.conf << EOF

[warmshower]
Server = ${REPO_SERVER}
EOF'"

CACHYOS=$(vm_ssh "grep -ci cachyos /etc/pacman.conf 2>/dev/null || true")
[ "${CACHYOS:-0}" -eq 0 ] \
    && record "No [cachyos] repo in pacman.conf" "PASS" \
    || record "No [cachyos] repo in pacman.conf" "FAIL" "CachyOS found in pacman.conf"

WARMSHOWER=$(vm_ssh "grep -ci '^\[warmshower\]' /etc/pacman.conf 2>/dev/null || true")
[ "${WARMSHOWER:-0}" -ge 1 ] \
    && record "[warmshower] repo present in pacman.conf" "PASS" \
    || record "[warmshower] repo present in pacman.conf" "FAIL"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 3: pacman -Sy (repository sync) ==="
# ══════════════════════════════════════════════════════════════════════════════
if vm_ssh "sudo pacman -Sy 2>&1"; then
    record "pacman -Sy succeeds" "PASS"
    DB_SIZE=$(vm_ssh "stat -c%s /var/lib/pacman/sync/warmshower.db 2>/dev/null || echo 0")
    [ "${DB_SIZE:-0}" -gt 50 ] \
        && record "warmshower.db downloaded (${DB_SIZE} bytes)" "PASS" \
        || record "warmshower.db downloaded" "FAIL" "file missing or empty"
else
    record "pacman -Sy" "FAIL"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 4: Install warmshower-mirrorlist ==="
# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = "local" ]; then
    # SigLevel is Optional in local mode — the package may not be signed
    run_test "warmshower-mirrorlist installs" \
        "sudo pacman -S --noconfirm warmshower-mirrorlist"
else
    # In hosted mode the package is properly signed; install with default SigLevel
    run_test "warmshower-mirrorlist installs (signed)" \
        "sudo pacman -S --noconfirm warmshower-mirrorlist"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 5: Install warmshower-settings ==="
# ══════════════════════════════════════════════════════════════════════════════
if vm_ssh "sudo pacman -S --noconfirm warmshower-settings 2>&1"; then
    record "warmshower-settings installs" "PASS"
    # Verify no CachyOS service URLs in installed files
    CACHY_URLS=$(vm_ssh "grep -ri 'cachyos.org' /etc /usr/bin 2>/dev/null | wc -l")
    [ "${CACHY_URLS:-0}" -eq 0 ] \
        && record "No CachyOS service URLs in installed settings" "PASS" \
        || record "No CachyOS service URLs in installed settings" "FAIL" \
              "${CACHY_URLS} occurrence(s) found — WS-017 may be incomplete"
else
    record "warmshower-settings installs" "FAIL"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 6: Install warmshower-hooks ==="
# ══════════════════════════════════════════════════════════════════════════════
if vm_ssh "sudo pacman -S --noconfirm warmshower-hooks 2>&1"; then
    record "warmshower-hooks installs" "PASS"
    HOOK_COUNT=$(vm_ssh "ls /usr/share/libalpm/hooks/warmshower-* 2>/dev/null | wc -l")
    [ "${HOOK_COUNT:-0}" -ge 1 ] \
        && record "warmshower- prefixed hooks installed to /usr/share/libalpm/hooks/" "PASS" \
        || record "warmshower- prefixed hooks in /usr/share/libalpm/hooks/" "FAIL"
    CACHYOS_HOOKS=$(vm_ssh "ls /usr/share/libalpm/hooks/cachyos-* 2>/dev/null | wc -l || echo 0")
    [ "${CACHYOS_HOOKS:-0}" -eq 0 ] \
        && record "No cachyos- prefixed hooks installed" "PASS" \
        || record "No cachyos- prefixed hooks installed" "FAIL"
else
    record "warmshower-hooks installs" "FAIL"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 7: Install mkinitcpio and rebuild initramfs ==="
# ══════════════════════════════════════════════════════════════════════════════
# The VM already has a kernel; test that mkinitcpio (WarmShower variant) builds an initramfs.
if vm_ssh "sudo pacman -S --noconfirm mkinitcpio 2>&1"; then
    record "mkinitcpio (WarmShower variant) installs" "PASS"
    if vm_ssh "sudo mkinitcpio -P 2>&1"; then
        record "mkinitcpio -P builds initramfs" "PASS"
    else
        record "mkinitcpio -P builds initramfs" "FAIL"
    fi
else
    record "mkinitcpio installs" "FAIL" "ensure mkinitcpio is built and published to local repo"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 8: linux-warmshower kernel (if present in repo) ==="
# ══════════════════════════════════════════════════════════════════════════════
if [ "$SKIP_KERNEL_TEST" = "true" ]; then
    echo "  SKIPPED (--skip-kernel-test)"
else
    KERNEL_IN_REPO=false
    if [ "$MODE" = "local" ]; then
        find "$ARCH_DIR" -name "linux-warmshower-[0-9]*.pkg.tar.zst" | grep -q . \
            && KERNEL_IN_REPO=true
    else
        vm_ssh "pacman -Si linux-warmshower &>/dev/null" && KERNEL_IN_REPO=true || true
    fi

    if [ "$KERNEL_IN_REPO" = "true" ]; then
        if vm_ssh "sudo pacman -S --noconfirm linux-warmshower linux-warmshower-headers 2>&1"; then
            record "linux-warmshower + headers install" "PASS"
            VMLINUZ=$(vm_ssh "ls /boot/vmlinuz-linux-warmshower 2>/dev/null && echo yes || echo no")
            [ "$VMLINUZ" = "yes" ] \
                && record "vmlinuz-linux-warmshower present in /boot" "PASS" \
                || record "vmlinuz-linux-warmshower present in /boot" "FAIL"
            INITRD=$(vm_ssh "ls /boot/initramfs-linux-warmshower.img 2>/dev/null && echo yes || echo no")
            [ "$INITRD" = "yes" ] \
                && record "initramfs-linux-warmshower.img present (hook triggered)" "PASS" \
                || record "initramfs-linux-warmshower.img generated" "FAIL" \
                    "warmshower-hooks may not have triggered mkinitcpio"
        else
            record "linux-warmshower installs" "FAIL"
        fi
    else
        echo "  INFO: linux-warmshower not in repo — kernel test skipped."
        echo "        Build takes 30-90 min; publish it then re-run with kernel in repo."
        echo "        To skip permanently: --skip-kernel-test"
        record "linux-warmshower in repo" "FAIL" \
            "not published yet — multi-hour build; run CI workflow or local build"
    fi
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 9: pacman -Syu (full upgrade / update cycle) ==="
# ══════════════════════════════════════════════════════════════════════════════
if vm_ssh "sudo pacman -Syu --noconfirm 2>&1"; then
    record "pacman -Syu succeeds" "PASS"
else
    record "pacman -Syu" "FAIL"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 10: Package signature verification (pacman -Qkk) ==="
# ══════════════════════════════════════════════════════════════════════════════
WS_PKGS=$(vm_ssh "pacman -Q | awk '\$1 ~ /^warmshower-/ { print \$1 }' | tr '\n' ' '")
if [ -n "$WS_PKGS" ]; then
    # shellcheck disable=SC2086
    if vm_ssh "sudo pacman -Qkk $WS_PKGS 2>&1"; then
        record "pacman -Qkk passes for all warmshower-* packages" "PASS"
    else
        record "pacman -Qkk warmshower-* packages" "FAIL" \
            "integrity check failed — may be expected with placeholder signing key"
    fi
else
    record "warmshower-* packages installed for -Qkk check" "FAIL" "no warmshower packages found"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 11: Repository database consistency (pacman -Dk) ==="
# ══════════════════════════════════════════════════════════════════════════════
if vm_ssh "sudo pacman -Dk 2>&1"; then
    record "pacman -Dk (database consistency)" "PASS"
else
    record "pacman -Dk" "FAIL"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
echo "=== Check 12: Branding audit (bootstrap packages only) ==="
# ══════════════════════════════════════════════════════════════════════════════

# os-release
OS_NAME=$(vm_ssh "grep '^NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"'")
echo "  /etc/os-release NAME = '${OS_NAME}'"
echo "$OS_NAME" | grep -qi "warmshower" \
    && record "/etc/os-release contains WarmShower" "PASS" \
    || record "/etc/os-release contains WarmShower" "FAIL" "NAME='${OS_NAME}'"
echo "$OS_NAME" | grep -qi "cachyos\|cachy" \
    && record "/etc/os-release contains no CachyOS name" "FAIL" "NAME='${OS_NAME}'" \
    || record "/etc/os-release contains no CachyOS name" "PASS"

# CachyOS strings in user-visible paths (installed bootstrap files only)
CACHY_HITS=$(vm_ssh "grep -ril 'cachyos' \
    /etc/pacman.d \
    /usr/share/libalpm/hooks \
    /usr/share/libalpm/scripts \
    /usr/bin/paste-warmshower \
    /etc/debuginfod \
    2>/dev/null | tr '\n' ' '" || echo "")
if [ -z "${CACHY_HITS// }" ]; then
    record "No CachyOS strings in bootstrap-installed files" "PASS"
else
    record "No CachyOS strings in bootstrap-installed files" "FAIL" \
        "found in: ${CACHY_HITS}"
fi

# Mirrorlist check
MIRROR_CACHY=$(vm_ssh \
    "grep -i cachyos /etc/pacman.d/warmshower-mirrorlist 2>/dev/null | wc -l || echo 0")
[ "${MIRROR_CACHY:-0}" -eq 0 ] \
    && record "warmshower-mirrorlist contains no CachyOS mirrors" "PASS" \
    || record "warmshower-mirrorlist contains no CachyOS mirrors" "FAIL"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Cleanup
# ══════════════════════════════════════════════════════════════════════════════
echo "--- Shutting down VM ---"
vm_ssh "sudo poweroff" 2>/dev/null || true
wait "$VM_PID" 2>/dev/null || true
rm -f "$EPHEMERAL"
rm -rf "$SEED_DIR"
echo "  VM stopped. Ephemeral disk removed."
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Results summary
# ══════════════════════════════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════"
echo " WarmShower OS Phase 6 — Validation Results"
echo "════════════════════════════════════════════════════════"
echo " Mode:    ${MODE}"
echo " Passed:  ${PASS}"
echo " Failed:  ${FAIL}"
echo ""
for entry in "${RESULTS[@]}"; do
    status="${entry%%|*}"
    rest="${entry#*|}"
    name="${rest%%|*}"
    detail="${rest#*|}"
    marker="✓"
    [ "$status" = "FAIL" ] && marker="✗"
    printf " %s  %s\n" "$marker" "$name"
    [ -n "$detail" ] && [ "$detail" != "$name" ] && printf "     → %s\n" "$detail"
done
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo " RESULT: ALL CHECKS PASSED"
    echo ""
    echo " Phase 6 bootstrap validation is complete."
    if [ "$MODE" = "local" ]; then
        echo ""
        echo " Next steps to reach Mode B (hosted) sign-off:"
        echo "   1. Complete WS-001 — generate GPG key on air-gapped machine"
        echo "   2. Complete WS-002 — update warmshower-keyring with real key"
        echo "   3. Complete WS-036 — stand up Cloudflare R2 + repo.warmshower.ai"
        echo "   4. Trigger publish-keyring.yml and publish-mirrorlist.yml in GitHub Actions"
        echo "   5. Run: scripts/vm-test-phase6.sh --repo-url https://repo.warmshower.ai"
    else
        echo ""
        echo " Phase 6 hosted validation is complete."
        echo " Phase 7 (mass package migration) may begin after engineering review."
    fi
    exit 0
else
    echo " RESULT: ${FAIL} CHECK(S) FAILED"
    echo ""
    echo " Review failures above before proceeding to Phase 7."
    exit 1
fi
