#!/usr/bin/env bash
# Rebuild Proxmox OVMF firmware from source with a custom boot logo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/lib"

BUILD_ROOT="${BUILD_ROOT:-/var/lib/pve-custom-boot-logo/build}"
PVE_FIRMWARE_DIR="/usr/share/pve-edk2-firmware"
GIT_URL="git://git.proxmox.com/git/pve-edk2-firmware.git"

usage() {
    cat <<'EOF'
Rebuild pve-edk2-firmware with a custom Logo.bmp and install the results.

Usage:
  build-firmware.sh <logo-image>

Environment:
  BUILD_ROOT   Build working directory (default: /var/lib/pve-custom-boot-logo/build)

This is slower than quick patch but supports arbitrary logo dimensions.
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
    log "Installing build dependencies..."
    apt-get update -qq
    apt-get install -y \
        git devscripts python3-pil \
        pve-qemu-kvm gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu \
        libacl1-dev libaio-dev libattr1-dev libcap-ng-dev \
        libcurl4-gnutls-dev libepoxy-dev libfdt-dev libgbm-dev \
        libgnutls28-dev libiscsi-dev libjpeg-dev libnuma-dev \
        libpci-dev libpixman-1-dev libproxmox-backup-qemu0-dev \
        librbd-dev libsdl1.2-dev libseccomp-dev libslirp-dev \
        libspice-protocol-dev libspice-server-dev libsystemd-dev \
        liburing-dev libusb-1.0-0-dev libusbredirparser-dev \
        libvirglrenderer-dev meson python3-sphinx python3-sphinx-rtd-theme \
        quilt xfslibs-dev
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

    install_build_deps
    mkdir -p "${BUILD_ROOT}"

    if [[ ! -d "${BUILD_ROOT}/pve-edk2-firmware/.git" ]]; then
        log "Cloning ${GIT_URL}..."
        git clone "${GIT_URL}" "${BUILD_ROOT}/pve-edk2-firmware"
    fi

    cd "${BUILD_ROOT}/pve-edk2-firmware"
    git fetch --all --tags
    git pull --ff-only || true

    fix_subhook_submodule

    log "Updating submodules..."
    git submodule sync --recursive
    git submodule update --init --recursive

    if [[ ! -f debian/control ]]; then
        yes | mk-build-deps --install ./debian/control 2>/dev/null || true
    fi

    local logo_bmp="${BUILD_ROOT}/Logo.bmp"
    python3 "${LIB_DIR}/prepare_logo.py" "$(readlink -f "${logo_image}")" "${logo_bmp}"

    local logo_targets=(
        "edk2/MdeModulePkg/Logo/Logo.bmp"
        "OvmfPkg/Logo.bmp"
    )
    for target in "${logo_targets[@]}"; do
        if [[ -f "${BUILD_ROOT}/pve-edk2-firmware/${target}" || -d "$(dirname "${BUILD_ROOT}/pve-edk2-firmware/${target}")" ]]; then
            cp "${logo_bmp}" "${BUILD_ROOT}/pve-edk2-firmware/${target}"
            log "Installed logo at ${target}"
        fi
    done
    cp "${logo_bmp}" "${BUILD_ROOT}/pve-edk2-firmware/debian/Logo.bmp" 2>/dev/null || \
        cp "${logo_bmp}" "${BUILD_ROOT}/pve-edk2-firmware/Logo.bmp"

    log "Building firmware (this may take a while)..."
    make clean 2>/dev/null || true
    make -j"$(nproc)"

    log "Building Debian packages..."
    make deb

    local deb_dir="${BUILD_ROOT}/pve-edk2-firmware"
    mapfile -t debs < <(find "${deb_dir}" -maxdepth 1 -name 'pve-edk2-firmware_*.deb' | sort)
    [[ "${#debs[@]}" -gt 0 ]] || die "No .deb packages were produced"

    log "Installing ${debs[-1]}..."
    dpkg -i "${debs[-1]}"

    if [[ -d "${PVE_FIRMWARE_DIR}" ]]; then
        log "Installed firmware is available under ${PVE_FIRMWARE_DIR}"
        ls -1 "${PVE_FIRMWARE_DIR}"/*.fd 2>/dev/null || true
    fi

    log "Build complete. Restart VMs to see the new boot logo."
}

main "$@"