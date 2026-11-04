"""Timed mode (spec 15, rulings R53 to R55) against the board and script sources: one local clock of the turn time
(DuelWait.TURN_MS, 60 s) for each stretch in which the board waits on local input (a turn with the decisions its move
raises, the mulligan, a decision outside the turn); on expiry an open zoom closes, open decisions take their first
option, a picked card is cancelled and the board passes (S), sends M with the redraws so far, or answers the decision;
the opponent's countdown is display only; the countdown is drawn in code; Normal mode has no timer. The clock itself
(each stretch, its expiry, one budget across a decision in a turn) is checked in game by DuelSelfTest's timer group."""
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


def session(signature: str) -> str:
    """The body of one DuelSession function."""
    return function_body(source("DuelSession.as"), signature)


def timer_update() -> str:
    """DuelTimer.update: the clocks, their log lines and the view, every 20 ms."""
    return function_body(source("DuelTimer.as"), "public function update(")


def test_one_turn_time_shared_with_the_stuck_wait() -> None:
    """R53: the clock runs DuelWait.TURN_MS, the number the Timed stuck limit (TURN_MS + 30 s) is built from."""
    clock = source("DuelClock.as")
    assert "DuelWait.TURN_MS" in function_body(clock, "public function tick(")
    assert "DuelWait.TURN_MS" in function_body(clock, "public function remainingMs(")
    for name in ("DuelClock.as", "DuelTimer.as", "DuelTimerView.as", "DuelSession.as"):
        assert "60000" not in source(name) and "60 * 1000" not in source(name), name


def test_normal_mode_has_no_stretch() -> None:
    """R54: Normal mode shows no timer and acts as before: stretchOf answers NONE before anything else."""
    stretch = function_body(source("DuelClock.as"), "public static function stretchOf(")
    assert stretch.index("if(!isTimed)") < stretch.index("return NONE") < stretch.index("localTurn")
    timer = timer_update()
    assert "DuelClock.stretchOf(isTimed,human != null" in timer
    assert "DuelClock.stretchOf(isTimed,opponent != null" in timer
    assert "this._timer.update(this._isTimed," in session("private function updateTimer(")
    # the view only exists once a Timed stretch showed it
    assert "new DuelTimerView()" in function_body(source("DuelTimer.as"), "private function show(")
    assert "new DuelTimerView()" not in source("DuelTimer.as").replace(
        function_body(source("DuelTimer.as"), "private function show("), "")


def test_one_budget_across_a_decision_in_a_turn() -> None:
    """R53: a decision inside the local turn is part of the turn (TURN wins over DECISION), and an expired stretch
    stays expired until it ends, so every further decision of that turn takes its first option at once."""
    stretch = function_body(source("DuelClock.as"), "public static function stretchOf(")
    assert stretch.index("localTurn") < stretch.index("mulliganOpen") < stretch.index("localDecision ? DECISION")
    tick = function_body(source("DuelClock.as"), "public function tick(")
    assert "kind != this._kind || id != this._id" in tick and "this._expired = false" in tick
    assert "this._expired = true" in tick
    timer = timer_update()
    assert "human.duelTurnNumber" in timer and "localDecisions" in timer and "gameNumber" in timer
    assert "return this._clock.expired ? kind : DuelClock.NONE" in timer
    glue = session("private function updateTimer(")
    assert "this._localDecisions,this._gameNumber" in glue
    assert glue.index("if(expired != DuelClock.NONE)") < glue.index("this.timeUp(expired,human,flow)")


def test_expiry_closes_the_zoom_then_answers_or_passes() -> None:
    """R53: on expiry an open zoom closes; an open decision takes its first option once the board has settled (as
    a player's answer would); else a turn passes (S) and a mulligan counts as done."""
    up = session("private function timeUp(")
    assert up.index("human.duelCloseZoom()") < up.index("this._localDecision != null")
    assert "this.settled()" in up and "this.answerFirst()" in up
    assert up.index("this.answerFirst()") < up.index("human.duelTimeUp()") < up.index("flow.duelMulliganTimeUp()")
    first = session("private function answerFirst(")
    assert "decision.firstChoice()" in first and "this.answer(decision.kind,choice)" in first
    assert first.index("decision.shown = true") < first.index("this.answer(")
    assert "mcChoiceDialog.hideDialog()" in first and "duelCloseCoinPopup()" in first
    assert "DUEL TIMER timeout decide " in first
    decision = function_body(source("DuelDecision.as"), "public function firstChoice(")
    assert "this.firstFn" in decision


def test_decisions_are_counted_for_their_own_stretch() -> None:
    """R53: each local decision outside the turn is its own stretch (its id is the count of local decisions)."""
    decide = session("public function decide(")
    local = decide[decide.index("seat == this.localSeat"):decide.index("by=opponent")]
    assert "this._localDecisions++" in local


def test_timer_logs_and_runs_after_the_waits() -> None:
    """The timer runs in the 20 ms update after the stuck wait and the dialog, before autoplay, and logs DUEL TIMER
    lines (start, expired after=<ms>, timeout ...) only in Timed mode."""
    update = session("public function update(")
    assert update.index("this.opponentGone()") < update.index("this.updateTimer()") < update.index("this.autoplay()")
    timer = timer_update()
    assert '"DUEL TIMER expired "' in timer and '" after="' in timer and '"DUEL TIMER start "' in timer
    up = session("private function timeUp(")
    assert '"DUEL TIMER timeout pass"' in up and '"DUEL TIMER timeout mulligan redraws="' in up


def test_the_view_is_drawn_in_code_and_never_runs_its_own_timer() -> None:
    """Spec 15: Sprite graphics and a TextField, no copied art; R22: no Timer of its own (the 20 ms duel tick drives
    it) and it hides when the duel tick stops."""
    view = source("DuelTimerView.as")
    assert "extends Sprite" in view and "graphics." in view and "TextField" in view
    for name in ("DuelTimerView.as", "DuelClock.as", "DuelTimer.as"):
        assert "flash.utils.Timer" not in source(name) and "new Timer(" not in source(name), name
    assert "getBounds(" in view
    assert "this._timer.hide()" in session("public function hideTimer(")
    assert "this._view.hide()" in function_body(source("DuelTimer.as"), "public function hide(")


@needs_vanilla
def test_the_turn_passes_through_the_pass_path(board: Path) -> None:
    """R53: the local turn's timeout passes like the pass button (S, then the vanilla pass, a picked card restored),
    but only before the move was sent; the turn number and the turn states are what the clock reads."""
    human = (board / "HumanPlayerController.as").read_text(encoding="utf-8")
    skip = function_body(human, "override public function skipTurn(")
    assert "this.passTurn()" in skip
    passing = function_body(human, "private function passTurn(")
    assert passing.index('send("S"') < passing.index("declineCardTransaction()") < passing.index('ChangeState("Idle")')
    up = function_body(human, "public function duelTimeUp(")
    assert "this.duelMoveInFlight()" in up and "this.passTurn()" in up
    for state in ("ChoosingCard", "ChoosingHandler", "ChoosingTargetCard", "WaitConfirmation"):
        assert f'"{state}"' in up and f'"{state}"' in function_body(human, "public function get duelTurnActive(")
    assert '"ApplyingCard"' in function_body(human, "public function get duelTurnActive(")
    assert '"ApplyingCard"' not in up
    assert "this.closeZoomCB()" in function_body(human, "public function duelCloseZoom(")
    start = function_body(human, "override public function startTurn(")
    assert start.index("super.startTurn()") < start.index("this._duelTurnNumber++") < start.index('ChangeState("ChoosingCard")')


@needs_vanilla
def test_the_mulligan_timeout_declines(board: Path) -> None:
    """R53: the mulligan's timeout counts as done with the redraws so far: the vanilla decline, which sends M."""
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    up = function_body(flow, "public function duelMulliganTimeUp(")
    assert '"Mulligan"' in up and "this._mulliganDecided" in up and "this.handleDeclineMulligan()" in up
    assert "this.duelSendMulliganDone()" in function_body(flow, "protected function handleDeclineMulligan(")
    assert "DuelSession.active.hideTimer()" in function_body(flow, "public function stopDuelTimer(")


@needs_vanilla
def test_the_opponent_countdown_is_display_only(board: Path) -> None:
    """R54: the opponent's turn runs a second clock for the view; nothing acts on its expiry."""
    net = (board / "NetOpponentController.as").read_text(encoding="utf-8") if (board / "NetOpponentController.as").is_file() \
        else source("NetOpponentController.as")
    assert "this._duelTurnNumber++" in function_body(net, "override public function startTurn(")
    assert '"WaitingForMove"' in function_body(net, "public function get duelTurnActive(")
    timer = source("DuelTimer.as")
    assert "this._opponentClock.tick(" in timer_update() and "this._opponentClock.expired" not in timer
    assert "opponent.playerRenderer" in timer_update() and "human.playerRenderer" in timer_update()


@needs_vanilla
def test_the_coin_popup_closes_on_its_timeout(board: Path) -> None:
    """R53 with R48: the Scoia'tael popup is the script's: on the decision's timeout the board answers its first
    option itself and asks the script to close the popup, marked answered so its close does not answer again."""
    menu = (board / "GwintGameMenu.as").read_text(encoding="utf-8")
    assert '"OnDuelCoinTimeUp"' in function_body(menu, "public function duelCloseCoinPopup(")
    duel = (SCRIPTS / "gwentDuel.ws").read_text(encoding="utf-8")
    body = duel[duel.index("event OnDuelCoinTimeUp("):]
    body = body[:body.index("\n}\n")]
    assert body.index("chooseTurnPopup.duelAnswered = true") < body.index("chooseTurnPopup.ClosePopupOverlay()")


def test_self_test_covers_the_timer() -> None:
    """The in-game self-test runs the timer group."""
    selftest = source("DuelSelfTest.as")
    assert 'test.guard("timer",test.checkTimer)' in selftest
    timer = function_body(selftest, "private function checkTimer(")
    for needle in ("DuelClock.TURN", "DuelClock.MULLIGAN", "DuelClock.DECISION", "DuelClock.EXPIRED",
                   "stretchOf(false"):
        assert needle in timer, needle
    assert len(re.findall(r"this\.expect\(", timer)) >= 12
