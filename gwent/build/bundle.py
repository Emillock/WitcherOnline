"""Reader for Witcher 3 POTATO70 bundles (4.x and 5.x layouts), writer for 4.x bundles.

Layout, all little endian:
  0x00  "POTATO70"
  0x10  u32 size of the entry table
  0x14  u16 bundle version (5 for the 5.x game, otherwise the 4.x layout)
  0x20  entry table

4.x entries are 0x140 bytes: name at 0x00 (0x100 bytes, NUL padded), size, csize
and offset as u32 at 0x114, and a compression type u32 at 0x13C (0 stored,
1 zlib, 4 or 5 raw LZ4 block). The u32 at 0x138 is the CRC32 of the uncompressed payload.
5.x entries are 0x130 bytes: name at 0x00, a u64 offset at 0x110 followed by
u32 size and u32 csize, zlib whenever size differs from csize.
"""
import dataclasses
import re
import struct
import zlib
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
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

DATA_ALIGN = 4096
V3_HEADER_TAIL = bytes.fromhex("030001000013131313131313")


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


def _align(n: int, to: int = DATA_ALIGN) -> int:
    return (n + to - 1) // to * to


def write_v3(path: Path, files: Sequence[tuple[str, bytes]]) -> None:
    """Writes a 4.x bundle that stores every file uncompressed (compression type 0).

    Every file starts on a 4096 byte boundary, the first one on the first
    boundary after the entry table. Header offset 0x08 holds the end of the data
    rounded up to 4096, as in bundles from the game's own tools; the file itself
    is not padded at the end.
    """
    table = bytearray()
    placed: list[tuple[int, bytes]] = []
    end = HEADER_SIZE + V3_ENTRY_SIZE * len(files)
    offset = _align(end)
    for name, data in files:
        try:
            raw_name = name.encode("latin-1")
        except UnicodeEncodeError as exc:
            raise BundleError(f"{name}: entry names must be latin-1") from exc
        if len(raw_name) >= NAME_SIZE:
            raise BundleError(f"{name}: entry name is longer than {NAME_SIZE - 1} bytes")
        entry = bytearray(V3_ENTRY_SIZE)
        entry[:len(raw_name)] = raw_name
        struct.pack_into("<III", entry, 0x114, len(data), len(data), offset)
        struct.pack_into("<II", entry, 0x138, zlib.crc32(data), COMP_STORED)
        table += entry
        placed.append((offset, data))
        end = offset + len(data)
        offset = _align(end)
    out = bytearray(MAGIC)
    out += struct.pack("<III", _align(end), 0, len(table)) + V3_HEADER_TAIL + table
    for at, data in placed:
        out += bytes(at - len(out))
        out += data
    Path(path).write_bytes(out)


MS_MAGIC = b"\x03VTM"
MS_VERSION = 6
MS_LOC_SIZE = 20
MS_BUNDLE_SIZE = 24
_FNV_OFFSET = 0xCBF29CE484222325
_FNV_PRIME = 0x100000001B3
_U64 = (1 << 64) - 1
_BUFFER_NAME = re.compile(r"^(.+)\.(\d+)\.buffer$", re.IGNORECASE)


def path_hash(path: str) -> int:
    """Returns the 64 bit FNV-1a hash metadata.store keys a file path by (lower case, latin-1)."""
    h = _FNV_OFFSET
    for byte in path.lower().encode("latin-1"):
        h = ((h ^ byte) * _FNV_PRIME) & _U64
    return h


@dataclass(frozen=True)
class MetaBundle:
    """One bundle file of a mod: its name, the files it holds and where its header chunk sits."""

    name: str
    first_file: int
    file_count: int
    offset: int
    size: int


@dataclass(frozen=True)
class MetaFile:
    """One file of a mod. index is 1 based and follows data order across the bundles."""

    path: str
    csize: int
    size: int
    index: int
    comp: int
    bundle: int
    offset: int
    buffer_start: int
    buffer_count: int


@dataclass(frozen=True)
class Metadata:
    """Content of a metadata.store (format version 6).

    The tables a loader needs to find a file by path (directory tree, file name
    entries, path hashes) follow from files, so encode rebuilds them and they are
    not stored here. Bundle numbers in MetaFile are 1 based; bundle 1 is the one
    whose files are listed by path, later bundles only hold the .N.buffer files
    that belong to a file of bundle 1. buffers lists those buffer files by index,
    grouped per owner as buffer_start and buffer_count say. reserved is the tail of
    the all-zero record 0, which the original tool left as uninitialised memory.
    """

    version: int
    biggest_csize: int
    biggest_size: int
    bundles: tuple[MetaBundle, ...]
    files: tuple[MetaFile, ...]
    buffers: tuple[int, ...]
    reserved: int = 0

    def encode(self) -> bytes:
        """Serialises to the bytes of a metadata.store file."""
        return _encode_metadata(self)


def _vlq(value: int) -> bytes:
    """Encodes a count the way metadata.store does (6 bit first byte, then 7 bit groups).

    An empty table is written as 0x80 (a negative zero), as the game's tools do.
    """
    if value == 0:
        return b"\x80"
    out = bytearray()
    first, rest = value & 0x3F, value >> 6
    out.append(first | (0x40 if rest else 0))
    while rest:
        byte, rest = rest & 0x7F, rest >> 7
        out.append(byte | (0x80 if rest else 0))
    return bytes(out)


class _StringTable:
    """NUL terminated strings, with a leading NUL so that offset 0 is the empty string."""

    def __init__(self) -> None:
        self.data = bytearray(b"\0")

    def add(self, text: str) -> int:
        offset = len(self.data)
        self.data += text.encode("latin-1") + b"\0"
        return offset


def _directory_tree(paths: list[str]) -> tuple[list[tuple[str, int]], list[int]]:
    """Builds the folder table for the given file paths.

    Returns the folders as (name, parent number) in depth first order, children
    of a folder ordered by their first file, plus the folder number of every
    path. Folder numbers are 1 based, 0 is the root.
    """
    children: dict[tuple[str, ...], list[tuple[str, ...]]] = {(): []}
    for path in paths:
        parts = tuple(path.split("\\")[:-1])
        for depth in range(1, len(parts) + 1):
            node = parts[:depth]
            if node not in children:
                children[node] = []
                children[node[:-1]].append(node)
    numbers: dict[tuple[str, ...], int] = {(): 0}
    folders: list[tuple[str, int]] = []

    def walk(node: tuple[str, ...]) -> None:
        for child in children[node]:
            folders.append((child[-1], numbers[node]))
            numbers[child] = len(folders)
            walk(child)

    walk(())
    return folders, [numbers[tuple(p.split("\\")[:-1])] for p in paths]


def _encode_metadata(meta: Metadata) -> bytes:
    for position, file in enumerate(meta.files, 1):
        if file.index != position:
            raise BundleError(f"{file.path}: file index {file.index} is not its position {position}")
    strings = _StringTable()
    bundle_name = [0]
    file_path = [0]
    for number, bun in enumerate(meta.bundles, 1):
        bundle_name.append(strings.add(bun.name))
        file_path += [strings.add(f.path) for f in meta.files if f.bundle == number]
    root = strings.add("")
    folders, folder_of = _directory_tree([f.path for f in meta.files if f.bundle == 1])
    dirs = [(root, 0)] + [(strings.add(name), parent) for name, parent in folders]
    names = []
    for file in (f for f in meta.files if f.bundle == 1):
        leaf = file.path.rsplit("\\", 1)[-1]
        names.append((file.index, folder_of[file.index - 1], file_path[file.index] + len(file.path) - len(leaf)))
    hashes = sorted((path_hash(f.path), f.index) for f in meta.files if f.bundle == 1)

    out = bytearray(MS_MAGIC)
    out += struct.pack("<III", meta.version, meta.biggest_csize, meta.biggest_size)
    out += _vlq(len(strings.data)) + strings.data
    out += _vlq(len(meta.files) + 1)
    out += struct.pack("<QIIIIQ", 0, 0, 0, 0, 0, meta.reserved)
    for f in meta.files:
        buffers = f.buffer_start | (f.buffer_count << 32) if f.buffer_count else 0
        out += struct.pack("<QIIIIQ", file_path[f.index], f.csize, f.size, f.index, f.comp, buffers)
    out += _vlq(len(meta.files) + 1) + bytes(MS_LOC_SIZE)
    for f in meta.files:
        out += struct.pack("<5I", f.index, f.bundle, f.offset, f.csize, 0)
    out += _vlq(len(meta.bundles) + 1) + bytes(MS_BUNDLE_SIZE)
    for number, bun in enumerate(meta.bundles, 1):
        out += struct.pack(
            "<6I", bundle_name[number], bun.first_file, bun.file_count, bun.offset, bun.size, 0
        )
    out += _vlq(len(meta.buffers)) + struct.pack(f"<{len(meta.buffers)}I", *meta.buffers)
    out += _vlq(len(dirs)) + b"".join(struct.pack("<II", *d) for d in dirs)
    out += _vlq(len(names)) + b"".join(struct.pack("<III", *n) for n in names)
    out += _vlq(len(hashes)) + b"".join(struct.pack("<QQ", *h) for h in hashes)
    return bytes(out)


class _Reader:
    """Cursor over the bytes of a metadata.store."""

    def __init__(self, data: bytes, origin: str) -> None:
        self.data, self.pos, self.origin = data, 0, origin

    def take(self, n: int) -> bytes:
        if self.pos + n > len(self.data):
            raise BundleError(f"{self.origin}: metadata.store ends early")
        chunk = self.data[self.pos:self.pos + n]
        self.pos += n
        return chunk

    def unpack(self, fmt: str) -> tuple[int, ...]:
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))

    def vlq(self) -> int:
        byte = self.take(1)[0]
        value, shift, negative = byte & 0x3F, 6, bool(byte & 0x80)
        more = bool(byte & 0x40)
        while more:
            byte = self.take(1)[0]
            value |= (byte & 0x7F) << shift
            shift += 7
            more = bool(byte & 0x80)
        return -value if negative else value

    def table(self, fmt: str) -> list[tuple[int, ...]]:
        return [self.unpack(fmt) for _ in range(self.vlq())]


def read_metadata(path: Path) -> Metadata:
    """Parses a metadata.store; raises BundleError when it is not a version 6 file."""
    reader = _Reader(Path(path).read_bytes(), str(path))
    if reader.take(4) != MS_MAGIC:
        raise BundleError(f"{path}: not a metadata.store")
    version, biggest_csize, biggest_size = reader.unpack("<III")
    if version != MS_VERSION:
        raise BundleError(f"{path}: metadata.store version {version} is not supported")
    strings = reader.take(reader.vlq())

    def text(offset: int) -> str:
        return strings[offset:strings.index(b"\0", offset)].decode("latin-1")

    records = reader.table("<QIIIIQ")
    locs = reader.table("<5I")
    bundle_rows = reader.table("<6I")
    buffers = tuple(value for (value,) in reader.table("<I"))
    reader.table("<II")
    reader.table("<III")
    reader.table("<QQ")
    if reader.pos != len(reader.data):
        raise BundleError(f"{path}: {len(reader.data) - reader.pos} bytes after the last table")
    if len(records) != len(locs) or not records:
        raise BundleError(f"{path}: file and location tables differ in length")
    files = []
    for position, (record, loc) in enumerate(zip(records[1:], locs[1:]), 1):
        offset, csize, size, index, comp, buffer_ref = record
        if index != position or loc[0] != position:
            raise BundleError(f"{path}: file {position} is numbered {index}")
        files.append(
            MetaFile(
                text(offset), csize, size, index, comp, loc[1], loc[2],
                buffer_ref & 0xFFFFFFFF, buffer_ref >> 32,
            )
        )
    bundles = tuple(
        MetaBundle(text(name), first, count, offset, size)
        for name, first, count, offset, size, _ in bundle_rows[1:]
    )
    return Metadata(
        version, biggest_csize, biggest_size, bundles, tuple(files), buffers, records[0][5]
    )


def _owner_buffers(files: list[MetaFile]) -> tuple[list[MetaFile], tuple[int, ...]]:
    """Links every file of the later bundles to the file of bundle 1 it is a .N.buffer of."""
    owners = {f.path.lower(): f for f in files if f.bundle == 1}
    grouped: dict[int, list[tuple[int, int]]] = {}
    for file in files:
        if file.bundle == 1:
            continue
        found = _BUFFER_NAME.match(file.path)
        owner = owners.get(found.group(1).lower()) if found else None
        if found is None or owner is None:
            raise BundleError(f"{file.path}: not a .N.buffer of a file in the first bundle")
        grouped.setdefault(owner.index, []).append((int(found.group(2)), file.index))
    buffers: list[int] = []
    for owner_index in sorted(grouped):
        ordered = [index for _, index in sorted(grouped[owner_index])]
        files[owner_index - 1] = dataclasses.replace(
            files[owner_index - 1], buffer_start=len(buffers), buffer_count=len(ordered)
        )
        buffers += ordered
    return files, tuple(buffers)


def build_metadata(bundles: Sequence[Path]) -> Metadata:
    """Describes the given 4.x bundles (the first one holds the real files) as a Metadata.

    The header chunk (32 byte header plus entry table) of the first bundle is
    recorded as ending at the rounded up size of the bundle, in later bundles as
    ending at the first 4096 byte boundary after it.
    """
    files: list[MetaFile] = []
    rows: list[MetaBundle] = []
    for number, path in enumerate(bundles, 1):
        with open(path, "rb") as f:
            head = f.read(HEADER_SIZE)
        if head[:8] != MAGIC:
            raise BundleError(f"{path}: not a POTATO70 bundle")
        rounded, _, table_size = struct.unpack_from("<III", head, 8)
        if struct.unpack_from("<H", head, 0x14)[0] == V5_VERSION:
            raise BundleError(f"{path}: metadata.store for 5.x bundles is not supported")
        chunk = HEADER_SIZE + table_size
        offset = rounded - chunk if number == 1 else _align(chunk) - chunk
        found = sorted(entries(path), key=lambda e: e.offset)
        rows.append(MetaBundle(Path(path).name, len(files) + 1, len(found), offset, chunk))
        for e in found:
            files.append(
                MetaFile(e.name, e.csize, e.size, len(files) + 1, e.comp, number, e.offset, 0, 0)
            )
    files, buffers = _owner_buffers(files)
    return Metadata(
        MS_VERSION,
        max((f.csize for f in files), default=0),
        max((f.size for f in files), default=0),
        tuple(rows),
        tuple(files),
        buffers,
    )


def write_metadata(path: Path, bundles: Sequence[Path]) -> None:
    """Writes the metadata.store that describes the given bundles (first one holds the files)."""
    Path(path).write_bytes(build_metadata(bundles).encode())
