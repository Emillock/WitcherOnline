"""Reader for Witcher 3 POTATO70 bundles (4.x and 5.x layouts).

Layout, all little endian:
  0x00  "POTATO70"
  0x10  u32 size of the entry table
  0x14  u16 bundle version (5 for the 5.x game, otherwise the 4.x layout)
  0x20  entry table

4.x entries are 0x140 bytes: name at 0x00 (0x100 bytes, NUL padded), size, csize
and offset as u32 at 0x114, and a compression type u32 at 0x13C (0 stored,
1 zlib, 4 or 5 raw LZ4 block).
5.x entries are 0x130 bytes: name at 0x00, a u64 offset at 0x110 followed by
u32 size and u32 csize, zlib whenever size differs from csize.
"""
import struct
import zlib
from collections.abc import Iterator
from pathlib import Path
from typing import NamedTuple

MAGIC = b"POTATO70"
HEADER_SIZE = 0x20
NAME_SIZE = 0x100
V5_VERSION = 5
V5_ENTRY_SIZE = 0x130
V3_ENTRY_SIZE = 0x140

COMP_STORED = 0
COMP_ZLIB = 1
COMP_LZ4 = (4, 5)


class BundleError(Exception):
    """A bundle is malformed or does not hold the requested entry."""


class Entry(NamedTuple):
    """One file of a bundle."""

    name: str
    size: int
    csize: int
    offset: int
    comp: int


def entries(path: Path) -> Iterator[Entry]:
    """Yields every named entry of the bundle at path."""
    with open(path, "rb") as f:
        head = f.read(HEADER_SIZE)
        if head[:8] != MAGIC:
            raise BundleError(f"{path}: not a POTATO70 bundle")
        table_size = struct.unpack_from("<I", head, 0x10)[0]
        version = struct.unpack_from("<H", head, 0x14)[0]
        table = f.read(table_size)
    is_v5 = version == V5_VERSION
    step = V5_ENTRY_SIZE if is_v5 else V3_ENTRY_SIZE
    for i in range(0, len(table) - step + 1, step):
        raw = table[i:i + step]
        name = raw[:NAME_SIZE].split(b"\0", 1)[0].decode("latin-1")
        if not name:
            continue
        if is_v5:
            offset, size, csize = struct.unpack_from("<QII", raw, 0x110)
            comp = COMP_STORED if size == csize else COMP_ZLIB
        else:
            size, csize, offset = struct.unpack_from("<III", raw, 0x114)
            comp = struct.unpack_from("<I", raw, 0x13C)[0]
        yield Entry(name, size, csize, offset, comp)


def _lz4_length(src: bytes, i: int, base: int) -> tuple[int, int]:
    """Reads the 255-run extension of an LZ4 length; returns (length, next index)."""
    if base != 15:
        return base, i
    while True:
        b = src[i]
        i += 1
        base += b
        if b != 255:
            return base, i


def lz4_block(src: bytes, size: int) -> bytes:
    """Decompresses one raw LZ4 block (no frame header) into exactly size bytes."""
    dst = bytearray()
    i, n = 0, len(src)
    try:
        while i < n:
            token = src[i]
            i += 1
            lit, i = _lz4_length(src, i, token >> 4)
            dst += src[i:i + lit]
            i += lit
            if i >= n:
                break
            back = src[i] | (src[i + 1] << 8)
            i += 2
            match, i = _lz4_length(src, i, token & 15)
            match += 4
            start = len(dst) - back
            if back == 0 or start < 0:
                raise BundleError("lz4: match offset outside the output")
            if back >= match:
                dst += dst[start:start + match]
            else:
                for k in range(match):
                    dst.append(dst[start + k])
    except IndexError as exc:
        raise BundleError("lz4: truncated block") from exc
    if len(dst) != size:
        raise BundleError(f"lz4: got {len(dst)} bytes, expected {size}")
    return bytes(dst)


def decompress(raw: bytes, size: int, comp: int) -> bytes:
    """Returns the decompressed payload of one entry."""
    if comp == COMP_STORED or len(raw) == size:
        return raw
    if comp == COMP_ZLIB:
        try:
            data = zlib.decompress(raw)
        except zlib.error as exc:
            raise BundleError(f"zlib: {exc}") from exc
        if len(data) != size:
            raise BundleError(f"zlib: got {len(data)} bytes, expected {size}")
        return data
    if comp in COMP_LZ4:
        return lz4_block(raw, size)
    raise BundleError(f"compression type {comp} is not supported")


def _normalise(name: str) -> str:
    return name.replace("/", "\\").lower()


def extract(path: Path, name: str) -> bytes:
    """Returns the decompressed bytes of the entry called name (case and slash insensitive)."""
    want = _normalise(name)
    for entry in entries(path):
        if _normalise(entry.name) == want:
            with open(path, "rb") as f:
                f.seek(entry.offset)
                raw = f.read(entry.csize)
            if len(raw) != entry.csize:
                raise BundleError(f"{entry.name}: bundle ends before the entry does")
            return decompress(raw, entry.size, entry.comp)
    raise BundleError(f"{path}: entry {name} not found")
