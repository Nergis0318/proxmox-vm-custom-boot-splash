# AGENTS.md

This repo patches Proxmox OVMF firmware to replace the UEFI boot logo. All production commands run **as root on a live Proxmox VE host** (not inside a guest VM or dev machine).

## Invocation (primary entrypoints)
- Main tool: `sudo ./scripts/apply-custom-boot-logo.sh <logo.png> [options]`
  - `--vmid N` — patch only firmware used by that VM
  - `--files LIST` — comma-separated firmware filenames
  - `--build` — force source rebuild of pve-edk2-firmware
  - `--auto-build` — fall back to `--build` if quick patch fails
  - `--dry-run`, `--restore`, `--firmware-dir DIR`
- Detect VM firmware: `./scripts/detect-vm-firmware.sh <vmid>` (or `--list-installed`)
- Low-level Python:
  - `python3 lib/patch_firmware.py {scan,extract,patch,diagnose} <firmware> ...`
  - `python3 lib/prepare_logo.py <input> <output.bmp> [--match ...]`
- Tests: `python3 tests/test_patch_firmware.py -v` (unittest, not pytest)

## Critical constraints (easy to miss)
- Scripts enforce root and look for `/usr/share/pve-edk2-firmware` (fallback `/usr/share/kvm`).
- Proxmox 8+: logos are LZMA-compressed inside UEFI volumes. `scan`/`diagnose` will show this; quick patch fails. Use `--build`/`--auto-build`.
- Only patch `OVMF_CODE*.fd` files. `OVMF_VARS*.fd` are NVRAM only (no logo).
- Windows 11 + Secure Boot VMs typically need `OVMF_CODE_4M.secboot.fd`.
- After patching: **stop then start** the VM. Running VMs do not reload firmware.
- Backups always written to `/var/lib/pve-custom-boot-logo/backups/`.
- On live Proxmox host, **never** install `gcc-multilib` or `qemu-utils` (they remove `proxmox-ve`/`pve-qemu-kvm`). Build script uses `gcc-i686-linux-gnu` and guards protected packages.
- Python: 3.14 (`.python-version`, `pyproject.toml`). Runtime dep is Pillow (`python3-pil`); scripts auto-install via apt if missing. No `uv`/`pip` workflow for host use.
- `main.py` is an unused placeholder.
- No repo-defined lint, typecheck, formatter, or `uv` commands. Use system tools if needed.

## Build / CI notes
- `./scripts/build-firmware.sh <logo>` (called by apply script under `--build`).
- Docker env: `docker/Dockerfile` (Debian 13/trixie base, ccache, cross-gcc).
- CI: `.github/workflows/build-firmware.yml` (GHCR image + weekly source cache + ccache) and `auto-release.yml` (upstream version watcher).

## Quick gotchas
- `diagnose` before assuming quick patch will work: `python3 lib/patch_firmware.py diagnose /usr/share/pve-edk2-firmware/OVMF_CODE_4M*.fd`
- Restore: `sudo ./scripts/apply-custom-boot-logo.sh --restore`
- Logo input can be PNG/JPG/BMP; converted to 24-bit BMP internally.
