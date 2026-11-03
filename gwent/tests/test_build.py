"""Tests for the build pipeline: the diff command and the real end to end build with our classes."""
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
DUEL_CLASSES = sorted(path.stem for path in (GWENT_DIR / "src").glob("Duel*.as"))


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
def test_build_lists_duel_classes(tmp_path: Path) -> None:
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
    assert len(DUEL_CLASSES) >= 10
    assert [name for name in DUEL_CLASSES if f"{PACKAGE}.{name}" not in classes] == []
    assert f"{PACKAGE}.CardTransaction" in classes
    assert f"{PACKAGE}.NetOpponentController" in classes
    decompiled = tmp_path / "decompiled"
    ffdec.export_scripts(swf, decompiled)
    menu = (decompiled / "red" / "game" / "witcher3" / "menus" / "gwint" / "GwintGameMenu.as").read_text()
    assert '"gwint.game.debug.selfTest"' in menu and "DuelSelfTest.start" in menu
    assert "DuelProbe" not in menu
    for key in ("seed", "isHost", "isTimed", "opponentLeft", "remoteInput", "debug.autoplay", "debug.mulligan",
                "debug.leaderFirst", "debug.corruptAt", "debug.forceDraw", "debug.breakTemplates"):
        assert f'"gwint.game.{key}"' in menu
    gwint = decompiled / "red" / "game" / "witcher3" / "menus" / "gwint"
    assert "DuelSession.active.update()" in (gwint / "GwintGameFlowController.as").read_text()
    assert "ids.assign(" in (gwint / "CardManager.as").read_text()
    assert "DuelSession.randomInt(" in (gwint / "GwintDeck.as").read_text()
    assert "duelPlaceResurrected" in (gwint / "CardInstance.as").read_text()
    assert "DuelSession.randomInt(" in (gwint / "CardLeaderInstance.as").read_text()
    human = (gwint / "HumanPlayerController.as").read_text()
    assert "ALWAYS_PASS" not in human and "sendMove(" in human
    assert "ShowingMove" in (gwint / "NetOpponentController.as").read_text()
    assert "DUEL DESYNC seq=" in (gwint / "DuelSession.as").read_text()
    assert "DUEL DECIDE " in (gwint / "DuelSession.as").read_text()
    assert "duelDecideNurse" in (gwint / "CardInstance.as").read_text()
    assert "duelDecide" in (gwint / "CardLeaderInstance.as").read_text()
    flow = (gwint / "GwintGameFlowController.as").read_text()
    assert "duelScoiataelToss" in flow and "duelApplyRemoteRedraw" in flow
    assert "duelCoinChosen" in menu
    assert "function onQuitConfirmed" in menu and "stopDuelTimer" in menu
