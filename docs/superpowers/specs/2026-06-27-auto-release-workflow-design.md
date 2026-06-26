# Design: Weekly auto-release on upstream version bump

Date: 2026-06-27

## Goal

Automatically cut a new GitHub Release whenever the upstream Proxmox firmware
repository (`git://git.proxmox.com/git/pve-edk2-firmware.git`) publishes a new
version, and have the existing `build-firmware` workflow build the OVMF images
and attach them to that release.

## Trigger flow constraint

GitHub's default `GITHUB_TOKEN` does **not** trigger other workflows when it
pushes a tag (recursion guard). So creating a tag alone will not start
`build-firmware.yml` (`on: push: tags: ["v*"]`).

Resolution: the new workflow explicitly dispatches the build via
`gh workflow run build-firmware.yml --ref <tag>`. `workflow_dispatch` _is_
allowed with `GITHUB_TOKEN`, so no PAT is required. Because the dispatch runs on
a tag ref, `github.ref` becomes `refs/tags/<tag>`, which satisfies the existing
release-attach condition in `build-firmware.yml` unchanged.

## New file: `.github/workflows/auto-release.yml`

### Triggers

- `schedule`: `cron: "0 6 * * 1"` — every Monday 06:00 UTC.
- `workflow_dispatch`: manual run for testing.

### Permissions

- `contents: write` — create tags / releases.
- `actions: write` — dispatch `build-firmware.yml`.

### Single job: `check-and-release`

1. **Fetch latest upstream commit.** `git clone --depth 2 --no-tags
https://git.proxmox.com/git/pve-edk2-firmware.git upstream`. Depth 2 keeps
   `HEAD~1` so the changelog diff is available. (`https` is used because `git://`
   is commonly blocked, mirroring `scripts/build-firmware.sh`.)
2. **Match version.** If `git log -1 --format=%s` matches
   `^bump version to (.+)$`, capture the version (e.g. `4.2025.05-2`). Otherwise
   exit 0 (nothing to do).
3. **Dedup.** If `gh release view <version>` succeeds, the release already
   exists — exit 0. This makes the weekly run idempotent.
4. **Release notes.** Extract added lines from the changelog diff:
   `git show --no-color --format= HEAD -- debian/changelog`, keep lines starting
   with `+` (excluding the `+++` header), strip the leading `+`. This yields the
   new changelog stanza verbatim. Fallback to the commit subject if empty.
5. **Create release.** `gh release create <version> --title "Auto Build -
<version>" --notes-file release-notes.md --target $GITHUB_SHA`. The tag points
   at the current repo commit, which is what `build-firmware` will check out.
6. **Trigger build.** `gh workflow run build-firmware.yml --ref <version>`.

### Verified upstream data (2025-11-13 HEAD)

- Subject: `bump version to 4.2025.05-2`
- Changelog added lines:

  ```
  pve-edk2-firmware (4.2025.05-2) trixie; urgency=medium

    * add image for Intel TDX support.

   -- Proxmox Support Team <support@proxmox.com>  Thu, 13 Nov 2025 11:17:01 +0100
  ```

## `build-firmware.yml` changes

None required. When dispatched on a tag ref:

- `actions/checkout@v7` checks out the tag.
- The attach step's `if: startsWith(github.ref, 'refs/tags/')` is true.
- `softprops/action-gh-release@v3` updates the _existing_ release `<version>`:
  with no `name`/`body` inputs it preserves our title and notes and only uploads
  the `.fd` + `SHA256SUMS` assets.

## Edge cases

- Latest commit is not a version bump → exit 0 silently.
- Release for that version already exists → exit 0 (no duplicate build).
- Empty changelog diff → fall back to the commit subject as notes.
