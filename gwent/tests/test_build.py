"""Tests for the build pipeline: the diff command and the real end to end probe build."""
import os
import subprocess
import sys
from pathlib import Path

import pytest

import build
import bundle
import ffdec
import redswf

GWENT_DIR = Path(__file__).resolve().parent.parent
GAME_DIR = Path(os.environ.get(
    "WITCHER3_GAME_DIR", r"C:\Program Files (x86)\GOG Galaxy\Games\The Witcher 3 Wild Hunt GOTY"))
MOVIE_VERSION = 12
PACKAGE = "red.game.witcher3.menus.gwint"


def test_diff_rewrites_prefixes_so_git_apply_works(tmp_path: Path) -> None:
    work = tmp_path / "work"
    patch_dir = tmp_path / "patches"
    (work / "vanilla" / "pkg").mkdir(parents=True)
    (work / "edit" / "pkg").mkdir(parents=True)
    (work / "vanilla" / "pkg" / "Same.as").write_text("same\n", newline="\n")
    (work / "edit" / "pkg" / "Same.as").write_text("same\n", newline="\n")
    (work / "vanilla" / "pkg" / "A.as").write_text("one\ntwo\nthree\n", newline="\n")
    (work / "edit" / "pkg" / "A.as").write_text("one\ntwo\nPING\nthree\n", newline="\n")
    assert build.write_patches(work / "vanilla", work / "edit", patch_dir) == ["A.patch"]
    text = (patch_dir / "A.patch").read_text()
    assert "a/pkg/A.as" in text and "b/pkg/A.as" in text and "vanilla" not in text
    target = tmp_path / "target"
    (target / "pkg").mkdir(parents=True)
    (target / "pkg" / "A.as").write_text("one\ntwo\nthree\n", newline="\n")
    build.apply_patches(target, patch_dir)
    assert (target / "pkg" / "A.as").read_text() == "one\ntwo\nPING\nthree\n"


def test_diff_removes_stale_patches(tmp_path: Path) -> None:
    (tmp_path / "vanilla").mkdir()
    (tmp_path / "edit").mkdir()
    (tmp_path / "vanilla" / "A.as").write_text("x\n", newline="\n")
    (tmp_path / "edit" / "A.as").write_text("x\n", newline="\n")
    patch_dir = tmp_path / "patches"
    patch_dir.mkdir()
    (patch_dir / "Gone.patch").write_text("stale")
    assert build.write_patches(tmp_path / "vanilla", tmp_path / "edit", patch_dir) == []
    assert not (patch_dir / "Gone.patch").exists()


@pytest.mark.slow
@pytest.mark.skipif(not (GAME_DIR / build.GUI_BUNDLE).is_file(), reason="game folder not found")
def test_build_lists_probe_class(tmp_path: Path) -> None:
    out = tmp_path / "out"
    work = tmp_path / "w"
    subprocess.run(
        [sys.executable, str(GWENT_DIR / "build" / "build.py"), "build",
         "--game", str(GAME_DIR), "--out", str(out), "--work", str(work)],
        check=True)
    content = out / "modWitcherOnline" / "content"
    assert (content / "metadata.store").is_file()
    board = bundle.extract(content / "blob0.bundle", build.BOARD_ENTRY)
    redswf.check_consistency(board)
    movie = redswf.read_movie(board)
    assert board[movie.blob_offset:movie.blob_offset + 3] == b"CFX"
    assert movie.version == MOVIE_VERSION
    swf = tmp_path / "result.swf"
    swf.write_bytes(redswf.read_movie(board).fws)
    classes = ffdec.dump_as3(swf)
    assert f"{PACKAGE}.DuelProbe" in classes
    assert f"{PACKAGE}.CardTransaction" in classes
    decompiled = tmp_path / "decompiled"
    ffdec.export_scripts(swf, decompiled)
    menu = (decompiled / "red" / "game" / "witcher3" / "menus" / "gwint" / "GwintGameMenu.as").read_text()
    assert "DuelProbe.ping" in menu
