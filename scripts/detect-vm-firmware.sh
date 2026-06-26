#!/usr/bin/env bash
# Show which OVMF firmware images a Proxmox VM is likely using.
set -euo pipefail

usage() {
    cat <<'EOF'
Detect likely OVMF firmware files for a Proxmox VM.

Usage:
  detect-vm-firmware.sh <vmid>
  detect-vm-firmware.sh --list-installed
EOF
}

list_installed() {
    for dir in /usr/share/pve-edk2-firmware /usr/share/kvm; do
        [[ -d "${dir}" ]] || continue
        printf '== %s ==\n' "${dir}"
        ls -1 "${dir}"/*.fd 2>/dev/null || true
        echo
    done
}

detect_vmid() {
    local vmid="$1"
    local conf="/etc/pve/qemu-server/${vmid}.conf"
    [[ -f "${conf}" ]] || {
        echo "error: VM config not found: ${conf}" >&2
        exit 1
    }

    echo "VM ${vmid} configuration:"
    grep -E '^(machine|bios|efidisk0|cpu|ostype):' "${conf}" || true
    echo

    local eficode
    eficode="$(grep -E '^efidisk0:' "${conf}" | head -n1 || true)"
    if [[ -z "${eficode}" ]]; then
        echo "This VM does not use UEFI (no efidisk0 entry)."
        echo "Custom UEFI boot logos apply only to UEFI VMs."
        exit 0
    fi

    echo "Likely firmware CODE files to patch:"
    if [[ "${eficode}" == *"pre-enrolled-keys=1"* ]]; then
        echo "  - OVMF_CODE_4M.secboot.fd   (Secure Boot, pre-enrolled keys)"
        echo "  - OVMF_CODE_4M.ms.fd        (Microsoft Secure Boot variant)"
    fi
    if [[ "${eficode}" == *"efitype=4m"* ]] || [[ "${eficode}" == *"4m"* ]]; then
        echo "  - OVMF_CODE_4M.fd"
    fi
    echo "  - OVMF_CODE-pure-efi.fd"
    echo "  - OVMF_CODE.fd"
    echo
    echo "VARS files (OVMF_VARS*.fd) store NVRAM and do not contain the boot logo."
    echo
    echo "Suggested command:"
    echo "  sudo ./apply-custom-boot-logo.sh <logo.png> --vmid ${vmid}"
}

main() {
    case "${1:-}" in
        -h|--help)
            usage
            ;;
        --list-installed)
            list_installed
            ;;
        "")
            usage
            exit 1
            ;;
        *)
            detect_vmid "$1"
            ;;
    esac
}

main "$@"