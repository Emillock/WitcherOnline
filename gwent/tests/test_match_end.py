"""Match end (spec 9.8, 10; rulings R13, R20, R41, R42, R43) against the board sources: the end screen and with it the
settlement wait for the opponent's end of game message (E), a desync or no E in that wait pays nobody, a draw is
replayed together or ends without money, surrender is a loss, and the duel log comparison skips the surrender hash."""
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
GWENT_DUEL_WS = (GWENT_DIR.parent / "witcher" / "mods" / "modWitcherOnline" / "content" / "scripts" / "local"
                 / "gwentDuel.ws")

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


def session() -> str:
    return (SRC / "DuelSession.as").read_text(encoding="utf-8")


@needs_vanilla
def test_the_end_screen_waits_for_the_confirmation(board: Path) -> None:
    """R43: in a duel the end screen (whose close settles) opens only from the confirmation callback."""
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    final = function_body(flow, "function state_begin_ShowingFinalResult(")
    duel = final.index("DuelSession.active.gameOver(gameWinner,this.duelShowEndDialog)")
    assert final.index("return;", duel) < final.index("this.mcEndGameDialog.show(gameWinner,this.OnEndGameResult)")
    assert final.index("DuelSession.active.finalWinner(gameWinner)") < final.index("this.duelGameWinner = gameWinner")
    assert "this.mcEndGameDialog.show(" in function_body(flow, "function duelShowEndDialog(")


def test_settling_needs_a_confirmed_result() -> None:
    """R43: finishGame (the only path to OnMatchResult for a finished game) refuses an unconfirmed result."""
    text = session()
    finish = function_body(text, "public function finishGame(")
    assert "this._end.phase != DuelEnd.CONFIRMED" in finish
    assert finish.index("this._end.phase != DuelEnd.CONFIRMED") < finish.index("duelFinish(")
    confirm = function_body(text, "private function dispatchEnd(")
    assert "this._end.endHash" in confirm
    assert confirm.index("next.hash != mine") < confirm.index("this._end.confirm()") < confirm.index("show()")
    assert confirm.index("desync(next.seq,mine,next.hash") < confirm.index("this._end.confirm()")


def test_a_desync_or_no_confirmation_pays_nobody() -> None:
    """R43: Y wins over the end routing; no E within the stuck-wait limit is no contest; both are aborts."""
    text = session()
    dispatch = function_body(text, "private function dispatch(")
    assert dispatch.index("next.type == DESYNC") < dispatch.index("this.dispatchEnd(next)")
    update = function_body(text, "public function update(")
    assert "confirmExpired(getTimer(),STUCK_WAIT_MS)" in update and 'abort("end_timeout")' in update
    assert "HELLO_TIMEOUT_MS:int = STUCK_WAIT_MS" in text and "STUCK_WAIT_MS:int = 120000" in text


def test_a_corrupt_end_message_is_the_test_of_the_last_message() -> None:
    """The test switch corruptAt=-1 corrupts the state right before this board's E (W3T_GWENT_CORRUPT_AT=end)."""
    send = function_body(session(), "public function send(")
    assert "corruptAt == CORRUPT_END && type == END" in send
    assert send.index("this.corrupt(") < send.index("DuelStateHash.compute(")


def test_draws_replay_together_or_end_without_money() -> None:
    text = session()
    replay = function_body(text, "public function localReplay(")
    assert "this._end.isDraw" in replay and "send(REPLAY," in replay and "startNextGame()" in replay
    leave = function_body(text, "public function localLeave(")
    assert leave.index("send(LEAVE,") < leave.index('finishDraw("leave")')
    assert 'finishDraw("opponent_leave")' in function_body(text, "private function dispatchEnd(")
    update = function_body(text, "public function update(")
    assert update.index("replayExpired(") < update.index("send(LEAVE,") < update.index('finishDraw("replay_timeout")')
    assert 'duelFinish("draw")' in function_body(text, "private function finishDraw(")


def test_the_next_game_starts_fresh_and_keeps_counting() -> None:
    """Spec 9.8: new game number, streams, net ids, match id and window; the outbound seq is not reset; the window goes
    on from the seq after the opponent's R and takes the opponent's last window again."""
    body = function_body(session(), "private function startNextGame(")
    for needle in ("this._gameNumber++", "new DuelRandom(this._seed,this._gameNumber)", "this._ids.reset()",
                   "DuelMessage.matchIdFor(this._seed,this._gameNumber)", "new DuelWindow(this._matchId,firstSeq)",
                   "this._window.ingest(this._lastWindow)", "new DuelEnd()", "new DuelMulligan()",
                   "duelStartNextGame()"):
        assert needle in body, needle
    assert body.index("var firstSeq:int = this._window.nextSeq") < body.index("new DuelWindow(")
    assert "_outSeq" not in body
    assert 'reason=replay game=' in body


@needs_vanilla
def test_the_flow_resets_through_the_vanilla_path(board: Path) -> None:
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    start = function_body(flow, "public function duelStartNextGame(")
    for needle in ("this.mcEndGameDialog.hide()", "this.lastRoundWinner = CardManager.PLAYER_INVALID",
                   "this.startDuelTimer()", 'this.stateMachine.ChangeState("Reset")'):
        assert needle in start, needle
    result = function_body(flow, "protected function OnEndGameResult(")
    assert "DuelSession.active.localLeave()" in result and "DuelSession.active.localReplay()" in result
    assert "PushMessage(DUEL_REPLAY_WAIT_TEXT)" in result
    assert result.index("DuelSession.active.localReplay()") < result.index('this.stateMachine.ChangeState("Reset")')


@needs_vanilla
def test_a_draw_calls_on_multiplayer_draw_instead_of_on_match_result(board: Path) -> None:
    menu = (board / "GwintGameMenu.as").read_text(encoding="utf-8")
    finish = function_body(menu, "public function duelFinish(")
    draw = finish.index('result == "draw"')
    assert finish.index("OnMultiplayerDraw", draw) < finish.index("else", draw) < finish.index("OnMatchResult")
    assert '"gwint.game.debug.replay"' in menu and "duelDebugReplay" in menu


def test_force_draw_only_for_game_zero() -> None:
    body = function_body(session(), "public function finalWinner(")
    assert "this._gameNumber != 0 || !GwintGameMenu.mSingleton.duelDebugForceDraw" in body
    assert "return CardManager.PLAYER_INVALID" in body


def test_surrender_after_an_abort_sends_nothing_and_late_quits_are_logged() -> None:
    """Task 8 carry: an aborted board sends no QUITGAME. R41: a QUITGAME after the local surrender is logged and
    ignored."""
    text = session()
    surrender = function_body(text, "public function surrender(")
    assert surrender.index("if(this._ended)") < surrender.index("this.send(DuelCodec.SURRENDER")
    assert "this.logLateQuit(this._lastWindow)" in surrender
    remote = function_body(text, "public function onRemoteInput(")
    assert remote.index("this._quitLocally") < remote.index("this._lastWindow = window")
    assert '"DUEL IGNORED "' in function_body(text, "private function logLateQuit(")


def test_end_routing_is_covered_by_the_self_test() -> None:
    text = (SRC / "DuelSelfTest.as").read_text(encoding="utf-8")
    assert 'test.guard("end",test.checkEnd)' in text
    body = function_body(text, "private function checkEnd(")
    assert len(re.findall(r"this\.expect\(", body)) >= 15
    assert "DuelEnd.CONFIRM" in body and "confirmExpired(" in body and "replayExpired(" in body


def test_end_message_routes_in_duel_end() -> None:
    text = (SRC / "DuelEnd.as").read_text(encoding="utf-8")
    route = function_body(text, "public function route(")
    assert "this.phase == PLAYING" in route and "message.type == DuelSession.END ? WAIT : detail" in route
    assert "message.args[0] == this.winner ? CONFIRM" in route


def test_script_match_id_clear_skips_an_empty_id() -> None:
    """Task 8 carry: a new match id clears the end signals, but not before the first outbound message (an abort of a
    game that sent nothing yet stays)."""
    text = GWENT_DUEL_WS.read_text(encoding="utf-8")
    assert 'if(duelMatchId != "" && matchId != duelMatchId)' in text
    assert 'SetFlashBool("gwint.game.debug.replay", manager.duelDebugReplay)' in text
