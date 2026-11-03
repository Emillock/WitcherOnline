"""Canonical order for simultaneous effects (spec 7.4) against the patched board sources: in a duel a card's landing
effects (CardInstance.onFinishedMovingIntoHolder) are queued in DuelSession and run one at a time in seat, then net id
order once the board has settled, the board holds while any is queued, nothing stays queued past the end of a game,
and the paired perks (Northern Realms draw, Skellige round 3, the Monsters round-end loop) run seat A first."""
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


def session_source() -> str:
    """gwent/src/DuelSession.as."""
    return (SRC / "DuelSession.as").read_text(encoding="utf-8")


@needs_vanilla
def test_landing_effects_are_deferred_in_duels(board: Path) -> None:
    patched = (board / "CardInstance.as").read_text(encoding="utf-8")
    vanilla = (VANILLA / GWINT / "CardInstance.as").read_text(encoding="utf-8")
    entry = function_body(patched, "public function onFinishedMovingIntoHolder(")
    assert entry.index("DuelSession.active != null") < entry.index("deferEffect(this,this.duelRunLanding)")
    assert entry.index("deferEffect(") < entry.index("applyFinishedMovingIntoHolder(listID,playerID)")
    # the vanilla rules run unchanged, only later
    assert function_body(patched, "function applyFinishedMovingIntoHolder(") == \
        function_body(vanilla, "public function onFinishedMovingIntoHolder(")
    run = function_body(patched, "private function duelRunLanding(")
    assert "this.inList == this._duelLandingList" in run and "this.listsPlayer == this._duelLandingPlayer" in run
    assert "applyFinishedMovingIntoHolder(" in run


def test_deferred_effects_run_in_seat_then_net_id_order() -> None:
    before = function_body((SRC / "DuelEffect.as").read_text(encoding="utf-8"), "public function before(")
    assert before.index("this.seat") < before.index("this.netId") < before.index("this.order")
    defer = function_body(session_source(), "public function deferEffect(")
    assert "seatOf(card.owningPlayer)" in defer and "toNet(card.instanceId)" in defer
    assert "_deferred.add(" in defer


def test_deferred_effects_run_one_at_a_time_once_the_board_settles() -> None:
    text = session_source()
    update = function_body(text, "public function update(")
    assert "runDeferred()" in update
    assert update.index("runDeferred()") < update.index("this._window.peek()")
    loop = function_body(text, "private function runDeferred(")
    assert "while(" in loop
    condition = loop[loop.index("while("):loop.index("{", loop.index("while("))]
    for word in ("_ended", "_deferred.pending", "decisionOpen", "settled()"):
        assert word in condition, word
    assert "takeNext()" in loop and ".run()" in loop
    # decisions are shown and taken at settled points while effects wait, so settled() must not wait for the queue
    assert "_deferred" not in function_body(text, "private function settled(")


@needs_vanilla
def test_queued_effects_hold_the_board(board: Path) -> None:
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    assert "effectsPending" in function_body(flow, "function shouldDisallowStateChangeFunc(")
    human = (board / "HumanPlayerController.as").read_text(encoding="utf-8")
    applying = function_body(human, "override protected function state_update_ApplyingCard(")
    # the turn is not over while a decision of this move is open or one of its effects waits
    assert "effectsPending" in applying and "decisionOpen" in applying
    assert "effectsPending" in function_body(human, "override protected function cardEffectApplying(")
    tick = function_body(human, "private function duelAutoplayTick(")
    assert tick.index("this.cardEffectApplying()") < tick.index("duelSuggestMove()")
    net = (SRC / "NetOpponentController.as").read_text(encoding="utf-8")
    assert "effectsPending" in function_body(net, "override protected function cardEffectApplying(")
    assert "this._deferred.pending" in function_body(session_source(), "public function get effectsPending(")


def test_nothing_stays_queued_after_a_game_ends() -> None:
    text = session_source()
    enders = [match.start() for match in re.finditer(r"this\._ended = true;", text)]
    assert enders, "no end of game found"
    for at in enders:
        start = text.rindex("function ", 0, at)
        body = function_body(text, text[start:text.index("(", start) + 1])
        assert "this._deferred.clear()" in body, text[start:text.index("(", start)]
    defer = function_body(text, "public function deferEffect(")
    assert defer.index("this._ended") < defer.index("run()") < defer.index("_deferred.add(")
    assert "_deferred.clear()" in function_body(text, "public static function stop(")


@needs_vanilla
def test_round_start_perks_run_in_seat_order(board: Path) -> None:
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    begin = function_body(flow, "function state_begin_RoundStart(")
    assert begin.index("duelPushRoundStartPerks()") < begin.index("FactionId_Northern_Kingdom")
    push = function_body(flow, "private function duelPushRoundStartPerks(")
    assert "seat = DuelIds.SEAT_A; seat <= DuelIds.SEAT_B" in push
    assert "FactionId_Northern_Kingdom" in push and "FactionId_Skellige" in push
    assert "this.currentRound == 2" in push and "this.lastRoundWinner" in push
    # one callback runs every perk at the same logical point (the player may skip messages)
    assert push.count("duelPushPerk(") == 2
    perk = function_body(flow, "private function duelPushPerk(")
    assert "first ? this.duelRunRoundStartPerks : null" in perk
    run = function_body(flow, "private function duelRunRoundStartPerks(")
    assert "drawCard(" in run and "ressurectFromGraveyard(" in run


@needs_vanilla
def test_monsters_round_end_loop_runs_in_seat_order(board: Path) -> None:
    manager = (board / "CardManager.as").read_text(encoding="utf-8")
    clear = function_body(manager, "public function clearBoard(")
    assert "duelClearOrder(" in clear
    order = function_body(manager, "private function duelClearOrder(")
    assert "DuelSession.active == null" in order and "playerOf(" in order


def test_self_test_checks_the_deferral_order() -> None:
    text = (SRC / "DuelSelfTest.as").read_text(encoding="utf-8")
    assert 'test.guard("deferred",test.checkDeferred)' in text
    check = function_body(text, "private function checkDeferred(")
    assert "new DuelDeferred()" in check and "takeNext()" in check


@needs_vanilla
def test_effects_at_the_end_of_simultaneous_fx_are_deferred(board: Path) -> None:
    # a scorch burns several cards at once and a mushroom morphs several berserkers at once: their FX end in an order
    # that depends on the board, so what each end does is queued too
    patched = (board / "CardInstance.as").read_text(encoding="utf-8")
    scorch = function_body(patched, "protected function onScorchFXEnd(")
    assert scorch.index("deferEffect(cardInstance,cardInstance.duelRunScorched)") < scorch.index("sendToGraveyard(")
    assert "sendToGraveyard(this)" in function_body(patched, "private function duelRunScorched(")
    morph = function_body(patched, "protected function morphFXEnded(")
    assert morph.index("deferEffect(cardInstance,cardInstance.duelRunMorphEffects)") < morph.index("updateEffectsApplied(")
    assert "updateEffectsApplied(this)" in function_body(patched, "private function duelRunMorphEffects(")
    leader = (board / "CardLeaderInstance.as").read_text(encoding="utf-8")
    assert "function onScorchFXEnd" not in leader and "playScorchEffectFX(scorchList[i],onScorchFXEnd)" in leader


@needs_vanilla
def test_perk_list_is_filled_before_the_message_is_pushed(board: Path) -> None:
    # review finding 1: PushMessage runs the first callback at once when nothing is showing
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    perk = function_body(flow, "private function duelPushPerk(")
    assert perk.index("_duelPerkPlayers.push(player)") < perk.index("PushMessage(")
    assert perk.index("_duelPerkKinds.push(kind)") < perk.index("PushMessage(")
    assert "first ? this.duelRunRoundStartPerks : null" in perk


@needs_vanilla
def test_deferred_fx_ends_skip_cards_that_left_the_rows(board: Path) -> None:
    # review finding 2: two scorches landing together target the same cards; only the first graveyard move counts
    patched = (board / "CardInstance.as").read_text(encoding="utf-8")
    guard = "DuelDeferred.stillOnBoard(this.inList,CardManager.getInstance().getCardInstance(this.instanceId) == this)"
    scorched = function_body(patched, "private function duelRunScorched(")
    assert scorched.index(guard) < scorched.index("sendToGraveyard(this)")
    morph = function_body(patched, "private function duelRunMorphEffects(")
    assert morph.index(guard) < morph.index("updateEffectsApplied(this)")
    deferred = (SRC / "DuelDeferred.as").read_text(encoding="utf-8")
    on_board = function_body(deferred, "public static function stillOnBoard(")
    for row in ("CARD_LIST_LOC_SEIGE", "CARD_LIST_LOC_RANGED", "CARD_LIST_LOC_MELEE"):
        assert row in on_board
    assert "exists &&" in on_board
    doc = deferred[deferred.rindex("/**", 0, deferred.index("stillOnBoard(")):deferred.index("stillOnBoard(")]
    assert "differs from vanilla" in doc
    self_test = (SRC / "DuelSelfTest.as").read_text(encoding="utf-8")
    assert "this.checkDoubleScorch()" in function_body(self_test, "private function checkDeferred(")
    check = function_body(self_test, "private function checkDoubleScorch(")
    assert "DuelDeferred.stillOnBoard(" in check and "double scorch moves each card once" in check
    assert "DuelDeferred.stillOnBoard(" in function_body(self_test, "private static function scorchMove(")
