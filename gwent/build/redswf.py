"""Extracts and re-wraps the Scaleform movie inside a Witcher 3 CR2W `.redswf` file.

A `.redswf` is a CR2W v164 container. Its first export (a CSwfResource object) holds the
movie as a u32 length followed by a "CFX" blob: magic, version byte, u32 uncompressed
length, then a zlib stream (CFX is Scaleform's counterpart of SWF "CWS"). The remaining
exports are textures and only move when the movie changes size.

CR2W header layout (little endian), confirmed against the vanilla 5.01 board:

    offset  size   meaning                          rewritten
    0x00    4      magic "CR2W"                     no
    0x04    4      version, 164                     no
    0x18    4      file size                        yes, += size delta
    0x1C    4      buffer size (equals file size)   yes, += size delta
    0x20    4      header CRC32                     yes, see below
    0x28    12*10  table headers (offset, count or byte size, CRC32) for tables 0..9
    0xA0           end of header, table data follows

Tables: 0 strings, 1 names, 3 imports, 4 exports; the rest are unused in this file. Only
the exports table changes. Table 4's header sits at 0x58 (offset, count 10, CRC32 at 0x60).
Each export entry is 24 bytes, struct `<HHIIIII`: class name index, object flags, parent id,
data size, data offset, template, data CRC32.

    field                                               rewritten
    table 4 CRC32 (header offset 0x60)                  yes, CRC32 of the exports table bytes
    export entry data size (entry +8)                   yes, movie export only
    export entry data offset (entry +12)                yes, every export after the movie
    export entry data CRC32 (entry +20)                 yes, movie export only
    u32 length prefix before the CFX blob               yes, the new blob length

Export data runs back to back, so the last export ends at the end of the file. The u32
prefix equals the blob length exactly (8 byte CFX header plus the zlib stream); four zero
bytes follow the blob inside the same export and are kept.

The header CRC32 is zlib.crc32 over bytes 0x00..0x9F with the CRC field itself replaced by
0xDEADBEEF (found by search; the identity test proves the computation on the vanilla file).
Every table and export CRC is a plain zlib.crc32 of its bytes. No other checksum exists in
the file.

The vanilla zlib stream decompresses to 1657 more bytes than the FWS header declares (the
movie's End tag sits exactly at the declared length), so `read_movie` truncates to the
declared length and `rewrap` writes exactly the declared length.

The Scaleform blob is compressed with zlib level 9 (the vanilla stream starts 78 DA, which
is level 9).
"""
import re
import struct
import zlib
from dataclasses import dataclass

CR2W_MAGIC = b"CR2W"
CR2W_VERSION = 164
HEADER_SIZE = 0xA0
FILE_SIZE_OFFSET = 0x18
BUFFER_SIZE_OFFSET = 0x1C
HEADER_CRC_OFFSET = 0x20
HEADER_CRC_PLACEHOLDER = 0xDEADBEEF
TABLES_OFFSET = 0x28
TABLE_HEADER_SIZE = 12
TABLE_CRC_FIELD = 8
TABLE_COUNT = 10
EXPORTS_TABLE = 4
UNUSED_TABLES_FROM = 5
EXPORT_SIZE = 24
EXPORT_STRUCT = struct.Struct("<HHIIIII")
EXPORT_DATA_SIZE_FIELD = 8
EXPORT_DATA_OFFSET_FIELD = 12
EXPORT_CRC_FIELD = 20

SCALEFORM_MAGIC = b"CFX"
FWS_MAGIC = b"FWS"
BLOB_HEADER_SIZE = 8
ZLIB_LEVEL = 9
U32 = struct.Struct("<I")
MAX_UINT32 = 0xFFFFFFFF


class RedswfError(Exception):
    """The input is not a `.redswf` this module understands, or a request is inconsistent."""


@dataclass(frozen=True)
class Table:
    """One CR2W table header: where the table starts, its count or byte size, its CRC32."""

    offset: int
    count: int
    crc: int


@dataclass(frozen=True)
class Export:
    """One CR2W export entry (an object stored in the file)."""

    class_name: int
    flags: int
    parent: int
    data_size: int
    data_offset: int
    template: int
    crc: int


@dataclass(frozen=True)
class Header:
    """The parts of the CR2W header this module reads and rewrites."""

    file_size: int
    buffer_size: int
    crc: int
    tables: tuple[Table, ...]
    exports: tuple[Export, ...]


@dataclass(frozen=True)
class Movie:
    """A decompressed Scaleform movie and where its blob sits in the container."""

    fws: bytes
    version: int
    blob_offset: int


@dataclass(frozen=True)
class _BlobLocation:
    """Position of the length-prefixed blob: its export, its offset and its stored length."""

    export_index: int
    offset: int
    length: int


def _u32(buf: bytes, offset: int) -> int:
    return U32.unpack_from(buf, offset)[0]


def parse_header(data: bytes) -> Header:
    """Parse the CR2W v164 header and exports table. Raises RedswfError if it is not one."""
    if len(data) < HEADER_SIZE or data[:4] != CR2W_MAGIC:
        raise RedswfError("not a CR2W file")
    version = _u32(data, 4)
    if version != CR2W_VERSION:
        raise RedswfError(f"unsupported CR2W version {version}, expected {CR2W_VERSION}")
    tables = tuple(
        Table(*struct.unpack_from("<III", data, TABLES_OFFSET + i * TABLE_HEADER_SIZE))
        for i in range(TABLE_COUNT)
    )
    exports_table = tables[EXPORTS_TABLE]
    end = exports_table.offset + exports_table.count * EXPORT_SIZE
    if exports_table.count == 0 or end > len(data):
        raise RedswfError("exports table is empty or outside the file")
    exports = tuple(
        Export(*EXPORT_STRUCT.unpack_from(data, exports_table.offset + i * EXPORT_SIZE))
        for i in range(exports_table.count)
    )
    return Header(
        file_size=_u32(data, FILE_SIZE_OFFSET),
        buffer_size=_u32(data, BUFFER_SIZE_OFFSET),
        crc=_u32(data, HEADER_CRC_OFFSET),
        tables=tables,
        exports=exports,
    )


def header_crc(data: bytes) -> int:
    """CRC32 of the first 0xA0 bytes with the CRC field set to the 0xDEADBEEF placeholder."""
    head = bytearray(data[:HEADER_SIZE])
    U32.pack_into(head, HEADER_CRC_OFFSET, HEADER_CRC_PLACEHOLDER)
    return zlib.crc32(bytes(head))


def check_consistency(data: bytes) -> None:
    """Verify every size, offset and CRC this module maintains. Raises RedswfError on a mismatch."""
    header = parse_header(data)
    if header.file_size != len(data) or header.buffer_size != len(data):
        raise RedswfError("file or buffer size does not match the file length")
    if header.crc != header_crc(data):
        raise RedswfError("header CRC mismatch")
    exports_table = header.tables[EXPORTS_TABLE]
    table_end = exports_table.offset + exports_table.count * EXPORT_SIZE
    if zlib.crc32(data[exports_table.offset:table_end]) != exports_table.crc:
        raise RedswfError("exports table CRC mismatch")
    cursor = header.exports[0].data_offset
    for index, export in enumerate(header.exports):
        if export.data_offset != cursor:
            raise RedswfError(f"export {index} is not contiguous with the previous one")
        body = data[cursor:cursor + export.data_size]
        if len(body) != export.data_size or zlib.crc32(body) != export.crc:
            raise RedswfError(f"export {index} data size or CRC mismatch")
        cursor += export.data_size
    if cursor != len(data):
        raise RedswfError("exports do not end at the end of the file")


def _inflate_blob(data: bytes, offset: int, length: int) -> tuple[bytes, int]:
    """Decompress the blob at `offset`; return (body, declared movie length)."""
    blob = data[offset:offset + length]
    if len(blob) != length or length <= BLOB_HEADER_SIZE or blob[:3] != SCALEFORM_MAGIC:
        raise RedswfError("movie blob is malformed")
    inflater = zlib.decompressobj()
    try:
        body = inflater.decompress(blob[BLOB_HEADER_SIZE:])
    except zlib.error as error:
        raise RedswfError(f"movie blob is not a zlib stream: {error}") from error
    if not inflater.eof or inflater.unused_data:
        raise RedswfError("movie blob zlib stream does not fill the blob")
    return body, _u32(blob, 4)


def _locate_blob(data: bytes, header: Header) -> _BlobLocation:
    """Find the length-prefixed CFX blob inside the export data."""
    for index, export in enumerate(header.exports):
        end = export.data_offset + export.data_size
        region = data[export.data_offset:end]
        for match in re.finditer(re.escape(SCALEFORM_MAGIC), region):
            offset = export.data_offset + match.start()
            if offset < export.data_offset + 4:
                continue
            length = _u32(data, offset - 4)
            if length <= BLOB_HEADER_SIZE or offset + length > end:
                continue
            try:
                _inflate_blob(data, offset, length)
            except RedswfError:
                continue
            return _BlobLocation(index, offset, length)
    raise RedswfError("no Scaleform movie found in the file")


def read_movie(data: bytes) -> Movie:
    """Extract the movie as an uncompressed FWS byte string, exactly its declared length."""
    header = parse_header(data)
    location = _locate_blob(data, header)
    body, declared = _inflate_blob(data, location.offset, location.length)
    if declared < BLOB_HEADER_SIZE or len(body) < declared - BLOB_HEADER_SIZE:
        raise RedswfError("movie body is shorter than its declared length")
    version = data[location.offset + 3]
    fws = FWS_MAGIC + bytes([version]) + U32.pack(declared) + body[:declared - BLOB_HEADER_SIZE]
    return Movie(fws=fws, version=version, blob_offset=location.offset)


def _patch_u32(buf: bytearray, offset: int, value: int) -> None:
    if not 0 <= value <= MAX_UINT32:
        raise RedswfError("a size or offset no longer fits in 32 bits")
    U32.pack_into(buf, offset, value)


def rewrap_raw(data: bytes, blob: bytes) -> bytes:
    """Replace the length-prefixed movie blob with `blob` as is and fix the CR2W bookkeeping.

    `blob` is the whole CFX blob (magic, version, length, zlib stream). Nothing is
    recompressed. Updated: the u32 blob length prefix, the movie export's data size and CRC,
    the data offset of every later export, the exports table CRC, the file and buffer sizes
    and the header CRC.
    """
    header = parse_header(data)
    for table in header.tables[UNUSED_TABLES_FROM:]:
        if table.count:
            raise RedswfError("files with buffer or embedded tables are not supported")
    location = _locate_blob(data, header)
    delta = len(blob) - location.length
    out = bytearray(data[:location.offset - 4])
    out += U32.pack(len(blob))
    out += blob
    out += data[location.offset + location.length:]

    exports_table = header.tables[EXPORTS_TABLE]
    movie_export = header.exports[location.export_index]
    for index, export in enumerate(header.exports):
        entry = exports_table.offset + index * EXPORT_SIZE
        if index == location.export_index:
            new_size = export.data_size + delta
            _patch_u32(out, entry + EXPORT_DATA_SIZE_FIELD, new_size)
            start = export.data_offset
            crc = zlib.crc32(bytes(out[start:start + new_size]))
            _patch_u32(out, entry + EXPORT_CRC_FIELD, crc)
        elif export.data_offset > movie_export.data_offset:
            _patch_u32(out, entry + EXPORT_DATA_OFFSET_FIELD, export.data_offset + delta)

    table_end = exports_table.offset + exports_table.count * EXPORT_SIZE
    crc_field = TABLES_OFFSET + EXPORTS_TABLE * TABLE_HEADER_SIZE + TABLE_CRC_FIELD
    _patch_u32(out, crc_field, zlib.crc32(bytes(out[exports_table.offset:table_end])))
    _patch_u32(out, FILE_SIZE_OFFSET, header.file_size + delta)
    _patch_u32(out, BUFFER_SIZE_OFFSET, header.buffer_size + delta)
    _patch_u32(out, HEADER_CRC_OFFSET, header_crc(bytes(out)))
    return bytes(out)


def rewrap(data: bytes, fws: bytes) -> bytes:
    """Put the uncompressed movie `fws` back into the container as a level 9 CFX blob.

    The FWS header's own length field must equal `len(fws)`.
    """
    if len(fws) < BLOB_HEADER_SIZE or fws[:3] != FWS_MAGIC:
        raise RedswfError("movie must start with the FWS magic")
    if _u32(fws, 4) != len(fws):
        raise RedswfError("movie header length does not match the movie size")
    compressed = zlib.compress(fws[BLOB_HEADER_SIZE:], ZLIB_LEVEL)
    blob = SCALEFORM_MAGIC + fws[3:BLOB_HEADER_SIZE] + compressed
    return rewrap_raw(data, blob)
