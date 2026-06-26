#!/usr/bin/env python3
"""Lightweight tests for firmware BMP scanning logic."""

import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))

from patch_firmware import choose_logo_region, find_bmp_regions, patch_firmware  # noqa: E402


def make_bmp(width: int, height: int, fill: int = 0) -> bytes:
    row_size = ((width * 3 + 3) // 4) * 4
    pixel_data = bytes([fill] * (row_size * height))
    pixel_offset = 54
    file_size = pixel_offset + len(pixel_data)

    header = bytearray()
    header += b"BM"
    header += struct.pack("<I", file_size)
    header += b"\x00\x00\x00\x00"
    header += struct.pack("<I", pixel_offset)
    header += struct.pack("<I", 40)
    header += struct.pack("<i", width)
    header += struct.pack("<i", height)
    header += struct.pack("<H", 1)
    header += struct.pack("<H", 24)
    header += struct.pack("<I", 0)
    header += struct.pack("<I", len(pixel_data))
    header += b"\x00" * 16
    return bytes(header) + pixel_data


class PatchFirmwareTests(unittest.TestCase):
    def test_find_and_patch_logo(self) -> None:
        small = make_bmp(32, 32, fill=1)
        large = make_bmp(120, 80, fill=2)
        firmware = b"\xff" * 1000 + small + b"\x00" * 500 + large + b"\xaa" * 200

        regions = find_bmp_regions(firmware)
        self.assertEqual(len(regions), 2)
        chosen = choose_logo_region(regions)
        self.assertEqual((chosen.width, chosen.height), (120, 80))

        with tempfile.TemporaryDirectory() as tmp:
            fw_path = Path(tmp) / "OVMF_CODE_4M.fd"
            logo_path = Path(tmp) / "logo.bmp"
            fw_path.write_bytes(firmware)
            logo_path.write_bytes(large)

            patch_firmware(fw_path, logo_path)
            patched_regions = find_bmp_regions(fw_path.read_bytes())
            self.assertEqual(len(patched_regions), 2)


if __name__ == "__main__":
    unittest.main()
