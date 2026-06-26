#!/usr/bin/env bash
# Apply a custom UEFI boot logo to Proxmox VM OVMF firmware images.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${ROOT_DIR}/lib"

PVE_FIRMWARE_DIR="/usr/share/pve-edk2-firmware"
KVM_FIRMWARE_DIR="/usr/share/kvm"
BACKUP_DIR="/var/lib/pve-custom-boot-logo/backups"
WORK_DIR="/var/lib/pve-custom-boot-logo/work"

# OVMF CODE images that carry the boot logo (VARS files are NVRAM, not logos).
DEFAULT_FIRMWARE_FILES=(
    "OVMF_CODE_4M.fd"
    "OVMF_CODE_4M.secboot.fd"
    "OVMF_CODE-pure-efi.fd"
    "OVMF_CODE.fd"
)

usage() {
    cat <<'EOF'
Proxmox VM Custom Boot Logo

Usage:
  apply-custom-boot-logo.sh <logo-image> [options]

Arguments:
  logo-image    PNG, JPG, BMP, or other image supported by Pillow

Options:
  --firmware-dir DIR   Firmware directory (default: auto-detect)
  --files LIST         Comma-separated firmware filenames to patch
  --vmid ID            Patch only firmware files used by this VM
  --build              Rebuild firmware from pve-edk2-firmware source
  --auto-build         Fall back to --build when quick patch is impossible
  --dry-run            Show actions without modifying firmware
  --restore            Restore firmware from backups
  -h, --help           Show this help

Examples:
  sudo ./apply-custom-boot-logo.sh ./company-logo.png
  sudo ./apply-custom-boot-logo.sh ./logo.png --vmid 101
  sudo ./apply-custom-boot-logo.sh ./logo.png --build
  sudo ./apply-custom-boot-logo.sh --restore

Notes:
  - Run on the Proxmox host as root.
  - Quick patch replaces the embedded BMP in-place (same dimensions required).
  - Windows + Secure Boot VMs usually need OVMF_CODE_4M.secboot.fd or *.ms.fd.
  - Reboot running VMs (or stop/start) to see the new logo.
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

require_python() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required"
    python3 -c "from PIL import Image" 2>/dev/null || {
        log "Installing python3-pil..."
        apt-get update -qq
        apt-get install -y python3-pil
    }
}

detect_firmware_dir() {
    if [[ -n "${FIRMWARE_DIR:-}" ]]; then
        echo "${FIRMWARE_DIR}"
        return
    fi
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

firmware_for_vmid() {
    local vmid="$1"
    local conf="/etc/pve/qemu-server/${vmid}.conf"
    [[ -f "${conf}" ]] || die "VM ${vmid} config not found: ${conf}"

    local eficode=""
    eficode="$(grep -E '^efidisk0:' "${conf}" | head -n1 || true)"
    [[ -n "${eficode}" ]] || die "VM ${vmid} does not appear to use UEFI (no efidisk0)"

    local machine=""
    machine="$(grep -E '^machine:' "${conf}" | head -n1 | cut -d: -f2- | xargs || true)"

    local files=()
    if [[ "${eficode}" == *"pre-enrolled-keys=1"* ]] || [[ "${machine}" == *"q35"* && "${eficode}" == *"efitype=4m"* ]]; then
        files+=("OVMF_CODE_4M.secboot.fd")
    fi
    files+=("OVMF_CODE_4M.fd" "OVMF_CODE-pure-efi.fd" "OVMF_CODE.fd")

    printf '%s\n' "${files[@]}" | awk '!seen[$0]++'
}

restore_firmware() {
    require_root
    [[ -d "${BACKUP_DIR}" ]] || die "No backups found at ${BACKUP_DIR}"

    local restored=0
    for backup in "${BACKUP_DIR}"/*.fd; do
        [[ -f "${backup}" ]] || continue
        local name
        name="$(basename "${backup}")"
        local target=""
        if [[ -f "${PVE_FIRMWARE_DIR}/${name}" ]]; then
            target="${PVE_FIRMWARE_DIR}/${name}"
        elif [[ -f "${KVM_FIRMWARE_DIR}/${name}" ]]; then
            target="${KVM_FIRMWARE_DIR}/${name}"
        else
            log "Skipping ${name}: installed firmware not found"
            continue
        fi
        cp -a "${backup}" "${target}"
        log "Restored ${target}"
        restored=$((restored + 1))
    done

    [[ "${restored}" -gt 0 ]] || die "No firmware files were restored"
    log "Done. Restart VMs to pick up restored firmware."
}

patch_one_firmware() {
    local firmware_path="$1"
    local dry_run="$2"

    [[ -f "${firmware_path}" ]] || {
        log "Skip missing firmware: ${firmware_path}"
        return 1
    }

    local name
    name="$(basename "${firmware_path}")"
    local extracted="${WORK_DIR}/${name%.fd}-original-logo.bmp"
    local prepared="${WORK_DIR}/${name%.fd}-custom-logo.bmp"

    mkdir -p "${WORK_DIR}" "${BACKUP_DIR}"

    if [[ ! -f "${BACKUP_DIR}/${name}" ]]; then
        if [[ "${dry_run}" == "1" ]]; then
            log "[dry-run] Would backup ${firmware_path} -> ${BACKUP_DIR}/${name}"
        else
            cp -a "${firmware_path}" "${BACKUP_DIR}/${name}"
            log "Backup saved: ${BACKUP_DIR}/${name}"
        fi
    fi

    if [[ "${dry_run}" == "1" ]]; then
        python3 "${LIB_DIR}/patch_firmware.py" scan "${firmware_path}"
        log "[dry-run] Would extract logo from ${name}"
        log "[dry-run] Would prepare custom logo matching extracted dimensions"
        log "[dry-run] Would patch ${firmware_path}"
        return 0
    fi

    if ! python3 "${LIB_DIR}/patch_firmware.py" diagnose "${firmware_path}"; then
        log "Quick patch not possible for ${firmware_path}"
        return 2
    fi

    python3 "${LIB_DIR}/patch_firmware.py" extract "${firmware_path}" "${extracted}"
    python3 "${LIB_DIR}/prepare_logo.py" "${LOGO_IMAGE}" "${prepared}" --match "${extracted}"
    python3 "${LIB_DIR}/patch_firmware.py" patch "${firmware_path}" "${prepared}"
    log "Patched ${firmware_path}"
    return 0
}

main() {
    local logo_image=""
    local firmware_dir=""
    local files_csv=""
    local vmid=""
    local mode="patch"
    local dry_run="0"
    local auto_build="0"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --restore)
                restore_firmware
                exit 0
                ;;
            --build)
                mode="build"
                shift
                ;;
            --auto-build)
                auto_build="1"
                shift
                ;;
            --dry-run)
                dry_run="1"
                shift
                ;;
            --firmware-dir)
                firmware_dir="$2"
                shift 2
                ;;
            --files)
                files_csv="$2"
                shift 2
                ;;
            --vmid)
                vmid="$2"
                shift 2
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -z "${logo_image}" ]]; then
                    logo_image="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    if [[ "${mode}" == "build" ]]; then
        require_root
        [[ -n "${logo_image}" ]] || die "Logo image is required for --build"
        exec "${SCRIPT_DIR}/build-firmware.sh" "${logo_image}"
    fi

    [[ -n "${logo_image}" ]] || {
        usage
        exit 1
    }
    [[ -f "${logo_image}" ]] || die "Logo image not found: ${logo_image}"

    require_root
    require_python

    LOGO_IMAGE="$(readlink -f "${logo_image}")"
    FIRMWARE_DIR="$(detect_firmware_dir)"
    [[ -n "${firmware_dir}" ]] && FIRMWARE_DIR="${firmware_dir}"

    local files=()
    if [[ -n "${files_csv}" ]]; then
        IFS=',' read -r -a files <<< "${files_csv}"
    elif [[ -n "${vmid}" ]]; then
        mapfile -t files < <(firmware_for_vmid "${vmid}")
    else
        files=("${DEFAULT_FIRMWARE_FILES[@]}")
    fi

    log "Firmware dir: ${FIRMWARE_DIR}"
    log "Logo image:   ${LOGO_IMAGE}"

    local attempted=0
    local succeeded=0
    local needs_build=0
    for name in "${files[@]}"; do
        name="$(echo "${name}" | xargs)"
        [[ -n "${name}" ]] || continue
        local path="${FIRMWARE_DIR}/${name}"
        if [[ ! -f "${path}" && -f "${KVM_FIRMWARE_DIR}/${name}" ]]; then
            path="${KVM_FIRMWARE_DIR}/${name}"
        fi
        attempted=$((attempted + 1))
        if patch_one_firmware "${path}" "${dry_run}"; then
            succeeded=$((succeeded + 1))
        else
            local rc=$?
            if [[ "${rc}" -eq 2 ]]; then
                needs_build=1
            fi
        fi
    done

    [[ "${attempted}" -gt 0 ]] || die "No firmware files were processed"

    if [[ "${dry_run}" == "1" ]]; then
        log "Dry run complete."
        exit 0
    fi

    if [[ "${succeeded}" -gt 0 ]]; then
        log "Patched ${succeeded}/${attempted} firmware file(s)."
        log "Stop/start VMs to display the new boot logo."
        log "Restore originals with: sudo ${SCRIPT_DIR}/apply-custom-boot-logo.sh --restore"
        exit 0
    fi

    log "Quick patch failed on all firmware files."
    if [[ "${needs_build}" -eq 1 || "${auto_build}" == "1" ]]; then
        log "Falling back to pve-edk2-firmware source build..."
        exec "${SCRIPT_DIR}/build-firmware.sh" "${LOGO_IMAGE}"
    fi

    die "Logo is LZMA-compressed in modern Proxmox firmware. Re-run with --build or --auto-build."
}

main "$@"