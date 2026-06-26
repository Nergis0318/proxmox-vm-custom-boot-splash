#!/usr/bin/env python3
"""Find and replace the embedded boot logo BMP inside OVMF firmware images."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from uefi_lzma import find_guid_offsets, iter_decompressed_chunks

LOGO_GUID = "7BB28B99-61BB-11D5-9A5D-0090273FC14D"


@dataclass(frozen=True)
class BmpRegion:
    offset: int
    size: int
    width: int
    height: int
    source: str = "raw"

    @property
    def end(self) -> int:
        return self.offset + self.size


def _row_size(width: int, bpp: int) -> int:
    return ((width * (bpp // 8) + 3) // 4) * 4


def _computed_bmp_size(width: int, height: int, bpp: int, pixel_offset: int) -> int:
    return pixel_offset + _row_size(abs(width), bpp) * abs(height)


def parse_bmp_at(data: bytes, offset: int, *, relaxed: bool = False) -> BmpRegion | None:
    """Parse a BMP blob at *offset*; return None if invalid."""
    if offset + 54 > len(data) or data[offset : offset + 2] != b"BM":
        return None

    file_size = struct.unpack_from("<I", data, offset + 2)[0]
    pixel_offset = struct.unpack_from("<I", data, offset + 10)[0]
    dib_size = struct.unpack_from("<I", data, offset + 14)[0]
    if dib_size < 40:
        return None

    width = struct.unpack_from("<i", data, offset + 18)[0]
    height = struct.unpack_from("<i", data, offset + 22)[0]
    planes = struct.unpack_from("<H", data, offset + 26)[0]
    bpp = struct.unpack_from("<H", data, offset + 28)[0]
    compression = struct.unpack_from("<I", data, offset + 30)[0]

    if planes != 1 or compression != 0 or bpp not in (24, 32):
        return None
    if width == 0 or height == 0 or abs(width) > 4096 or abs(height) > 4096:
        return None

    computed = _computed_bmp_size(width, height, bpp, pixel_offset)
    size = file_size
    if size < 54 or offset + size > len(data):
        if relaxed and computed >= 54 and offset + computed <= len(data):
            size = computed
        else:
            return None

    return BmpRegion(
        offset=offset,
        size=size,
        width=abs(width),
        height=abs(height),
    )


def find_bmp_regions(data: bytes, *, relaxed: bool = True) -> list[BmpRegion]:
    """Scan a buffer for embedded BMP logos."""
    regions: list[BmpRegion] = []
    start = 0
    while True:
        idx = data.find(b"BM", start)
        if idx == -1:
            break
        region = parse_bmp_at(data, idx, relaxed=relaxed)
        if region is not None:
            regions.append(region)
            start = region.end
        else:
            start = idx + 1
    return regions


def find_bmp_near_logo_guid(data: bytes) -> list[BmpRegion]:
    regions: list[BmpRegion] = []
    for guid_offset in find_guid_offsets(data, LOGO_GUID):
        window_start = max(0, guid_offset - 4096)
        window_end = min(len(data), guid_offset + 65536)
        for region in find_bmp_regions(data[window_start:window_end]):
            regions.append(
                BmpRegion(
                    offset=window_start + region.offset,
                    size=region.size,
                    width=region.width,
                    height=region.height,
                    source="guid-window",
                )
            )
    return regions


def find_bmp_in_decompressed(data: bytes) -> list[BmpRegion]:
    regions: list[BmpRegion] = []
    for chunk in iter_decompressed_chunks(data):
        for region in find_bmp_regions(chunk):
            regions.append(
                BmpRegion(
                    offset=region.offset,
                    size=region.size,
                    width=region.width,
                    height=region.height,
                    source="decompressed",
                )
            )
    return regions


def find_all_logo_candidates(data: bytes) -> list[BmpRegion]:
    """Collect BMP logo candidates using every supported scan strategy."""
    regions: list[BmpRegion] = []
    regions.extend(find_bmp_regions(data))
    regions.extend(find_bmp_near_logo_guid(data))
    regions.extend(find_bmp_in_decompressed(data))

    unique: dict[tuple[int, int, int, int], BmpRegion] = {}
    for region in regions:
        key = (region.offset, region.size, region.width, region.height)
        unique[key] = region
    return list(unique.values())


def choose_logo_region(regions: list[BmpRegion]) -> BmpRegion:
    """Pick the most likely boot logo BMP from candidates."""
    if not regions:
        raise ValueError("No embedded BMP logos found in firmware")

    raw = [r for r in regions if r.source == "raw"]
    pool = raw or regions

    candidates = [r for r in pool if 16 <= r.width <= 2048 and 16 <= r.height <= 2048]
    if not candidates:
        candidates = pool

    return max(candidates, key=lambda r: r.width * r.height)


def extract_with_uefiextract(firmware: Path, output: Path) -> BmpRegion | None:
    """Fallback: use uefiextract when the logo is only visible after FFS parsing."""
    for tool in ("uefiextract", "UEFIExtract"):
        if not shutil.which(tool):
            continue

        with tempfile.TemporaryDirectory(prefix="pve-logo-") as tmp:
            subprocess.run(
                [tool, str(firmware)],
                cwd=tmp,
                check=False,
                capture_output=True,
                text=True,
            )
            bmp_files = sorted(Path(tmp).rglob("*.bmp"))
            bmp_files.extend(sorted(Path(tmp).rglob("*.BMP")))
            if not bmp_files:
                continue

            chosen = max(
                bmp_files,
                key=lambda p: p.stat().st_size,
            )
            data = chosen.read_bytes()
            region = parse_bmp_at(data, 0, relaxed=True)
            if region is None:
                continue
            output.write_bytes(data)
            return BmpRegion(
                offset=0,
                size=region.size,
                width=region.width,
                height=region.height,
                source="uefiextract",
            )
    return None


def diagnose_firmware(firmware: Path) -> dict:
    data = firmware.read_bytes()
    raw = find_bmp_regions(data)
    guid_hits = find_guid_offsets(data, LOGO_GUID)
    decompressed = find_bmp_in_decompressed(data)
    all_candidates = find_all_logo_candidates(data)

    return {
        "path": str(firmware),
        "size": len(data),
        "raw_bmp_count": len(raw),
        "guid_hits": len(guid_hits),
        "decompressed_bmp_count": len(decompressed),
        "candidate_count": len(all_candidates),
        "has_uefiextract": bool(shutil.which("uefiextract") or shutil.which("UEFIExtract")),
        "patchable": any(r.source == "raw" for r in all_candidates),
    }


def extract_logo(firmware: Path, output: Path) -> BmpRegion:
    data = firmware.read_bytes()
    candidates = find_all_logo_candidates(data)
    raw_candidates = [r for r in candidates if r.source == "raw"]
    if raw_candidates:
        region = choose_logo_region(raw_candidates)
        output.write_bytes(data[region.offset : region.end])
        return region

    extracted = extract_with_uefiextract(firmware, output)
    if extracted is not None:
        return extracted

    info = diagnose_firmware(firmware)
    raise ValueError(
        "No embedded BMP logos found in firmware. "
        f"raw_bmp={info['raw_bmp_count']}, "
        f"guid_hits={info['guid_hits']}, "
        f"decompressed_bmp={info['decompressed_bmp_count']}. "
        "This usually means the logo is LZMA-compressed inside the UEFI volume. "
        "Use: sudo ./scripts/apply-custom-boot-logo.sh <logo> --build"
    )


def patch_firmware(
    firmware: Path,
    logo_bmp: Path,
    output: Path | None = None,
    *,
    allow_resize_mismatch: bool = False,
) -> BmpRegion:
    """Replace the embedded logo BMP in *firmware* with *logo_bmp*."""
    fw_data = bytearray(firmware.read_bytes())
    logo_data = logo_bmp.read_bytes()

    candidates = find_all_logo_candidates(bytes(fw_data))
    raw_candidates = [r for r in candidates if r.source == "raw"]
    if not raw_candidates:
        raise ValueError(
            "Logo is not stored as a plain BMP in this firmware image. "
            "Quick patch cannot modify compressed UEFI sections. "
            "Use --build to rebuild pve-edk2-firmware from source."
        )

    region = choose_logo_region(raw_candidates)

    logo_region = parse_bmp_at(logo_data, 0, relaxed=True)
    if logo_region is None:
        raise ValueError(f"Invalid replacement BMP: {logo_bmp}")

    if logo_region.size != region.size and not allow_resize_mismatch:
        raise ValueError(
            f"Logo size mismatch: firmware logo is {region.size} bytes "
            f"({region.width}x{region.height}), replacement is "
            f"{logo_region.size} bytes ({logo_region.width}x{logo_region.height}). "
            "Use --match with prepare_logo.py or run build-firmware.sh."
        )

    if logo_region.size != region.size:
        raise ValueError(
            "Variable-size logo replacement is not supported in quick-patch mode. "
            "Use build-firmware.sh instead."
        )

    fw_data[region.offset : region.end] = logo_data

    target = output or firmware
    target.write_bytes(fw_data)
    return region


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch OVMF firmware boot logos.")
    sub = parser.add_subparsers(dest="command", required=True)

    extract_parser = sub.add_parser("extract", help="Extract current logo BMP")
    extract_parser.add_argument("firmware", type=Path)
    extract_parser.add_argument("output", type=Path)

    patch_parser = sub.add_parser("patch", help="Replace logo inside firmware")
    patch_parser.add_argument("firmware", type=Path)
    patch_parser.add_argument("logo_bmp", type=Path)
    patch_parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Write patched firmware here (default: overwrite input)",
    )

    scan_parser = sub.add_parser("scan", help="List embedded BMP regions")
    scan_parser.add_argument("firmware", type=Path)

    diagnose_parser = sub.add_parser("diagnose", help="Explain why logo detection fails")
    diagnose_parser.add_argument("firmware", type=Path)

    args = parser.parse_args()

    try:
        if args.command == "extract":
            region = extract_logo(args.firmware, args.output)
            print(
                f"Extracted {args.output} "
                f"({region.width}x{region.height}, {region.size} bytes, "
                f"source={region.source})"
            )
        elif args.command == "patch":
            region = patch_firmware(args.firmware, args.logo_bmp, args.output)
            target = args.output or args.firmware
            print(
                f"Patched {target} at offset 0x{region.offset:x} "
                f"({region.width}x{region.height})"
            )
            print(f"SHA256: {sha256_file(target)}")
        elif args.command == "scan":
            regions = find_all_logo_candidates(args.firmware.read_bytes())
            if not regions:
                print("No BMP regions found")
                return 1
            for i, region in enumerate(regions, 1):
                print(
                    f"[{i}] offset=0x{region.offset:x} "
                    f"size={region.size} {region.width}x{region.height} "
                    f"source={region.source}"
                )
            chosen = choose_logo_region(
                [r for r in regions if r.source == "raw"] or regions
            )
            print(
                f"Selected logo: offset=0x{chosen.offset:x} "
                f"{chosen.width}x{chosen.height} source={chosen.source}"
            )
        elif args.command == "diagnose":
            info = diagnose_firmware(args.firmware)
            print(f"file: {info['path']}")
            print(f"size: {info['size']} bytes")
            print(f"raw BMP hits: {info['raw_bmp_count']}")
            print(f"Logo GUID hits: {info['guid_hits']}")
            print(f"decompressed BMP hits: {info['decompressed_bmp_count']}")
            print(f"uefiextract available: {info['has_uefiextract']}")
            print(f"quick-patch possible: {info['patchable']}")
            if not info["patchable"]:
                print(
                    "Recommendation: rebuild firmware with "
                    "./scripts/apply-custom-boot-logo.sh <logo> --build"
                )
                return 2
    except Exception as exc:  # noqa: BLE001 - CLI tool
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())