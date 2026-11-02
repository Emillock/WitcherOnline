"""Tests for the bundle reader and for the vanilla board extraction command."""
import hashlib
import struct
import zlib
from pathlib import Path

import pytest

import build
import bundle

V5_ENTRY = 0x130
V3_ENTRY = 0x140


def _name_field(name: str) -> bytearray:
    entry = bytearray(0x140)
    entry[: len(name)] = name.encode("latin-1")
    return entry


def _v5_entry(name: str, size: int, csize: int, offset: int) -> bytes:
    entry = _name_field(name)[:V5_ENTRY]
    struct.pack_into("<QII", entry, 0x110, offset, size, csize)
    return bytes(entry)


def _v3_entry(name: str, size: int, csize: int, offset: int, comp: int) -> bytes:
    entry = _name_field(name)
    struct.pack_into("<III", entry, 0x114, size, csize, offset)
    struct.pack_into("<I", entry, 0x13C, comp)
    return bytes(entry)


def _bundle(version: int, table: bytes, payload: bytes) -> bytes:
    head = bytearray(0x20)
    head[:8] = b"POTATO70"
    struct.pack_into("<I", head, 0x10, len(table))
    struct.pack_into("<H", head, 0x14, version)
    return bytes(head) + table + payload


def _lz4_literals(data: bytes) -> bytes:
    """A valid LZ4 block that holds the data as one literal run."""
    n = len(data)
    out = bytearray([min(n, 15) << 4])
    if n >= 15:
        rest = n - 15
        while rest >= 255:
            out.append(255)
            rest -= 255
        out.append(rest)
    return bytes(out) + data


def _write_v5(path: Path, name: str, content: bytes, compress: bool) -> None:
    payload = zlib.compress(content) if compress else content
    offset = 0x20 + V5_ENTRY
    table = _v5_entry(name, len(content), len(payload), offset)
    path.write_bytes(_bundle(5, table, payload))


def test_entries_reads_v5_and_v3(tmp_path: Path) -> None:
    v5 = tmp_path / "v5.bundle"
    _write_v5(v5, "gameplay\\a.bin", b"x" * 100, compress=True)
    [e5] = list(bundle.entries(v5))
    assert e5.name == "gameplay\\a.bin"
    assert e5.size == 100
    assert e5.csize == len(zlib.compress(b"x" * 100))
    assert e5.offset == 0x20 + V5_ENTRY
    assert e5.comp == 1

    payload = _lz4_literals(b"hello bundle v3")
    offset = 0x20 + V3_ENTRY
    table = _v3_entry("gameplay\\b.bin", 15, len(payload), offset, comp=4)
    v3 = tmp_path / "v3.bundle"
    v3.write_bytes(_bundle(3, table, payload))
    [e3] = list(bundle.entries(v3))
    assert (e3.name, e3.size, e3.csize, e3.offset, e3.comp) == (
        "gameplay\\b.bin", 15, len(payload), offset, 4)


def test_extract_v5_zlib_and_stored(tmp_path: Path) -> None:
    content = bytes(range(256)) * 8
    for compress in (True, False):
        path = tmp_path / f"v5_{compress}.bundle"
        _write_v5(path, "dir\\file.bin", content, compress)
        assert bundle.extract(path, "dir\\file.bin") == content
        assert bundle.extract(path, "DIR/File.BIN") == content


def test_extract_v3_lz4(tmp_path: Path) -> None:
    content = b"A" * 40
    payload = _lz4_literals(content)
    table = _v3_entry("f.bin", len(content), len(payload), 0x20 + V3_ENTRY, comp=5)
    path = tmp_path / "v3.bundle"
    path.write_bytes(_bundle(3, table, payload))
    assert bundle.extract(path, "f.bin") == content


def test_lz4_block_with_match() -> None:
    # literal "ab", then a match of offset 2 and length 6, which gives "abababab"
    block = bytes([0x22, ord("a"), ord("b"), 0x02, 0x00])
    assert bundle.lz4_block(block, 8) == b"abababab"


def test_extract_missing_entry_raises(tmp_path: Path) -> None:
    path = tmp_path / "v5.bundle"
    _write_v5(path, "a.bin", b"data", compress=False)
    with pytest.raises(bundle.BundleError):
        bundle.extract(path, "missing.bin")


def test_entries_rejects_non_bundle(tmp_path: Path) -> None:
    path = tmp_path / "junk.bundle"
    path.write_bytes(b"NOTABUNDLE" + bytes(64))
    with pytest.raises(bundle.BundleError):
        list(bundle.entries(path))


def test_known_board_hash() -> None:
    assert build.KNOWN_BOARDS["5.0.0.1048522"] == (
        "aeb1255be5a4d218bf41a7630dd27e4b25b32936c0f06055fa77e7aec4d5664e")


def _fake_game(tmp_path: Path, board: bytes) -> Path:
    game = tmp_path / "game"
    bundles = game / "content" / "content0" / "bundles"
    bundles.mkdir(parents=True)
    _write_v5(bundles / "r4gui.bundle", build.BOARD_ENTRY, board, compress=True)
    return game


def test_vanilla_refuses_unknown_board(tmp_path: Path) -> None:
    game = _fake_game(tmp_path, b"some other board")
    out = tmp_path / "work" / "vanilla.redswf"
    assert build.main(["vanilla", "--game", str(game), "--out", str(out)]) == 1
    assert not out.exists()


def test_vanilla_allow_unknown_board_writes_file(tmp_path: Path) -> None:
    board = b"some other board"
    game = _fake_game(tmp_path, board)
    out = tmp_path / "work" / "vanilla.redswf"
    code = build.main(["vanilla", "--game", str(game), "--out", str(out),
                       "--allow-unknown-board"])
    assert code == 0
    assert out.read_bytes() == board


def test_vanilla_accepts_known_board(tmp_path: Path, monkeypatch) -> None:
    board = b"pretend vanilla board"
    monkeypatch.setitem(build.KNOWN_BOARDS, "test", hashlib.sha256(board).hexdigest())
    game = _fake_game(tmp_path, board)
    out = tmp_path / "work" / "vanilla.redswf"
    assert build.main(["vanilla", "--game", str(game), "--out", str(out)]) == 0
    assert out.read_bytes() == board
