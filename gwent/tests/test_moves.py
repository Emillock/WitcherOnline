"""Move sync (spec 5, 8.4, 9.5, 10) against the patched board sources: the local commit points send their message
before the transaction applies, a pass sends S, the always-pass switch of Tasks 9 and 10 is gone, the opponent's moves
go through the vanilla ApplyingCard path, and a hash mismatch ends both sides through Y."""
import re
import shutil
from pathlib import Path

import pytest

import build

GWENT_DIR = Path(__file__).resolve().parent.parent
VANILLA = GWENT_DIR / "work" / "vanilla"
SRC = GWENT_DIR / "src"
PATCHES = GWENT_DIR / "patches"
GWINT = Path("red") / "game" / "witcher3" / "menus" / "gwint"

needs_vanilla = pytest.mark.skipif(not (VANILLA / GWINT).is_dir(),
                                   reason="no decompiled vanilla board (run build.py build first)")


@pytest.fixture(scope="module")
def board(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """The vanilla board with gwent/patches applied (the gwint package folder)."""
    target = tmp_path_factory.mktemp("board")
    shutil.copytree(VANILLA / "red", target / "red")
    build.apply_patches(target, PATCHES)
    return target / GWINT


def function_body(text: str, signature: str) -> str:
    """The body of the first function whose declaration contains `signature` (brace matched)."""
    start = text.index(signature)
    open_at = text.index("{", start)
    depth = 0
    for index in range(open_at, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:index + 1]
    raise AssertionError(f"unbalanced braces after {signature}")


def test_always_pass_is_gone() -> None:
    assert "ALWAYS_PASS" not in (SRC / "DuelSession.as").read_text(encoding="utf-8")
    for patch in PATCHES.glob("*.patch"):
        assert "ALWAYS_PASS" not in patch.read_text(encoding="utf-8"), patch.name


@needs_vanilla
def test_commit_sends_the_move_before_it_applies(board: Path) -> None:
    body = function_body((board / "HumanPlayerController.as").read_text(encoding="utf-8"),
                         "function commitTransaction(")
    assert "sendMove(" in body
    assert body.index("sendMove(") < body.index('ChangeState("ApplyingCard")')


@needs_vanilla
def test_the_three_commit_points_and_autoplay_use_commit(board: Path) -> None:
    text = (board / "HumanPlayerController.as").read_text(encoding="utf-8")
    assert len(re.findall(r"this\.commitTransaction\(", text)) >= 4
    assert text.count('_stateMachine.ChangeState("ApplyingCard")') == 1


@needs_vanilla
def test_a_pass_sends_s(board: Path) -> None:
    body = function_body((board / "HumanPlayerController.as").read_text(encoding="utf-8"),
                         "override public function skipTurn(")
    assert 'send("S"' in body


@needs_vanilla
def test_autoplay_skips_moves_that_need_a_decision(board: Path) -> None:
    text = (board / "HumanPlayerController.as").read_text(encoding="utf-8")
    assert "duelNeedsDecision(" in text
    assert "DUEL AUTOPLAY skip " in text


def test_opponent_applies_moves_through_applying_card() -> None:
    text = (SRC / "NetOpponentController.as").read_text(encoding="utf-8")
    for state in ("Idle", "WaitingForMove", "ShowingMove", "ApplyingCard", "ChoosingMove"):
        assert f'AddState("{state}"' in text, state
    assert "state_begin_ApplyingCard" in text and "startCardTransaction(" in text
    assert "ids.toLocal(" in text
    assert "unsupported" not in text


def test_session_checks_hashes_and_handles_desync() -> None:
    text = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    assert '"DUEL DESYNC seq="' in text
    assert "The match went out of sync and was cancelled" in text
    assert 'DESYNC:String = "Y"' in text and "send(DESYNC," in text
    assert "duelDebugCorruptAt" in text


def test_every_desync_sends_y() -> None:
    """R29: gap, non-H before Hello, malformed Hello, unsupported messages and moves end through desync (Y)."""
    text = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    aborts = re.findall(r'this\.abort\("(\w+)"', text)
    assert sorted(set(aborts)) == ["decks", "desync", "hello_timeout", "quit", "templates", "version"]
    assert aborts.count("desync") == 1
    assert 'abort("desync",DESYNC_TEXT)' in function_body(text, "function endDesync(")
    assert '"gap")' in function_body(text, "public function update(")
    assert "localDesync(" in function_body(text, "public function sendMove(")


def test_send_move_refuses_after_the_end() -> None:
    body = function_body((SRC / "DuelSession.as").read_text(encoding="utf-8"), "public function sendMove(")
    assert body.index("this._ended") < body.index("this.send(")


def test_opponent_desync_logs_its_own_hash() -> None:
    text = (SRC / "NetOpponentController.as").read_text(encoding="utf-8")
    assert "move.hash,move.hash" not in text
    assert text.count("session.lastAppliedHash,move.hash") == 3


def test_showing_move_waits_for_a_zoom() -> None:
    body = function_body((SRC / "NetOpponentController.as").read_text(encoding="utf-8"),
                         "function state_update_ShowingMove(")
    assert "this.cardEffectApplying()" in body


@needs_vanilla
def test_a_sent_move_is_neither_sent_again_nor_cancelled(board: Path) -> None:
    text = (board / "HumanPlayerController.as").read_text(encoding="utf-8")
    commit = function_body(text, "function commitTransaction(")
    assert commit.index("duelMoveInFlight()") < commit.index("sendMove(") < commit.index("_duelMovePending = true")
    assert "awaitingNextState" in function_body(text, "function duelMoveInFlight(")
    assert "duelMoveInFlight()" in function_body(text, "function cancelCardTransaction(")
    skip = function_body(text, "override public function skipTurn(")
    assert skip.index("duelMoveInFlight()") < skip.index('send("S"')
    assert "_duelMovePending = false" in function_body(text, "override protected function state_begin_ApplyingCard(")
