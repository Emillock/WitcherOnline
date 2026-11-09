"""Opponent leaving and stuck waits (spec 10, 11; rulings R47 to R52) against the board and script sources: one
stuck-wait rule for every wait on an opponent message, whose Y goes out before the end, the R wait ending as a draw;
the opponent leaving ends the game after the same Y (through the stuck path while this board waits for E, as a draw
after a confirmed draw); a board decision dialog closed unanswered is shown again, the coin popup closed unanswered
counts as its first option; the script tells the board when the opponent's packets stop for 30 s of real time (a
local stall restarts the clock) and clears its duel state when the board never opens. The rule itself (each wait kind,
its limit, what resets it, each verdict) is checked in game by DuelSelfTest's wait group."""
import re
import shutil
from pathlib import Path

import pytest

import build
from as3_source import function_body

GWENT_DIR = Path(__file__).resolve().parent.parent
VANILLA = GWENT_DIR / "work" / "vanilla"
SRC = GWENT_DIR / "src"
PATCHES = GWENT_DIR / "patches"
GWINT = Path("red") / "game" / "witcher3" / "menus" / "gwint"
SCRIPTS = GWENT_DIR.parent / "witcher" / "mods" / "modWitcherOnline" / "content" / "scripts" / "local"

needs_vanilla = pytest.mark.skipif(not (VANILLA / GWINT).is_dir(),
                                   reason="no decompiled vanilla board (run build.py build first)")


@pytest.fixture(scope="module")
def board(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """The vanilla board with gwent/patches applied (the gwint package folder)."""
    target = tmp_path_factory.mktemp("board")
    shutil.copytree(VANILLA / "red", target / "red")
    build.apply_patches(target, PATCHES)
    return target / GWINT


def source(name: str) -> str:
    """One of the board's own classes (gwent/src)."""
    return (SRC / name).read_text(encoding="utf-8")


def script(name: str) -> str:
    """One of Witcher Online's scripts."""
    return (SCRIPTS / name).read_text(encoding="utf-8")


def gone() -> str:
    """DuelSession.opponentGone: the only place that acts on DuelWait's verdict."""
    return function_body(source("DuelSession.as"), "private function opponentGone(")


def test_one_limit_by_mode() -> None:
    """R47: 120 s in Normal mode, turn time (60 s) + 30 s in Timed mode, picked by isTimed every update."""
    wait = source("DuelWait.as")
    assert "NORMAL_MS:int = 120000" in wait and "TURN_MS:int = 60000" in wait and "TIMED_EXTRA_MS:int = 30000" in wait
    assert "isTimed ? TURN_MS + TIMED_EXTRA_MS : NORMAL_MS" in function_body(wait, "public static function limitFor(")
    assert "DuelWait.limitFor(this._isTimed)" in gone()


def test_every_opponent_wait_has_a_kind() -> None:
    """R47: the Hello, a move, a decision, the mulligan, E and R; nothing while the next message is already there.
    Minor 4: the Hello wait counts only once this board sent its own Hello."""
    kind_of = function_body(source("DuelWait.as"), "public static function kindOf(")
    for name in ("NONE", "END", "REPLAY", "DECISION", "MULLIGAN", "MOVE"):
        assert f"return {name}" in kind_of or f"? {name}" in kind_of or f": {name}" in kind_of, name
    assert "return helloSent ? HELLO : NONE" in kind_of
    assert kind_of.index("!helloDone") < kind_of.index("messageReady")
    waiting = function_body(source("DuelSession.as"), "private function waitingFor(")
    for needle in ("this._helloSent,this._helloDone", "this._window.peek() != null", "this._end.phase",
                   "this.waitingForReplay", "this._remoteDecision != null", "this._mulligan.localSent",
                   "!this._mulligan.remoteDone", "opponent.waitingForMove"):
        assert needle in waiting, needle


def test_a_board_that_never_sent_its_hello_still_takes_a_y() -> None:
    """Minor 4: with no Hello wait before this board's own H, the opponent's Y or QUITGAME still ends it."""
    update = function_body(source("DuelSession.as"), "public function update(")
    assert update.index("if(!this._helloSent)") < update.index("this.dispatchEarlyEnd()") < update.index("this.dispatch(next)")
    early = function_body(source("DuelSession.as"), "private function dispatchEarlyEnd(")
    assert "this._lastWindow" in early and "m.matchId != this._matchId" in early
    assert "this.applyDesync(m)" in early and "this.applySurrender(m,this._gameNumber)" in early


def test_a_message_resets_the_wait() -> None:
    """R47: the wait starts over when its kind changes or the window's next seq moves on (a message was applied)."""
    wait = source("DuelWait.as")
    tick = function_body(wait, "public function tick(")
    assert "kind != this._kind || progress != this._progress" in tick
    assert tick.index("this._sinceMs = nowMs") < tick.index("nowMs - this._sinceMs > limitMs")
    assert "this.tick(kind,progress,nowMs,limitMs)" in function_body(wait, "public function verdict(")
    assert "this._wait.verdict(kind,this._window.nextSeq,now," in gone()


def test_the_wait_runs_after_this_ticks_message() -> None:
    """A message already queued is applied before any wait is judged (R45 order, kept for every wait)."""
    update = function_body(source("DuelSession.as"), "public function update(")
    assert update.index("this.dispatch(next)") < update.index("this.opponentGone()")
    assert update.index("this.opponentGone()") < update.index("this.autoplay()")


def test_each_expired_wait_has_its_verdict() -> None:
    """R47, R51: Hello -> hello_timeout, R -> replay_timeout (a draw), every other kind -> stuck."""
    verdict = function_body(source("DuelWait.as"), "public function verdict(")
    expired = verdict.index("if(!expired)")
    assert verdict.index("kind == HELLO", expired) < verdict.index("return HELLO_TIMEOUT", expired)
    assert "return kind == REPLAY ? REPLAY_TIMEOUT : STUCK" in verdict


def test_the_y_goes_out_before_every_no_contest() -> None:
    """R47, R50: an expired wait and the opponent leaving both send the marked Y, then end as no contest."""
    body = gone()
    y = body.index("this.sendStuckY(verdict == DuelWait.HELLO_TIMEOUT)")
    for end in ('this.abort("hello_timeout")', 'this.abort("opponent_left",LEFT_TEXT)', 'this.abort("stuck_wait",STUCK_TEXT)'):
        assert y < body.index(end), end
    assert body.index('"DUEL STUCK "', body.index("REPLAY_TIMEOUT")) < y
    send = function_body(source("DuelSession.as"), "private function sendStuckY(")
    assert "DuelWait.MARK_HELLO : DuelWait.MARK_STUCK" in send
    assert "this._end.phase == DuelEnd.CONFIRMING ? this._end.endHash" in send


def test_the_r_wait_ends_as_a_draw() -> None:
    """R51: no R in time sends X and ends as a draw without money (spec 9.8), as Task 14 did."""
    body = gone()
    replay = body.index("verdict == DuelWait.REPLAY_TIMEOUT")
    assert replay < body.index("this.send(LEAVE,[],DuelStateHash.SCOPE_FULL)", replay)
    assert body.index("this.send(LEAVE,", replay) < body.index('this.finishDraw("replay_timeout")', replay)
    assert body.index('this.finishDraw("replay_timeout")', replay) < body.index("this.sendStuckY(")


def test_the_old_separate_timers_are_gone() -> None:
    """R47: the Hello, E and R waits go through the same rule; no timer of their own is left."""
    session = source("DuelSession.as")
    for old in ("HELLO_TIMEOUT_MS", "STUCK_WAIT_MS", "confirmExpired", "replayExpired", "_startMs", "end_timeout",
                "leftEnds", "localDialogClosed", "answerFirstOption"):
        assert old not in session, old
    end = source("DuelEnd.as")
    for old in ("confirmExpired", "replayExpired", "endAtMs", "replayAtMs"):
        assert old not in end, old


def test_a_marked_y_ends_the_opponent_the_same_way() -> None:
    """R47: the idle side ends through the Y with the same reason, without a desync report."""
    apply = function_body(source("DuelSession.as"), "private function applyDesync(")
    marked = apply.index("DuelWait.reasonOfY(y.args)")
    assert marked < apply.index('this.abort("hello_timeout")') < apply.index("this.endDesync(")
    assert marked < apply.index('this.abort("stuck_wait",STUCK_TEXT)') < apply.index("this.endDesync(")
    reason = function_body(source("DuelWait.as"), "public static function reasonOfY(")
    assert "args.length >= 3" in reason and "MARK_STUCK" in reason and "MARK_HELLO" in reason


def test_opponent_left_ends_by_phase() -> None:
    """R47, R50, R51: messages already in the window apply first (at most LEFT_DRAIN_MS); a confirmed win or loss
    stands; a confirmed draw ends as a draw; while waiting for E through the stuck path; else opponent_left."""
    verdict = function_body(source("DuelWait.as"), "public function verdict(")
    left = verdict.index("leftAtMs >= 0 && !resultStands && (!messageReady || nowMs - leftAtMs > LEFT_DRAIN_MS)")
    assert "resultStands:Boolean = endPhase == DuelEnd.CONFIRMED && !isDraw" in verdict
    assert left < verdict.index("return LEFT_DRAW") < verdict.index("if(!expired)")
    assert "return endPhase == DuelEnd.CONFIRMING ? STUCK : LEFT" in verdict
    body = gone()
    assert body.index("GwintGameMenu.mSingleton.duelOpponentLeft") < body.index("this._wait.verdict(")
    draw = body.index("verdict == DuelWait.LEFT_DRAW")
    assert draw < body.index('this.finishDraw("opponent_leave")') < body.index("this.sendStuckY(")


def test_the_self_test_covers_the_rule() -> None:
    """The wait group runs every kind, limit, reset and verdict on DuelWait, and R52 on DuelDecision, in game."""
    text = source("DuelSelfTest.as")
    assert 'test.guard("wait",test.checkWait)' in text
    body = function_body(text, "private function checkWait(")
    assert len(re.findall(r"this\.expect\(", body)) >= 30
    for needle in ("DuelWait.HELLO", "DuelWait.MOVE", "DuelWait.DECISION", "DuelWait.MULLIGAN", "DuelWait.END",
                   "DuelWait.REPLAY", "limitFor(true)", "reasonOfY(", "verdict(", "DuelWait.LEFT_DRAW",
                   "DuelWait.REPLAY_TIMEOUT", "starts the wait over", "closedUnanswered(", "before this board sent"):
        assert needle in body, needle


def test_a_closed_board_dialog_is_shown_again() -> None:
    """R52: a board decision dialog that a card zoom replaced and closed is shown again, not answered; the coin popup
    is the script's (it answers a close itself)."""
    closed = function_body(source("DuelDecision.as"), "public function closedUnanswered(")
    assert "this.shown && this.kind != DuelSession.COIN && !dialogShown" in closed
    update = function_body(source("DuelSession.as"), "public function update(")
    check = update.index("this._localDecision.closedUnanswered(GwintGameMenu.mSingleton.mcChoiceDialog.isShown())")
    assert update.index("this._localDecision.shown = false", check) < update.index("this.autoplay()")
    assert "this.answer(" not in update[check:update.index("this.autoplay()")]
    assert "firstChoice:Function = null" in source("DuelSession.as") and "firstFn" in source("DuelDecision.as")


@needs_vanilla
def test_every_decision_site_has_a_first_option(board: Path) -> None:
    """The medic, the leader choices and the coin toss pass their first option to decide (the default answer)."""
    card = (board / "CardInstance.as").read_text(encoding="utf-8")
    assert "this.duelAutoNurseChoice,this.duelFirstNurseChoice)" in card
    assert "this._duelNurseTargets[0].instanceId" in function_body(card, "private function duelFirstNurseChoice(")
    leader = (board / "CardLeaderInstance.as").read_text(encoding="utf-8")
    assert "this.duelAutoChoice,this.duelFirstChoice)" in leader
    pick = function_body(leader, "private function duelFirstChoice(")
    assert "this._duelChoiceTemplates[0]" in pick and "this._duelChoiceCards[0].instanceId" in pick
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    assert "this.duelAutoCoinChoice,this.duelAutoCoinChoice)" in flow
    assert 'return "1";' in function_body(flow, "private function duelAutoCoinChoice(")


def test_script_closing_the_coin_popup_picks_go_first() -> None:
    """R48: the Scoia'tael popup closed without an answer counts as its first option, "go first" (duels only)."""
    text = script("gwentDuel.ws")
    closing = function_body(text, "function OnClosing()")
    assert "!turnPopup.duelAnswered" in closing and "gwintMenuRef.IsDuel()" in closing
    assert "gwintMenuRef.SetPlayerStarts(true)" in closing
    assert closing.index("wrappedMethod()") > closing.index("SetPlayerStarts(true)")
    for answer in ("function OnUserAccept()", "function OnUserDecline()"):
        assert "duelAnswered = true" in function_body(text, answer), answer


def test_script_tells_the_board_when_the_opponent_is_gone() -> None:
    """Spec 11: once the duel board is up, Witcher Online losing the opponent (disconnect) or the opponent's packets
    stopping (its game closed) sets gwint.game.opponentLeft, once."""
    client = script("client.ws")
    loop = function_body(client, "public function gwentGameLoop(")
    lost = loop.index("if(!gwentOpponent || gwentOpponentSilent())")
    assert loop.index("menu.IsDuel()") < lost < loop.index("menu.SetDuelOpponentLeft()")
    assert lost < loop.index("checkForGwentAction(action)")
    assert "gwentOpponentLeftSent" in loop
    signal = function_body(script("gwentDuel.ws"), "public function SetDuelOpponentLeft(")
    assert 'SetFlashBool("gwint.game.opponentLeft", true)' in signal


def test_script_presence_counts_real_time() -> None:
    """Engine time stands still while the board pauses the game (measured: Witcher Online's 5 s prune never removed a
    closed opponent during a duel), so the duel watches the opponent's movement sequence on the real clock: R50, 30 s
    of silence."""
    client = script("client.ws")
    silent = function_body(client, "private function gwentOpponentSilent(")
    assert silent.index("if(!gwentOpponent)") < silent.index("gwentOpponent.lastMovementSequence != gwentOpponentSeq")
    assert "gwentOpponentSeenMs = theGame.GetLocalTimeAsMilliseconds()" in silent
    assert "WO_GwentMsSince(gwentOpponentSeenMs) > (int)(WO_GwentOpponentSilentSeconds() * 1000.0)" in silent
    assert "GetEngineTime" not in silent
    duel = script("gwentDuel.ws")
    assert "return 30.0;" in function_body(duel, "function WO_GwentOpponentSilentSeconds(")
    since = function_body(duel, "function WO_GwentMsSince(")
    assert "theGame.GetLocalTimeAsMilliseconds() - startMs" in since and "elapsed += 86400000" in since


def test_script_local_stall_restarts_the_silence_clock() -> None:
    """R50: when gwentGameLoop itself was not called for more than 3 s, a stale sequence must not meet a jumped clock:
    the silence clock starts again before the check."""
    client = script("client.ws")
    loop = function_body(client, "public function gwentGameLoop(")
    stall = loop.index("WO_GwentMsSince(gwentLoopMs) > (int)(WO_GwentLoopStallSeconds() * 1000.0)")
    restart = loop.index("gwentOpponentSeenMs = theGame.GetLocalTimeAsMilliseconds()", stall)
    stamp = loop.index("gwentLoopMs = theGame.GetLocalTimeAsMilliseconds()", restart)
    assert stall < restart < stamp < loop.index("gwentOpponentSilent()")
    assert "return 3.0;" in function_body(script("gwentDuel.ws"), "function WO_GwentLoopStallSeconds(")


def test_script_clears_the_duel_when_the_board_never_opens() -> None:
    """R49: no duel board within the limit after the challenge clears inGwentGame (no bet is held, none is paid);
    a Hello wait that fails ends through OnMultiplayerAbort, whose close clears it as well."""
    client = script("client.ws")
    loop = function_body(client, "public function gwentGameLoop(")
    assert "!gwentBoardSeen" in loop and "WO_GwentBoardOpenSeconds()" in loop
    assert loop.index("!gwentBoardSeen") < loop.index("finishGwentGame()")
    assert loop.index("finishGwentGame()") < loop.index("gwentBoardSeen = true")
    start = function_body(client, "public function startGwentGame(")
    assert "gwentBoardSeen = false" in start and "gwentStartedMs = theGame.GetLocalTimeAsMilliseconds()" in start
    assert "WO_GwentMsSince(gwentStartedMs) > (int)(WO_GwentBoardOpenSeconds() * 1000.0)" in loop
    assert "gwentOpponentLeftSent = false" in start
    finish = function_body(client, "private function finishGwentGame(")
    assert "inGwentGame = false" in finish and "activeGwentBet = 0" in finish
    closing = function_body(script("gwentDuel.ws"), "function OnClosingMenu()")
    assert closing.index("if(duelAborted)") < closing.index("client.onGwentGameAborted(duelAbortReason)")
