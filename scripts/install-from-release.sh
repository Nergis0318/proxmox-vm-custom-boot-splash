#!/usr/bin/env bash
# Install pre-built OVMF CODE firmware from this repo's GitHub Releases.
#
# This is the fast alternative to the on-host source build (apply-custom-boot-logo.sh
# --build, 10-30 min): CI already builds the .fd images and attaches them to each
# Release, so the host only downloads, verifies, and copies them into place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_REPO="Nergis0318/proxmox-vm-custom-boot-splash"
PVE_FIRMWARE_DIR="/usr/share/pve-edk2-firmware"
KVM_FIRMWARE_DIR="/usr/share/kvm"
BACKUP_DIR="/var/lib/pve-custom-boot-logo/backups"

# Temp download dir, removed by the EXIT trap. Global (not a main() local) so the
# trap can still reference it after main returns under `set -u`.
WORK_DIR=""

usage() {
    cat <<'EOF'
Install Proxmox custom-logo firmware from a GitHub Release

Usage:
  install-from-release.sh [options]

Downloads the pre-built OVMF CODE firmware images attached to a GitHub Release
and installs them onto this Proxmox host. Only firmware files that already exist
on the host are overwritten (after a one-time backup).

Options:
  --version TAG        Install a specific Release tag (default: latest)
  --repo OWNER/NAME    Source repo. Default: this checkout's git origin (so a
                       clone of your fork targets your own Releases), else
                       Nergis0318/proxmox-vm-custom-boot-splash. Env GITHUB_REPO
                       is honoured between --repo and git origin.
  --firmware-dir DIR   Firmware directory (default: auto-detect)
  --dry-run            Download + verify only; do not install
  --no-verify          Skip SHA256 checksum verification (escape hatch)
  -h, --help           Show this help

Examples:
  sudo ./install-from-release.sh
  sudo ./install-from-release.sh --version v1.2.0
  sudo ./install-from-release.sh --dry-run

Notes:
  - Run on the Proxmox host as root (not required for --dry-run).
  - Stop/start VMs afterwards to display the new boot logo.
  - Restore originals with: sudo ./apply-custom-boot-logo.sh --restore
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root on the Proxmox host."
    fi
}

# download <url> <dest> — fetch a URL to a file. Prefers curl, falls back to wget.
download() {
    local url="$1"
    local dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${url}" -o "${dest}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${dest}" "${url}"
    else
        die "Need curl or wget to download releases. Install one of them."
    fi
}

# Derive "owner/repo" from this checkout's origin remote so a clone of your fork
# downloads from your fork's Releases without needing --repo. Prints nothing and
# returns non-zero when it cannot be determined.
detect_repo_from_git() {
    command -v git >/dev/null 2>&1 || return 1
    local url
    url="$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null)" || return 1
    [[ -n "${url}" ]] || return 1
    url="${url%.git}"
    case "${url}" in
        *github.com*) ;;
        *) return 1 ;;
    esac
    # Strip everything up to and including github.com, then a leading : or /,
    # which normalises both https://github.com/owner/repo and git@github.com:owner/repo.
    url="${url#*github.com}"
    url="${url#[:/]}"
    [[ "${url}" == */* ]] || return 1
    printf '%s\n' "${url}"
}

detect_firmware_dir() {
    if [[ -d "${PVE_FIRMWARE_DIR}" ]]; then
        echo "${PVE_FIRMWARE_DIR}"
        return
    fi
    if [[ -d "${KVM_FIRMWARE_DIR}" ]]; then
        echo "${KVM_FIRMWARE_DIR}"
        return
    fi
    die "Could not find OVMF firmware directory. Use --firmware-dir."
}

main() {
    local version=""
    local repo=""
    local firmware_dir=""
    local dry_run="0"
    local verify="1"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                version="$2"
                shift 2
                ;;
            --repo)
                repo="$2"
                shift 2
                ;;
            --firmware-dir)
                firmware_dir="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="1"
                shift
                ;;
            --no-verify)
                verify="0"
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                die "Unexpected argument: $1"
                ;;
        esac
    done

    # Repo resolution order: --repo > $GITHUB_REPO > this checkout's git origin
    # (so a clone of your fork targets your fork's Releases) > built-in default.
    if [[ -z "${repo}" ]]; then
        repo="${GITHUB_REPO:-}"
    fi
    if [[ -z "${repo}" ]]; then
        repo="$(detect_repo_from_git || true)"
    fi
    if [[ -z "${repo}" ]]; then
        repo="${DEFAULT_REPO}"
    fi

    # Installing writes to the firmware dir and so needs root; --dry-run only
    # downloads to a temp dir, which lets it run off-host for testing.
    [[ "${dry_run}" == "1" ]] || require_root

    local base_url
    if [[ -n "${version}" ]]; then
        base_url="https://github.com/${repo}/releases/download/${version}"
    else
        base_url="https://github.com/${repo}/releases/latest/download"
    fi

    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "${WORK_DIR}"' EXIT

    log "Repo:    ${repo}"
    log "Release: ${version:-latest}"

    # Discover the asset list from SHA256SUMS rather than hard-coding filenames,
    # so this adapts if the Release's CODE file set ever changes.
    log "Downloading SHA256SUMS..."
    download "${base_url}/SHA256SUMS" "${WORK_DIR}/SHA256SUMS" \
        || die "Could not download SHA256SUMS from the Release (check --version/--repo)."

    # Keep only the .fd lines and parse their filenames (lines look like
    # "<hash>  ./OVMF_CODE_4M.fd"; strip a leading ./ from the path).
    grep -E '\.fd$' "${WORK_DIR}/SHA256SUMS" > "${WORK_DIR}/SHA256SUMS.filtered" || true
    local assets=()
    mapfile -t assets < <(awk '{print $2}' "${WORK_DIR}/SHA256SUMS.filtered" | sed 's#^\./##')
    [[ "${#assets[@]}" -gt 0 ]] || die "No .fd files listed in SHA256SUMS."

    for name in "${assets[@]}"; do
        log "Downloading ${name}..."
        download "${base_url}/${name}" "${WORK_DIR}/${name}" \
            || die "Failed to download ${name} from the Release."
    done

    if [[ "${verify}" == "1" ]]; then
        log "Verifying checksums..."
        ( cd "${WORK_DIR}" && sha256sum -c SHA256SUMS.filtered ) \
            || die "Checksum verification failed. Aborting (use --no-verify to override)."
    else
        log "Skipping checksum verification (--no-verify)."
    fi

    local target_dir="${firmware_dir}"
    [[ -n "${target_dir}" ]] || target_dir="$(detect_firmware_dir)"
    log "Firmware dir: ${target_dir}"

    if [[ "${dry_run}" == "1" ]]; then
        log "[dry-run] Verified ${#assets[@]} file(s). Would install into ${target_dir}:"
        for name in "${assets[@]}"; do
            if [[ -f "${target_dir}/${name}" ]]; then
                log "[dry-run]   install ${name} -> ${target_dir}/${name}"
            else
                log "[dry-run]   skip ${name} (not present on host)"
            fi
        done
        log "Dry run complete."
        exit 0
    fi

    mkdir -p "${BACKUP_DIR}"
    local installed=0
    local skipped=0
    for name in "${assets[@]}"; do
        local host_file="${target_dir}/${name}"
        if [[ ! -f "${host_file}" ]]; then
            log "Skip ${name}: not installed on this host"
            skipped=$((skipped + 1))
            continue
        fi
        # Back up only on the first install so the pristine original is preserved
        # (and not overwritten by an already-patched copy on re-runs).
        if [[ ! -f "${BACKUP_DIR}/${name}" ]]; then
            cp -a "${host_file}" "${BACKUP_DIR}/${name}"
            log "Backup saved: ${BACKUP_DIR}/${name}"
        fi
        cp -a "${WORK_DIR}/${name}" "${host_file}"
        log "Installed ${host_file}"
        installed=$((installed + 1))
    done

    [[ "${installed}" -gt 0 ]] || die "No matching firmware files on this host (skipped ${skipped})."

    log "Installed ${installed} firmware file(s) (skipped ${skipped})."
    log "Stop/start VMs to display the new boot logo."
    log "Restore originals with: sudo ${SCRIPT_DIR}/apply-custom-boot-logo.sh --restore"
}

main "$@"
