#!/usr/bin/env bash
# Rebuild Proxmox OVMF firmware from source with a custom boot logo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/lib"

BUILD_ROOT="${BUILD_ROOT:-/var/lib/pve-custom-boot-logo/build}"
EDK2_WORK_DIR="${BUILD_ROOT}/edk2-work"
PVE_FIRMWARE_DIR="/usr/share/pve-edk2-firmware"
BACKUP_DIR="/var/lib/pve-custom-boot-logo/backups"
# Overridable so CI / containers can clone over https (git:// is often blocked).
GIT_URL="${GIT_URL:-git://git.proxmox.com/git/pve-edk2-firmware.git}"

# Only rebuild x64 OVMF CODE images (sufficient for typical Proxmox VMs).
OVMF_ONLY="${OVMF_ONLY:-1}"

# Skip apt dependency installation. Set to 1 when build deps are already present
# (e.g. inside the docker/Dockerfile build-env image used by CI).
SKIP_DEPS="${SKIP_DEPS:-0}"

# Shallow-clone depth for the firmware repo and its (many) submodules. Set to 1
# to fetch only the pinned tip — dramatically faster, no history. Empty = full.
GIT_DEPTH="${GIT_DEPTH:-}"

# Parallel submodule fetch jobs. edk2 pulls dozens of nested submodules
# (openssl, libspdm, mbedtls, ...); cloning them in parallel is the biggest win.
GIT_JOBS="${GIT_JOBS:-$(nproc 2>/dev/null || echo 4)}"

# Packages that must never be removed by our apt install on a live Proxmox node.
PVE_PROTECTED_PKGS=(
    proxmox-ve
    pve-qemu-kvm
    qemu-server
    pve-manager
)

usage() {
    cat <<'EOF'
Rebuild pve-edk2-firmware with a custom Logo.bmp and install the results.

Usage:
  build-firmware.sh <logo-image>

Environment:
  BUILD_ROOT   Build working directory (default: /var/lib/pve-custom-boot-logo/build)
  OVMF_ONLY    1 = build only x64 OVMF CODE images (default, Proxmox-safe)
               0 = full package build (make deb, NOT recommended on live PVE node)

By default only OVMF_CODE_4M.fd and OVMF_CODE_4M.secboot.fd are installed.
VARS files (NVRAM) are not overwritten.

IMPORTANT: Never install gcc-multilib or qemu-utils on a live Proxmox host —
they can conflict with proxmox-ve / pve-qemu-kvm.
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

apt_would_remove_proxmox() {
    local simulate="$1"
    local pkg
    for pkg in "${PVE_PROTECTED_PKGS[@]}"; do
        if echo "${simulate}" | grep -A30 "packages will be REMOVED" | grep -qi "${pkg}"; then
            return 0
        fi
    done
    return 1
}

safe_apt_install() {
    local packages=("$@")
    [[ "${#packages[@]}" -gt 0 ]] || return 0

    local simulate
    simulate="$(apt-get install --simulate -y "${packages[@]}" 2>&1)" || true

    if apt_would_remove_proxmox "${simulate}"; then
        log "apt simulate output:"
        echo "${simulate}" | grep -E '^(The following|  )' || true
        die "Refusing to install packages that would remove Proxmox components."
    fi

    apt-get install -y "${packages[@]}"
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
    if [[ "${SKIP_DEPS}" == "1" ]]; then
        log "SKIP_DEPS=1: assuming build dependencies are preinstalled."
        command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found (install qemu-utils in the build image)."
        return 0
    fi

    log "Installing Proxmox-safe build dependencies..."

    # Safe on a live Proxmox node:
    # - gcc-i686-linux-gnu instead of gcc-multilib (multilib removes proxmox-ve)
    # - no qemu-utils (conflicts with pve-qemu-kvm; qemu-img already provided)
    # - no python3-virt-firmware (only needed for VARS enrollment, which we skip)
    local packages=(
        git build-essential bc debhelper dpkg-dev dosfstools
        acpica-tools nasm uuid-dev mtools xorriso
        python3 python3-pexpect python3-pil
        gcc-i686-linux-gnu
    )

    if [[ "${OVMF_ONLY}" != "1" ]]; then
        packages+=(
            gcc-aarch64-linux-gnu
            gcc-riscv64-linux-gnu
            devscripts
            python3-virt-firmware
        )
        if ! dpkg -s pve-qemu-kvm >/dev/null 2>&1; then
            packages+=(qemu-utils)
        fi
    fi

    apt-get update -qq
    safe_apt_install "${packages[@]}"

    if ! command -v qemu-img >/dev/null 2>&1; then
        die "qemu-img not found. Install pve-qemu-kvm before building."
    fi
}

setup_edk2_toolchain() {
    # Ia32X64 firmware needs a 32-bit compiler on amd64 hosts.
    export EDK2_TOOLCHAIN="${EDK2_TOOLCHAIN:-GCC5}"
    export GCC5_IA32_PREFIX="${GCC5_IA32_PREFIX:-i686-linux-gnu-}"
    export DEB_BUILD_ARCH="${DEB_BUILD_ARCH:-amd64}"
    export DEB_HOST_ARCH="${DEB_HOST_ARCH:-amd64}"
    log "Using IA32 cross prefix: ${GCC5_IA32_PREFIX}"
}

prepare_edk2_worktree() {
    local repo="${BUILD_ROOT}/pve-edk2-firmware"
    local logo_bmp="$1"

    [[ -f "${repo}/edk2/edksetup.sh" ]] || die "edk2 submodule missing. Run: git submodule update --init --recursive"

    log "Preparing edk2 build tree at ${EDK2_WORK_DIR}..."
    rm -rf "${EDK2_WORK_DIR}"
    cp -a "${repo}/edk2/." "${EDK2_WORK_DIR}/"
    cp -a "${repo}/debian" "${EDK2_WORK_DIR}/debian"
    cp "${logo_bmp}" "${EDK2_WORK_DIR}/debian/Logo.bmp"
}

build_ovmf_code_only() {
    setup_edk2_toolchain
    cd "${EDK2_WORK_DIR}"

    # Targets live in debian/rules, not the top-level Makefile (which only builds .deb).
    log "Building OVMF CODE images (make -f debian/rules)..."
    # Build sequentially: both targets share Build/Ovmf3264 and race if run in parallel.
    make -f debian/rules debian/setup-build-stamp
    make -f debian/rules debian/ovmf-install/OVMF_CODE_4M.fd
    make -f debian/rules debian/ovmf-install/OVMF_CODE_4M.secboot.fd
}

install_built_code_images() {
    local install_dir="${EDK2_WORK_DIR}/debian/ovmf-install"
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
    logo_image="$(readlink -f "${logo_image}")"

    if [[ "${OVMF_ONLY}" != "1" ]]; then
        log "WARNING: OVMF_ONLY=0 can break a live Proxmox node. Prefer OVMF_ONLY=1."
    fi

    command -v python3 >/dev/null || die "python3 is required"
    python3 -c "from PIL import Image" 2>/dev/null || safe_apt_install python3-pil

    mkdir -p "${BUILD_ROOT}"

    local just_cloned=0
    if [[ ! -d "${BUILD_ROOT}/pve-edk2-firmware/.git" ]]; then
        log "Cloning ${GIT_URL}${GIT_DEPTH:+ (shallow, depth=${GIT_DEPTH})}..."
        git clone ${GIT_DEPTH:+--depth "${GIT_DEPTH}"} \
            "${GIT_URL}" "${BUILD_ROOT}/pve-edk2-firmware"
        just_cloned=1
    fi

    install_build_deps

    cd "${BUILD_ROOT}/pve-edk2-firmware"
    # A fresh clone is already at the tip; only refresh an existing full checkout
    # (refreshing a shallow clone would defeat the point).
    if [[ "${just_cloned}" -eq 0 && -z "${GIT_DEPTH}" ]]; then
        git fetch --all --tags
        git pull --ff-only || true
    fi

    fix_subhook_submodule

    log "Updating submodules (${GIT_JOBS} parallel jobs${GIT_DEPTH:+, shallow depth=${GIT_DEPTH}})..."
    git submodule sync --recursive
    git submodule update --init --recursive --jobs "${GIT_JOBS}" ${GIT_DEPTH:+--depth "${GIT_DEPTH}"}

    local logo_bmp="${BUILD_ROOT}/Logo.bmp"
    python3 "${LIB_DIR}/prepare_logo.py" "${logo_image}" "${logo_bmp}"

    cp "${logo_bmp}" "${BUILD_ROOT}/pve-edk2-firmware/debian/Logo.bmp"
    log "Installed logo at debian/Logo.bmp"
    prepare_edk2_worktree "${logo_bmp}"

    if [[ "${OVMF_ONLY}" == "1" ]]; then
        build_ovmf_code_only
        install_built_code_images
    else
        log "Building full pve-edk2-firmware package (OVMF_ONLY=0)..."
        setup_edk2_toolchain
        cd "${BUILD_ROOT}/pve-edk2-firmware"
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
