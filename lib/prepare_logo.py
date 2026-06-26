#!/usr/bin/env python3
"""Convert an image file to a UEFI/OVMF-compatible 24-bit BMP logo."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    Image = None  # type: ignore[assignment,misc]


def parse_bmp_header(data: bytes) -> tuple[int, int, int]:
    """Return (width, height, pixel_data_offset) from a BMP header."""
    if len(data) < 26 or data[:2] != b"BM":
        raise ValueError("Not a valid BMP file")

    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    dib_header_size = struct.unpack_from("<I", data, 14)[0]
    if dib_header_size < 40:
        raise ValueError("Unsupported BMP DIB header")

    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    bits_per_pixel = struct.unpack_from("<H", data, 28)[0]

    if bits_per_pixel != 24:
        raise ValueError(f"Expected 24-bit BMP, got {bits_per_pixel}-bit")

    return abs(width), abs(height), pixel_offset


def convert_to_uefi_bmp(
    source: Path,
    output: Path,
    *,
    width: int | None = None,
    height: int | None = None,
    background: str = "black",
) -> tuple[int, int]:
    """Convert *source* image to a bottom-up 24-bit BMP suitable for OVMF."""
    if Image is None:
        raise RuntimeError("Pillow is required. Install with: pip install Pillow")

    with Image.open(source) as img:
        img = img.convert("RGBA")
        target_w = width or img.width
        target_h = height or img.height

        canvas = Image.new("RGBA", (target_w, target_h), background)
        scale = min(target_w / img.width, target_h / img.height)
        new_w = max(1, int(img.width * scale))
        new_h = max(1, int(img.height * scale))
        resized = img.resize((new_w, new_h), Image.Resampling.LANCZOS)

        offset_x = (target_w - new_w) // 2
        offset_y = (target_h - new_h) // 2
        canvas.paste(resized, (offset_x, offset_y), resized)

        rgb = canvas.convert("RGB")
        rgb.save(output, format="BMP")

    out_w, out_h, _ = parse_bmp_header(output.read_bytes())
    return out_w, out_h


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert an image to a UEFI/OVMF boot logo BMP."
    )
    parser.add_argument("source", type=Path, help="Input image (PNG, JPG, BMP, ...)")
    parser.add_argument("output", type=Path, help="Output Logo.bmp path")
    parser.add_argument(
        "--width",
        type=int,
        default=None,
        help="Target width in pixels (default: keep source width)",
    )
    parser.add_argument(
        "--height",
        type=int,
        default=None,
        help="Target height in pixels (default: keep source height)",
    )
    parser.add_argument(
        "--match",
        type=Path,
        default=None,
        help="Match dimensions of an existing firmware logo BMP",
    )
    parser.add_argument(
        "--background",
        default="black",
        help="Letterbox background color (default: black)",
    )
    args = parser.parse_args()

    if not args.source.is_file():
        print(f"error: source not found: {args.source}", file=sys.stderr)
        return 1

    width = args.width
    height = args.height
    if args.match:
        if not args.match.is_file():
            print(f"error: match file not found: {args.match}", file=sys.stderr)
            return 1
        match_w, match_h, _ = parse_bmp_header(args.match.read_bytes())
        width = width or match_w
        height = height or match_h

    try:
        out_w, out_h = convert_to_uefi_bmp(
            args.source,
            args.output,
            width=width,
            height=height,
            background=args.background,
        )
    except Exception as exc:  # noqa: BLE001 - CLI tool
        print(f"error: {exc}", file=sys.stderr)
        return 1

    size = args.output.stat().st_size
    print(f"Created {args.output} ({out_w}x{out_h}, {size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
