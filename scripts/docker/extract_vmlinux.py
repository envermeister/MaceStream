#!/usr/bin/env python3
"""Extract an uncompressed Linux kernel from common vmlinuz containers."""

import bz2
import lzma
from pathlib import Path
import struct
import subprocess
import sys
import zlib


def plausible(data: bytes) -> bool:
    if len(data) < 1_000_000:
        return False
    if data.startswith(b"\x7fELF") or data[56:60] == b"ARM\x64":
        return True
    if len(data) > 0x206 and data[0x202:0x206] == b"HdrS":
        return True
    return len(data) > 4_000_000


def decompress_at(data: bytes, offset: int, kind: bytes) -> bytes:
    payload = data[offset:]
    if kind == b"\x1f\x8b\x08":
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        return decoder.decompress(payload) + decoder.flush()
    if kind == b"BZh":
        decoder = bz2.BZ2Decompressor()
        return decoder.decompress(payload)
    if kind in (b"\xfd7zXZ\x00", b"\x5d\x00\x00"):
        decoder = lzma.LZMADecompressor(format=lzma.FORMAT_AUTO)
        return decoder.decompress(payload)
    if kind == b"\x28\xb5\x2f\xfd":
        return subprocess.run(
            ["zstd", "-dc"], input=payload, capture_output=True, check=True
        ).stdout
    if kind == b"\x02\x21\x4c\x18":
        return subprocess.run(
            ["lz4", "-dc"], input=payload, capture_output=True, check=True
        ).stdout
    raise ValueError("Unknown compression format")


def extract(source: Path) -> bytes:
    data = source.read_bytes()
    if plausible(data) and (data.startswith(b"\x7fELF") or data[56:60] == b"ARM\x64"):
        return data
    formats = (
        b"\x1f\x8b\x08",
        b"\xfd7zXZ\x00",
        b"BZh",
        b"\x5d\x00\x00",
        b"\x28\xb5\x2f\xfd",
        b"\x02\x21\x4c\x18",
    )
    for kind in formats:
        start = 0
        while True:
            offset = data.find(kind, start)
            if offset < 0:
                break
            start = offset + 1
            try:
                output = decompress_at(data, offset, kind)
            except (
                OSError,
                RuntimeError,
                ValueError,
                EOFError,
                zlib.error,
                lzma.LZMAError,
                subprocess.CalledProcessError,
            ):
                continue
            if plausible(output):
                return output
    raise RuntimeError(f"Could not extract an uncompressed Linux kernel from {source}.")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: extract_vmlinux.py <vmlinuz> <output>")
    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    output = extract(source)
    destination.write_bytes(output)
    if output.startswith(b"\x7fELF") and len(output) >= 20:
        machine = struct.unpack_from("<H", output, 18)[0]
        print(f"Wrote uncompressed ELF kernel; machine={machine}, size={len(output)}")
    else:
        print(f"Wrote uncompressed kernel; size={len(output)}")


if __name__ == "__main__":
    main()
