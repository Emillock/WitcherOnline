"""Opponent leaving and stuck waits (spec 10, 11; rulings R47, R48, R49) against the board and script sources: one
stuck-wait rule for every wait on an opponent message, whose Y goes out before the end; the opponent leaving ends the
game without a message; a decision dialog closed unanswered counts as its first option; the script tells the board when
it lost the opponent and clears its duel state when the board never opens. The rule itself (each wait kind, its limit,
what resets it) is checked in game by DuelSelfTest's wait group."""
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


def test_one_limit_by_mode() -> None:
    """R47: 120 s in Normal mode, turn time (60 s) + 30 s in Timed mode, picked by isTimed every update."""
    wait = source("DuelWait.as")
    assert "NORMAL_MS:int = 120000" in wait and "TURN_MS:int = 60000" in wait and "TIMED_EXTRA_MS:int = 30000" in wait
    assert "isTimed ? TURN_MS + TIMED_EXTRA_MS : NORMAL_MS" in function_body(wait, "public static function limitFor(")
    gone = function_body(source("DuelSession.as"), "private function opponentGone(")
    assert "DuelWait.limitFor(this._isTimed)" in gone


def test_every_opponent_wait_has_a_kind() -> None:
    """R47: the Hello, a move, a decision, the mulligan, E and R; nothing while the next message is already there."""
    kind_of = function_body(source("DuelWait.as"), "public static function kindOf(")
    for name in ("HELLO", "NONE", "END", "REPLAY", "DECISION", "MULLIGAN", "MOVE"):
        assert f"return {name}" in kind_of or f"? {name}" in kind_of or f": {name}" in kind_of, name
    assert kind_of.index("!helloDone") < kind_of.index("messageReady")
    waiting = function_body(source("DuelSession.as"), "private function waitingFor(")
    for needle in ("this._helloDone", "this._window.peek() != null", "this._end.phase", "this.waitingForReplay",
                   "this._remoteDecision != null", "this._mulligan.localSent", "!this._mulligan.remoteDone",
                   "opponent.waitingForMove"):
        assert needle in waiting, needle


def test_a_message_resets_the_wait() -> None:
    """R47: the wait starts over when its kind changes or the window's next seq moves on (a message was applied)."""
    tick = function_body(source("DuelWait.as"), "public function tick(")
    assert "kind != this._kind || progress != this._progress" in tick
    assert tick.index("this._sinceMs = nowMs") < tick.index("nowMs - this._sinceMs > limitMs")
    gone = function_body(source("DuelSession.as"), "private function opponentGone(")
    assert "this._wait.tick(kind,this._window.nextSeq,now," in gone


def test_the_wait_runs_after_this_ticks_message() -> None:
    """A message already queued is applied before any wait is judged (R45 order, kept for every wait)."""
    update = function_body(source("DuelSession.as"), "public function update(")
    assert update.index("this.dispatch(next)") < update.index("this.opponentGone()")
    assert update.index("this.opponentGone()") < update.index("this.autoplay()")


def test_the_y_goes_out_before_the_end() -> None:
    """R47: an expired wait sends Y (marked stuck, or hello for the Hello wait) and only then ends as no contest."""
    stuck = function_body(source("DuelSession.as"), "private function stuckWait(")
    y = stuck.index("this.send(DESYNC,")
    assert "DuelWait.MARK_HELLO : DuelWait.MARK_STUCK" in stuck
    assert y < stuck.index('this.abort("hello_timeout")') and y < stuck.index('this.abort("stuck_wait",STUCK_TEXT)')
    assert stuck.index('"DUEL STUCK "') < y
    assert "this._end.endHash" in stuck


def test_the_old_separate_timers_are_gone() -> None:
    """R47: the Hello, E and R waits go through the same rule; no timer of their own is left."""
    session = source("DuelSession.as")
    for old in ("HELLO_TIMEOUT_MS", "STUCK_WAIT_MS", "confirmExpired", "replayExpired", "_startMs", "end_timeout",
                "replay_timeout"):
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


def test_opponent_left_ends_without_a_message() -> None:
    """R47: gwint.game.opponentLeft ends nocontest reason=opponent_left and sends nothing; a confirmed win or loss
    stands, and messages already in the window apply first (at most LEFT_DRAIN_MS)."""
    gone = function_body(source("DuelSession.as"), "private function opponentGone(")
    left = gone.index("GwintGameMenu.mSingleton.duelOpponentLeft")
    end = gone.index('this.abort("opponent_left",LEFT_TEXT)')
    assert left < end and "send(" not in gone[left:end]
    assert "this._end.phase == DuelEnd.CONFIRMED && !this._end.isDraw" in gone
    assert "this._window.peek() != null" in gone
    ends = function_body(source("DuelWait.as"), "public static function leftEnds(")
    assert "!resultStands && (!messageReady || nowMs - leftAtMs > LEFT_DRAIN_MS)" in ends


def test_the_self_test_covers_the_rule() -> None:
    text = source("DuelSelfTest.as")
    assert 'test.guard("wait",test.checkWait)' in text
    body = function_body(text, "private function checkWait(")
    assert len(re.findall(r"this\.expect\(", body)) >= 20
    for needle in ("DuelWait.HELLO", "DuelWait.MOVE", "DuelWait.DECISION", "DuelWait.MULLIGAN", "DuelWait.END",
                   "DuelWait.REPLAY", "limitFor(true)", "reasonOfY(", "leftEnds(", "starts the wait over"):
        assert needle in body, needle


def test_a_closed_dialog_counts_as_its_first_option() -> None:
    """R48: a local decision whose dialog went away unanswered is answered with its first option (not COIN: the
    script's popup does that)."""
    session = source("DuelSession.as")
    closed = function_body(session, "private function localDialogClosed(")
    assert "decision.shown" in closed and "decision.kind != COIN" in closed and "mcChoiceDialog.isShown()" in closed
    first = function_body(session, "private function answerFirstOption(")
    assert first.index("var choice:String = first()") < first.index("this.answer(decision.kind,choice)")
    assert "firstChoice:Function = null" in session and "firstFn" in source("DuelDecision.as")


@needs_vanilla
def test_every_decision_site_has_a_first_option(board: Path) -> None:
    """R48: the medic, the leader choices and the coin toss pass their first option to decide."""
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
    gone = loop.index("if(!gwentOpponent || gwentOpponentSilent())")
    assert loop.index("menu.IsDuel()") < gone < loop.index("menu.SetDuelOpponentLeft()")
    assert gone < loop.index("checkForGwentAction(action)")
    assert "gwentOpponentLeftSent" in loop


def test_script_presence_counts_real_time() -> None:
    """Engine time stands still while the board pauses the game (measured: Witcher Online's 5 s prune never removed a
    closed opponent during a duel), so the duel watches the opponent's movement sequence on the real clock."""
    client = script("client.ws")
    silent = function_body(client, "private function gwentOpponentSilent(")
    assert silent.index("if(!gwentOpponent)") < silent.index("gwentOpponent.lastMovementSequence != gwentOpponentSeq")
    assert "gwentOpponentSeenMs = theGame.GetLocalTimeAsMilliseconds()" in silent
    assert "WO_GwentMsSince(gwentOpponentSeenMs) > (int)(WO_GwentOpponentSilentSeconds() * 1000.0)" in silent
    assert "GetEngineTime" not in silent
    duel = script("gwentDuel.ws")
    assert "return 10.0;" in function_body(duel, "function WO_GwentOpponentSilentSeconds(")
    since = function_body(duel, "function WO_GwentMsSince(")
    assert "theGame.GetLocalTimeAsMilliseconds() - startMs" in since and "elapsed += 86400000" in since
    signal = function_body(script("gwentDuel.ws"), "public function SetDuelOpponentLeft(")
    assert 'SetFlashBool("gwint.game.opponentLeft", true)' in signal


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
