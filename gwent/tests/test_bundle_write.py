"""Tests for the mod bundle writer and the metadata.store reader and writer."""
import dataclasses
import os
import struct
import zlib
from pathlib import Path

import bundle
import pytest

REPO = Path(__file__).resolve().parents[2]
WO_CONTENT = REPO / "witcher" / "mods" / "modWitcherOnline" / "content"
GAME_DIR = Path(
    os.environ.get(
        "WITCHER3_DIR",
        r"C:\Program Files (x86)\GOG Galaxy\Games\The Witcher 3 Wild Hunt GOTY",
    )
)
BOARD = "gameplay\\gui_new\\swf\\gwint\\gwint_game.redswf"

# metadata.store offset of the 8 byte tail of the all-zero first file record. The
# original tool left uninitialised memory in its low four bytes (0x82..0x85 of the
# 332 byte file); no input the file is built from determines them.
RECORD0_PAD = slice(0x82, 0x86)


def test_write_v3_roundtrip(tmp_path: Path) -> None:
    data = bytes((i * 7 + 3) % 251 for i in range(1000))
    out = tmp_path / "blob0.bundle"
    bundle.write_v3(out, [(BOARD, data)])
    assert list(bundle.entries(out)) == [bundle.Entry(BOARD, 1000, 1000, 4096, 0)]
    assert bundle.extract(out, BOARD) == data


def test_write_v3_header_and_layout(tmp_path: Path) -> None:
    first, second = b"a" * 5000, b"b" * 10
    out = tmp_path / "x.bundle"
    bundle.write_v3(out, [("one.bin", first), ("dir\\two.bin", second)])
    raw = out.read_bytes()
    assert raw[:8] == b"POTATO70"
    assert struct.unpack_from("<III", raw, 8) == (16384, 0, 0x280)
    assert raw[0x14:0x20] == bytes.fromhex("030001000013131313131313")
    entries = list(bundle.entries(out))
    assert [e.offset for e in entries] == [4096, 12288]
    assert len(raw) == 12288 + 10
    assert raw[0x20 + 0x120:0x20 + 0x138] == bytes(24)
    assert bundle.extract(out, "DIR/two.bin") == second


def test_write_v3_crc_is_of_the_payload(tmp_path: Path) -> None:
    data = b"gwent" * 100
    out = tmp_path / "c.bundle"
    bundle.write_v3(out, [("a.bin", data)])
    raw = out.read_bytes()
    assert struct.unpack_from("<I", raw, 0x20 + 0x138)[0] == zlib.crc32(data)


def test_write_v3_rejects_long_names(tmp_path: Path) -> None:
    with pytest.raises(bundle.BundleError):
        bundle.write_v3(tmp_path / "x.bundle", [("a" * 256, b"")])


def test_metadata_reads_existing() -> None:
    meta = bundle.read_metadata(WO_CONTENT / "metadata.store")
    assert meta.version == 6
    assert meta.biggest_csize == 8079387
    assert meta.biggest_size == 12137908
    assert [b.name for b in meta.bundles] == ["blob0.bundle"]
    assert meta.bundles[0] == bundle.MetaBundle("blob0.bundle", 1, 1, 8085152, 352)
    assert meta.files == (
        bundle.MetaFile(BOARD, 8079387, 12137908, 1, 5, 1, 4096, 0, 0),
    )
    assert meta.buffers == ()


def test_metadata_store_roundtrips_exactly() -> None:
    raw = (WO_CONTENT / "metadata.store").read_bytes()
    assert len(raw) == 332
    meta = bundle.read_metadata(WO_CONTENT / "metadata.store")
    assert meta.encode() == raw


def test_name_hash_is_fnv1a_of_lowercase_path() -> None:
    assert bundle.path_hash("GamePlay\\GUI_new\\swf\\gwint\\gwint_game.redswf") == 0xFF4EDDE731E8A159


def test_metadata_reproduces_existing(tmp_path: Path) -> None:
    original = (WO_CONTENT / "metadata.store").read_bytes()
    out = tmp_path / "metadata.store"
    bundle.write_metadata(out, [WO_CONTENT / "blob0.bundle"])
    written = out.read_bytes()
    assert len(written) == len(original) == 332
    assert written[:0x82] == original[:0x82]
    assert written[0x86:] == original[0x86:]
    assert written[RECORD0_PAD] == bytes(4)
    assert original[RECORD0_PAD] != bytes(4)


def test_metadata_for_a_written_bundle(tmp_path: Path) -> None:
    data = b"swf!" * 250
    blob = tmp_path / "blob0.bundle"
    bundle.write_v3(blob, [(BOARD, data), ("strings.list", b"x" * 20)])
    store = tmp_path / "metadata.store"
    bundle.write_metadata(store, [blob])
    meta = bundle.read_metadata(store)
    assert meta.biggest_csize == meta.biggest_size == 1000
    assert [(f.path, f.size, f.csize, f.comp, f.offset) for f in meta.files] == [
        (BOARD, 1000, 1000, 0, 4096),
        ("strings.list", 20, 20, 0, 8192),
    ]
    assert meta.bundles[0].offset + meta.bundles[0].size == 12288


def test_metadata_numbers_files_in_data_order(tmp_path: Path) -> None:
    blob = tmp_path / "blob0.bundle"
    bundle.write_v3(blob, [("b\\two.bin", b"2" * 9), ("a\\one.bin", b"1" * 9)])
    store = tmp_path / "metadata.store"
    bundle.write_metadata(store, [blob])
    meta = bundle.read_metadata(store)
    assert [f.path for f in meta.files] == ["b\\two.bin", "a\\one.bin"]
    assert [f.index for f in meta.files] == [1, 2]
    assert meta.encode() == store.read_bytes()


def _content(*parts: str) -> Path:
    return GAME_DIR.joinpath(*parts, "content")


CHILLOUT = _content("dlc", "dlcChillOut")
COMMUNITY = _content("mods", "modCustomPlayerCharacters")


@pytest.mark.skipif(not CHILLOUT.exists(), reason="game folder not available")
def test_metadata_reproduces_a_two_bundle_dlc() -> None:
    """dlcChillOut has a blob and a buffers bundle: buffer ownership and bundle numbering."""
    original = CHILLOUT / "metadata.store"
    meta = bundle.read_metadata(original)
    assert meta.buffers == (35,)
    assert meta.encode() == original.read_bytes()
    rebuilt = bundle.build_metadata([CHILLOUT / b.name for b in meta.bundles])
    assert dataclasses.replace(rebuilt, reserved=meta.reserved) == meta


@pytest.mark.skipif(not COMMUNITY.exists(), reason="game folder not available")
def test_metadata_describes_a_community_mod_the_same_way() -> None:
    """That mod's tool also stores each file name a second time, so only the model is compared."""
    meta = bundle.read_metadata(COMMUNITY / "metadata.store")
    rebuilt = bundle.build_metadata([COMMUNITY / b.name for b in meta.bundles])
    assert rebuilt == meta
