# Design: install-from-release.sh

Date: 2026-06-27

## Summary

Add `scripts/install-from-release.sh`, a standalone script that downloads
pre-built OVMF CODE firmware images from this repo's GitHub Releases and installs
them onto a Proxmox VE host. It is the fast alternative to the on-host source
build (`--build`, 10-30 min): the CI workflow already builds and attaches the
`.fd` images to each Release, so the host only needs to download and copy them.

## Goals

- Download pre-built `OVMF_CODE_4M.fd` / `OVMF_CODE_4M.secboot.fd` from a GitHub
  Release and install them into the host firmware directory.
- Default to the latest Release; allow pinning a specific tag with `--version`.
- Verify integrity against the Release's `SHA256SUMS` before installing.
- Reuse the existing backup convention so the existing `--restore` path works.
- No new host dependencies beyond `curl` or `wget` (no `gh` CLI, no `jq`).

## Non-goals

- No per-VM / per-file filtering (no `--vmid` / `--files`). All CODE files listed
  in the Release's `SHA256SUMS` are installed.
- No own `--restore`. Recovery is handled by the existing
  `apply-custom-boot-logo.sh --restore`, which reads the same backup directory.
- No logo conversion or firmware patching. This script only ships the already
  built `.fd` files.

## Release asset contract

The `firmware` job in `.github/workflows/build-firmware.yml` attaches these
assets to every `v*` / version-tagged Release:

- `OVMF_CODE_4M.fd`
- `OVMF_CODE_4M.secboot.fd`
- `SHA256SUMS` — produced by `cd dist && sha256sum ./*.fd`, so each line is
  `<hash>  ./<filename>.fd`.

The auto-release workflow can tag Releases with the upstream version (which does
not necessarily start with `v`), so the script must not assume a tag format; it
resolves "latest" via GitHub's `releases/latest/download/...` redirect.

## Download mechanism

Use GitHub's Release asset redirect URLs — no API token, no `jq`, no rate-limit
exposure:

- Latest:  `https://github.com/<repo>/releases/latest/download/<asset>`
- Pinned:  `https://github.com/<repo>/releases/download/<tag>/<asset>`

A small `download <url> <dest>` helper prefers `curl -fsSL` and falls back to
`wget -qO`; if neither is present it dies with a clear message.

**Asset discovery:** download `SHA256SUMS` first, parse the `.fd` filenames from
it (`awk '{print $2}'` then strip a leading `./`), and download exactly those
files. This auto-adapts if the Release's file set changes.

## Processing flow

```
require_root
  -> resolve repo (flag/env/default) and base URL (latest vs --version <tag>)
  -> mktemp -d work dir (trap-cleaned on exit)
  -> download SHA256SUMS
  -> parse .fd filenames from SHA256SUMS
  -> download each .fd into the work dir
  -> verify: (cd workdir && sha256sum -c SHA256SUMS.filtered)   [unless --no-verify]
  -> detect firmware dir: /usr/share/pve-edk2-firmware -> fallback /usr/share/kvm
  -> for each .fd:
       if host file exists:
           backup to /var/lib/pve-custom-boot-logo/backups/<name> (first time only)
           cp -a downloaded -> host file
       else:
           log skip + warning (do not add stray files)
  -> print "stop/start VMs" + restore hint
```

`--dry-run` stops after verification and only reports what would be installed.

## CLI

| Option | Behaviour |
| --- | --- |
| `--version <tag>` | Install a specific Release (default: latest). |
| `--repo <owner/name>` | Target repo (default `Nergis0318/proxmox-vm-custom-boot-splash`; env `GITHUB_REPO` also honoured). |
| `--firmware-dir <dir>` | Force the firmware directory. |
| `--dry-run` | Download + verify only; do not install. |
| `--no-verify` | Skip checksum verification (escape hatch). |
| `-h, --help` | Usage. |

## Reused conventions (match existing scripts)

- `#!/usr/bin/env bash` + `set -euo pipefail`.
- `SCRIPT_DIR` / `ROOT_DIR` resolution, `log()` / `die()` / `require_root()`.
- Firmware dir constants and detection identical to `apply-custom-boot-logo.sh`.
- Backup dir `/var/lib/pve-custom-boot-logo/backups/`; back up a file only if no
  backup exists yet (so the original is preserved, not overwritten by a patched
  copy on re-runs).

## Safety

- Only overwrite firmware files that already exist on the host; skip + warn
  otherwise. Prevents adding firmware variants the host does not use.
- Checksum verification on by default; `--no-verify` is opt-in.
- Work dir is a `mktemp -d` cleaned via `trap` so partial downloads never touch
  the firmware dir.
- Backups enable recovery through the existing `--restore`.

## Docs to update

- `README.md` — add an "Install from Release (fastest)" subsection under the
  apply-method section, showing `latest` and `--version` usage.
- `AGENTS.md` — add the new script to the entrypoint list.

## Testing / verification

This is a host-only network+filesystem script; no unit test harness exists for
shell here. Verify manually:

- `bash -n scripts/install-from-release.sh` (syntax).
- `shellcheck` if available.
- `--help` renders.
- `--dry-run` against a real Release downloads + verifies without writing.
- Optionally run `--dry-run` with `--firmware-dir <tmp>` containing dummy `.fd`
  files to exercise the detect/skip logic off-host.
