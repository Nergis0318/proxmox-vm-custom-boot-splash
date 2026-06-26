#!/usr/bin/env python3
"""Minimal UEFI/Tiano LZMA decompress helpers."""

from __future__ import annotations

import lzma
import struct


def _lzma_props_to_filter(props: bytes) -> dict | None:
    if len(props) != 5:
        return None

    d = props[0]
    lc = d % 9
    d //= 9
    lp = d % 5
    pb = d // 5
    dict_size = props[1] | (props[2] << 8) | (props[3] << 16)
    if dict_size < 4096 or dict_size > 64 * 1024 * 1024:
        return None

    return {
        "id": lzma.FILTER_LZMA1,
        "dict_size": max(dict_size, 4096),
        "lc": lc,
        "lp": lp,
        "pb": pb,
    }


def decompress_uefi_lzma(data: bytes) -> bytes | None:
    """Try to decompress a UEFI standard LZMA blob."""
    if len(data) < 14:
        return None

    for skip in range(0, 9):
        chunk = data[skip:]
        if len(chunk) < 14:
            continue

        props = chunk[8:13]
        compressed = chunk[13:]
        filt = _lzma_props_to_filter(props)
        if filt is None:
            continue

        try:
            return lzma.decompress(compressed, format=lzma.FORMAT_RAW, filters=[filt])
        except lzma.LZMAError:
            continue

    return None


def iter_decompressed_chunks(data: bytes, *, max_chunks: int = 256) -> list[bytes]:
    """Brute-force decompress likely LZMA regions inside firmware."""
    chunks: list[bytes] = []
    seen_hashes: set[bytes] = set()

    # EFI_SECTION_COMPRESSION headers often precede LZMA payloads.
    markers = (b"\x01\x00\x00", b"\x02\x00\x00")
    offsets: set[int] = set()
    for marker in markers:
        start = 0
        while True:
            idx = data.find(marker, start)
            if idx == -1:
                break
            for delta in range(-4, 8):
                offsets.add(max(0, idx + delta))
            start = idx + 1

    # Also sample aligned offsets — logos can sit behind opaque section headers.
    for idx in range(0, len(data) - 64, 512):
        offsets.add(idx)

    for offset in sorted(offsets):
        if len(chunks) >= max_chunks:
            break
        out = decompress_uefi_lzma(data[offset:])
        if not out or len(out) < 54:
            continue
        digest = out[:64]
        if digest in seen_hashes:
            continue
        seen_hashes.add(digest)
        chunks.append(out)

    return chunks


def find_guid_offsets(data: bytes, guid: str) -> list[int]:
    """Return offsets of a GUID stored in mixed-endian UEFI layout."""
    parts = guid.split("-")
    if len(parts) != 5:
        return []

    a = struct.pack("<I", int(parts[0], 16))
    b = struct.pack("<H", int(parts[1], 16))
    c = struct.pack("<H", int(parts[2], 16))
    d = bytes.fromhex(parts[3])
    e = bytes.fromhex(parts[4])
    needle = a + b + c + d + e

    offsets: list[int] = []
    start = 0
    while True:
        idx = data.find(needle, start)
        if idx == -1:
            break
        offsets.append(idx)
        start = idx + 1
    return offsets
