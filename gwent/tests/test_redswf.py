"""Tests for gwent/build/redswf.py against the real vanilla board in gwent/work/vanilla.redswf."""
import struct
import zlib
from pathlib import Path

import pytest

import redswf

VANILLA = Path(__file__).resolve().parent.parent / "work" / "vanilla.redswf"

pytestmark = pytest.mark.skipif(not VANILLA.exists(), reason="gwent/work/vanilla.redswf is absent")

VANILLA_SIZE = 12284472
MOVIE_LENGTH = 6490511
MOVIE_BLOB_OFFSET = 0x35B
MOVIE_BLOB_LENGTH = 4573062
HEADER_CRC_PLACEHOLDER = 0xDEADBEEF


@pytest.fixture(scope="module")
def data() -> bytes:
    return VANILLA.read_bytes()


def u32(buf: bytes, offset: int) -> int:
    return struct.unpack_from("<I", buf, offset)[0]


def vanilla_blob(data: bytes) -> bytes:
    return data[MOVIE_BLOB_OFFSET:MOVIE_BLOB_OFFSET + MOVIE_BLOB_LENGTH]


def test_read_movie(data):
    movie = redswf.read_movie(data)
    assert len(movie.fws) == MOVIE_LENGTH
    assert movie.fws[:3] == b"FWS"
    assert movie.version == 12
    assert movie.fws[3] == 12
    assert u32(movie.fws, 4) == MOVIE_LENGTH
    assert movie.blob_offset == MOVIE_BLOB_OFFSET


def test_vanilla_cr2w_header_fields(data):
    """Pins the v164 header layout the rewrite relies on, field by field."""
    assert data[:4] == b"CR2W"
    assert u32(data, 0x04) == 164
    assert u32(data, 0x18) == VANILLA_SIZE
    assert u32(data, 0x1C) == VANILLA_SIZE
    placeholder = struct.pack("<I", HEADER_CRC_PLACEHOLDER)
    assert u32(data, 0x20) == zlib.crc32(data[:0x20] + placeholder + data[0x24:0xA0])
    header = redswf.parse_header(data)
    assert header.file_size == VANILLA_SIZE
    assert len(header.exports) == 10
    first, last = header.exports[0], header.exports[-1]
    assert first.data_offset == 0x303
    assert first.data_offset <= MOVIE_BLOB_OFFSET - 4
    assert MOVIE_BLOB_OFFSET + MOVIE_BLOB_LENGTH <= first.data_offset + first.data_size
    assert u32(data, MOVIE_BLOB_OFFSET - 4) == MOVIE_BLOB_LENGTH
    assert last.data_offset + last.data_size == VANILLA_SIZE


def test_vanilla_is_consistent(data):
    redswf.check_consistency(data)


def test_rewrap_roundtrip_identity(data):
    assert redswf.rewrap_raw(data, vanilla_blob(data)) == data


@pytest.mark.parametrize("delta", [-7, 1000])
def test_rewrap_raw_grows_and_shrinks(data, delta):
    blob = vanilla_blob(data)
    resized = blob[:delta] if delta < 0 else blob + bytes(delta)
    out = redswf.rewrap_raw(data, resized)
    assert len(out) == len(data) + delta
    redswf.check_consistency(out)


def test_rewrap_changed_movie(data):
    movie = redswf.read_movie(data)
    position = movie.fws.index(b"GwintCard")
    changed = bytearray(movie.fws)
    changed[position + 8] = ord("X")
    fws2 = bytes(changed)
    assert fws2 != movie.fws

    out = redswf.rewrap(data, fws2)
    assert len(out) != len(data)
    assert redswf.read_movie(out).fws == fws2
    assert redswf.read_movie(out).version == 12

    header = redswf.parse_header(out)
    assert header.file_size == len(out)
    assert header.buffer_size == len(out)
    assert header.exports[-1].data_offset + header.exports[-1].data_size == len(out)
    redswf.check_consistency(out)

    blob = out[MOVIE_BLOB_OFFSET:]
    assert blob[:3] == b"CFX"
    assert blob[3] == 12
    assert u32(blob, 4) == MOVIE_LENGTH
    assert blob[8:10] == b"\x78\xda"

    assert out.endswith(data[MOVIE_BLOB_OFFSET + MOVIE_BLOB_LENGTH:])


def test_rewrap_unchanged_movie_is_valid(data):
    movie = redswf.read_movie(data)
    out = redswf.rewrap(data, movie.fws)
    assert redswf.read_movie(out).fws == movie.fws
    redswf.check_consistency(out)


def test_rewrap_rejects_wrong_declared_length(data):
    movie = redswf.read_movie(data)
    with pytest.raises(redswf.RedswfError):
        redswf.rewrap(data, movie.fws + b"\x00")


def test_rewrap_rejects_non_fws(data):
    with pytest.raises(redswf.RedswfError):
        redswf.rewrap(data, b"CWS" + bytes(20))


def test_read_movie_rejects_non_cr2w():
    with pytest.raises(redswf.RedswfError):
        redswf.read_movie(b"NOPE" + bytes(200))
