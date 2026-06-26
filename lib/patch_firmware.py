#!/usr/bin/env python3
"""Find and replace the embedded boot logo BMP inside OVMF firmware images."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class BmpRegion:
    offset: int
    size: int
    width: int
    height: int

    @property
    def end(self) -> int:
        return self.offset + self.size


def parse_bmp_at(data: bytes, offset: int) -> BmpRegion | None:
    """Parse a BMP blob at *offset*; return None if invalid."""
    if offset + 54 > len(data) or data[offset : offset + 2] != b"BM":
        return None

    file_size = struct.unpack_from("<I", data, offset + 2)[0]
    if file_size < 54 or offset + file_size > len(data):
        return None

    dib_size = struct.unpack_from("<I", data, offset + 14)[0]
    if dib_size < 40:
        return None

    width = struct.unpack_from("<i", data, offset + 18)[0]
    height = struct.unpack_from("<i", data, offset + 22)[0]
    planes = struct.unpack_from("<H", data, offset + 26)[0]
    bpp = struct.unpack_from("<H", data, offset + 28)[0]
    compression = struct.unpack_from("<I", data, offset + 30)[0]

    if planes != 1 or bpp != 24 or compression != 0:
        return None

    return BmpRegion(
        offset=offset,
        size=file_size,
        width=abs(width),
        height=abs(height),
    )


def find_bmp_regions(data: bytes) -> list[BmpRegion]:
    """Scan firmware binary for embedded 24-bit uncompressed BMP logos."""
    regions: list[BmpRegion] = []
    start = 0
    while True:
        idx = data.find(b"BM", start)
        if idx == -1:
            break
        region = parse_bmp_at(data, idx)
        if region is not None:
            regions.append(region)
            start = region.end
        else:
            start = idx + 1
    return regions


def choose_logo_region(regions: list[BmpRegion]) -> BmpRegion:
    """Pick the most likely boot logo BMP from candidates."""
    if not regions:
        raise ValueError("No embedded BMP logos found in firmware")

    # OVMF boot logos are typically modestly sized and not tiny icons.
    candidates = [r for r in regions if 16 <= r.width <= 2048 and 16 <= r.height <= 2048]
    if not candidates:
        candidates = regions

    # Prefer the largest pixel area — boot logos are usually the biggest BMP.
    return max(candidates, key=lambda r: r.width * r.height)


def extract_logo(firmware: Path, output: Path) -> BmpRegion:
    data = firmware.read_bytes()
    region = choose_logo_region(find_bmp_regions(data))
    output.write_bytes(data[region.offset : region.end])
    return region


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

    region = choose_logo_region(find_bmp_regions(bytes(fw_data)))

    logo_region = parse_bmp_at(logo_data, 0)
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


def backup_file(path: Path, backup_dir: Path) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = path.name
    backup_path = backup_dir / stamp
    if not backup_path.exists():
        shutil.copy2(path, backup_path)
    return backup_path


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

    args = parser.parse_args()

    try:
        if args.command == "extract":
            region = extract_logo(args.firmware, args.output)
            print(
                f"Extracted {args.output} "
                f"({region.width}x{region.height}, {region.size} bytes)"
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
            regions = find_bmp_regions(args.firmware.read_bytes())
            if not regions:
                print("No BMP regions found")
                return 1
            for i, region in enumerate(regions, 1):
                print(
                    f"[{i}] offset=0x{region.offset:x} "
                    f"size={region.size} {region.width}x{region.height}"
                )
            chosen = choose_logo_region(regions)
            print(
                f"Selected logo: offset=0x{chosen.offset:x} "
                f"{chosen.width}x{chosen.height}"
            )
    except Exception as exc:  # noqa: BLE001 - CLI tool
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())