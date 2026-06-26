#!/usr/bin/env bash
# Rebuild Proxmox OVMF firmware from source with a custom boot logo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/lib"

BUILD_ROOT="${BUILD_ROOT:-/var/lib/pve-custom-boot-logo/build}"
PVE_FIRMWARE_DIR="/usr/share/pve-edk2-firmware"
BACKUP_DIR="/var/lib/pve-custom-boot-logo/backups"
GIT_URL="git://git.proxmox.com/git/pve-edk2-firmware.git"

# Only rebuild x64 OVMF CODE images (sufficient for typical Proxmox VMs).
OVMF_ONLY="${OVMF_ONLY:-1}"

usage() {
    cat <<'EOF'
Rebuild pve-edk2-firmware with a custom Logo.bmp and install the results.

Usage:
  build-firmware.sh <logo-image>

Environment:
  BUILD_ROOT   Build working directory (default: /var/lib/pve-custom-boot-logo/build)
  OVMF_ONLY    1 = build only x64 OVMF CODE images (default, fast)
               0 = full package build (make deb, all architectures)

By default only OVMF_CODE_4M.fd and OVMF_CODE_4M.secboot.fd are installed.
VARS files (NVRAM) are not overwritten.
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

fix_subhook_submodule() {
    local gitmodules="${BUILD_ROOT}/pve-edk2-firmware/edk2/.gitmodules"
    [[ -f "${gitmodules}" ]] || return 0

    if grep -q 'github.com/Zeex/subhook' "${gitmodules}"; then
        log "Patching broken subhook submodule URL..."
        sed -i 's|https://github.com/Zeex/subhook.git|https://github.com/tianocore/edk2-subhook.git|g' \
            "${gitmodules}"
    fi
}

install_build_deps() {
    log "Installing build dependencies (from pve-edk2-firmware debian/control)..."

    # Minimal set matching upstream Build-Depends — no QEMU *-dev packages.
    local packages=(
        git build-essential bc debhelper dosfstools
        iasl mtools nasm uuid-dev xorriso
        python3 python3-pexpect python3-virt-firmware
        qemu-utils python3-pil
    )

    if [[ "${OVMF_ONLY}" == "1" ]]; then
        # OvmfPkgIa32X64 needs 32-bit compiler support on amd64.
        packages+=(gcc-multilib)
    else
        packages+=(
            gcc-aarch64-linux-gnu
            gcc-riscv64-linux-gnu
            gcc-multilib
            devscripts
        )
    fi

    apt-get update -qq
    if ! apt-get install -y "${packages[@]}"; then
        die "Failed to install build dependencies. See apt output above."
    fi

    if ! dpkg -s pve-qemu-kvm >/dev/null 2>&1; then
        log "pve-qemu-kvm not installed; installing qemu alternatives..."
        apt-get install -y qemu-system-x86 qemu-system-arm || true
    fi
}

install_built_code_images() {
    local install_dir="${BUILD_ROOT}/pve-edk2-firmware/debian/ovmf-install"
    [[ -d "${install_dir}" ]] || die "Build output not found: ${install_dir}"

    mkdir -p "${BACKUP_DIR}" "${PVE_FIRMWARE_DIR}"

    local code_files=(
        OVMF_CODE_4M.fd
        OVMF_CODE_4M.secboot.fd
    )

    local installed=0
    for name in "${code_files[@]}"; do
        local src="${install_dir}/${name}"
        local dst="${PVE_FIRMWARE_DIR}/${name}"
        [[ -f "${src}" ]] || {
            log "Skip missing build artifact: ${name}"
            continue
        }
        if [[ ! -f "${BACKUP_DIR}/${name}" && -f "${dst}" ]]; then
            cp -a "${dst}" "${BACKUP_DIR}/${name}"
            log "Backup: ${BACKUP_DIR}/${name}"
        fi
        cp -a "${src}" "${dst}"
        log "Installed ${dst}"
        installed=$((installed + 1))
    done

    [[ "${installed}" -gt 0 ]] || die "No OVMF CODE images were installed"
}

main() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Run as root on the Proxmox host."
    fi

    local logo_image="${1:-}"
    if [[ -z "${logo_image}" || "${logo_image}" == "-h" || "${logo_image}" == "--help" ]]; then
        usage
        exit 0
    fi
    [[ -f "${logo_image}" ]] || die "Logo image not found: ${logo_image}"

    command -v python3 >/dev/null || die "python3 is required"
    python3 -c "from PIL import Image" 2>/dev/null || apt-get install -y python3-pil

    mkdir -p "${BUILD_ROOT}"

    if [[ ! -d "${BUILD_ROOT}/pve-edk2-firmware/.git" ]]; then
        log "Cloning ${GIT_URL}..."
        git clone "${GIT_URL}" "${BUILD_ROOT}/pve-edk2-firmware"
    fi

    install_build_deps

    cd "${BUILD_ROOT}/pve-edk2-firmware"
    git fetch --all --tags
    git pull --ff-only || true

    fix_subhook_submodule

    log "Updating submodules (this may take a few minutes)..."
    git submodule sync --recursive
    git submodule update --init --recursive

    local logo_bmp="${BUILD_ROOT}/Logo.bmp"
    python3 "${LIB_DIR}/prepare_logo.py" "$(readlink -f "${logo_image}")" "${logo_bmp}"

    # debian/rules: cp debian/Logo.bmp MdeModulePkg/Logo/Logo.bmp
    cp "${logo_bmp}" "${BUILD_ROOT}/pve-edk2-firmware/debian/Logo.bmp"
    log "Installed logo at debian/Logo.bmp"

    if [[ "${OVMF_ONLY}" == "1" ]]; then
        log "Building x64 OVMF only (OVMF_ONLY=1)..."
        make build-ovmf
        install_built_code_images
    else
        log "Building full pve-edk2-firmware package (OVMF_ONLY=0)..."
        make clean 2>/dev/null || true
        make -j"$(nproc)"
        make deb
        local deb_dir="${BUILD_ROOT}/pve-edk2-firmware"
        mapfile -t debs < <(find "${deb_dir}" -maxdepth 1 -name 'pve-edk2-firmware_*.deb' | sort)
        [[ "${#debs[@]}" -gt 0 ]] || die "No .deb packages were produced"
        log "Installing ${debs[-1]}..."
        dpkg -i "${debs[-1]}" || apt-get install -f -y
    fi

    if [[ -d "${PVE_FIRMWARE_DIR}" ]]; then
        log "Firmware directory: ${PVE_FIRMWARE_DIR}"
        ls -1 "${PVE_FIRMWARE_DIR}"/OVMF_CODE*.fd 2>/dev/null || true
    fi

    log "Build complete. Stop/start VMs to see the new boot logo."
    log "Restore originals: sudo ./scripts/apply-custom-boot-logo.sh --restore"
}

main "$@"