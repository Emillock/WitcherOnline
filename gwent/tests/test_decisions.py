"""Decisions, mulligan and coin toss (spec 8.2, 8.4, 9.3, 9.4, 9.6) against the patched board sources: every rules caller
of the choice dialog asks DuelSession.decide in a duel (or is listed as local only), both seats mulligan at once with
D MUL and M (seat-scope hashes, round 1 waits for both), the Scoia'tael choice goes over the wire as D COIN, and the
autoplay skip of Task 11 (R25) is gone."""
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
SCRIPTS = Path("red") / "game" / "witcher3"
GWINT = SCRIPTS / "menus" / "gwint"
DECISION_KINDS = {"MUL", "COIN", "NUR", "LRES", "LWEA", "LBIN", "LPICK"}

needs_vanilla = pytest.mark.skipif(not (VANILLA / GWINT).is_dir(),
                                   reason="no decompiled vanilla board (run build.py build first)")


@pytest.fixture(scope="module")
def board(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """The vanilla board with gwent/patches applied (the gwint package folder)."""
    target = tmp_path_factory.mktemp("board")
    shutil.copytree(VANILLA / "red", target / "red")
    build.apply_patches(target, PATCHES)
    return target / GWINT


def dialog_calls(root: Path) -> set[tuple[str, int]]:
    """Every line under root/red/game/witcher3 that calls one of the choice dialog's show functions."""
    found = set()
    for path in sorted((root / SCRIPTS).rglob("*.as")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if re.search(r"\bshowDialog\w*\(", line) and "function showDialog" not in line:
                found.add((path.name, number))
    return found


def caller_block() -> dict[tuple[str, int], str]:
    """The DuelSession comment block of dialog callers: (file name, line) -> decision kind or "local"."""
    text = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    start = text.index("Choice dialog callers")
    end = text.index("*/", start)
    entries = {}
    for file_stem, number, what in re.findall(r"- (\w+)\.as:(\d+) (\w+)", text[start:end]):
        entries[(file_stem + ".as", int(number))] = what
    return entries


@needs_vanilla
def test_every_vanilla_dialog_caller_is_listed_with_its_kind() -> None:
    listed = caller_block()
    vanilla = dialog_calls(VANILLA)
    assert sorted(vanilla - set(listed)) == []
    assert sorted(set(listed) - vanilla) == []
    for site, what in listed.items():
        assert what in DECISION_KINDS or what == "local", site
    kinds = set(listed.values())
    assert {"MUL", "NUR", "LRES", "LWEA", "LBIN", "LPICK"} <= kinds


@needs_vanilla
def test_medic_choice_asks_decide_before_the_ai_branch(board: Path) -> None:
    text = (board / "CardInstance.as").read_text(encoding="utf-8")
    nurse = text.index("Applying Nurse Effect")
    duel = text.index("this.duelDecideNurse(copyList)", nurse)
    assert duel < text.index("is AIPlayerController", nurse)
    assert 'decide("NUR"' in function_body(text, "function duelDecideNurse(")


@needs_vanilla
def test_leader_choices_ask_decide(board: Path) -> None:
    text = (board / "CardLeaderInstance.as").read_text(encoding="utf-8")
    assert 'duelDecide("LRES"' in function_body(text, "function resurrectGraveyard(")
    assert 'duelDecide("LWEA"' in function_body(text, "function pickWeather(")
    assert 'duelDecide("LBIN"' in function_body(text, "function askBin(")
    assert 'duelDecide("LPICK"' in function_body(text, "function askPick(")
    assert "DuelSession.active.decide(kind," in function_body(text, "private function duelDecide(")
    # the opponent-cards display stays local: only the leader's own board shows it, nothing is sent
    view = function_body(text, "function ApplyLeaderAbility(")
    assert "duelShowsEnemyHand()" in view
    assert "send(" not in function_body(text, "function duelShowsEnemyHand(")


@needs_vanilla
def test_mulligan_runs_for_both_seats(board: Path) -> None:
    text = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    accept = function_body(text, "function handleAcceptMulligan(")
    assert accept.index("duelSendRedraw(") < accept.index("mulliganCard(")
    assert "duelSendMulliganDone()" in function_body(text, "function handleDeclineMulligan(")
    assert "duelSendMulliganDone()" in accept
    update = function_body(text, "function state_update_Mulligan(")
    assert "mulligan.roundMayStart(" in update and "mulligan.close()" in update
    begin = function_body(text, "function state_begin_Mulligan(")
    assert begin.index("shuffleAndDrawCards()") < begin.index("mulligan.open()")
    session = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    redraw = function_body(session, "public function sendRedraw(")
    assert "send(DECISION,[MULLIGAN,ASKER_PERK," in redraw and "SCOPE_SEAT" in redraw
    assert 'MULLIGAN:String = "MUL"' in session
    assert "SCOPE_SEAT" in function_body(session, "public function sendMulliganDone(")
    dispatch = function_body(session, "private function dispatchMulligan(")
    assert "SCOPE_SEAT" in dispatch and "_mulligan.route(next)" in dispatch


@needs_vanilla
def test_scoiatael_choice_goes_over_the_wire(board: Path) -> None:
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    toss = function_body(flow, "function state_begin_CoinToss(")
    assert toss.index("duelScoiataelToss(") < toss.index("COIN_TOSS_POPUP_NEEDED")
    assert 'decide("COIN"' in function_body(flow, "function duelScoiataelToss(")
    assert "STREAM_SHARED" in toss
    menu = (board / "GwintGameMenu.as").read_text(encoding="utf-8")
    assert "duelCoinChosen(" in function_body(menu, "function setFirstTurn(")
    session = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    assert "kind == COIN" in function_body(session, "private function scopeOf(")


def test_decisions_and_mulligans_are_dispatched() -> None:
    text = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    dispatch = function_body(text, "private function dispatch(")
    assert dispatch.index("DECISION") < dispatch.index('"unsupported "')
    assert dispatch.index("MULLIGAN_DONE") < dispatch.index('"unsupported "')
    decide = function_body(text, "public function decide(")
    assert "localSeat" in decide and "_remoteDecision" in decide and "_localDecision" in decide
    remote = function_body(text, "private function dispatchDecision(")
    assert "checkApply(" in remote and "desync(" in remote and "DuelDecision.route(" in remote


@needs_vanilla
def test_a_pending_decision_holds_the_board(board: Path) -> None:
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    assert "decisionOpen" in function_body(flow, "function shouldDisallowStateChangeFunc(")
    human = (board / "HumanPlayerController.as").read_text(encoding="utf-8")
    assert "decisionOpen" in function_body(human, "override protected function cardEffectApplying(")
    net = (SRC / "NetOpponentController.as").read_text(encoding="utf-8")
    assert "decisionOpen" in function_body(net, "override protected function cardEffectApplying(")


@needs_vanilla
def test_autoplay_no_longer_skips_decisions(board: Path) -> None:
    text = (board / "HumanPlayerController.as").read_text(encoding="utf-8")
    assert "duelNeedsDecision" not in text
    assert "DUEL AUTOPLAY skip" not in text
    session = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    assert "DUEL AUTOPLAY decide " in function_body(session, "private function autoplay(")


def gwent_duel_script() -> str:
    """Witcher Online's duel script (it hands the test switches to the board)."""
    root = GWENT_DIR.parent / "witcher" / "mods" / "modWitcherOnline" / "content" / "scripts" / "local"
    return (root / "gwentDuel.ws").read_text(encoding="utf-8")


@needs_vanilla
def test_leader_first_test_switch(board: Path) -> None:
    """R32: gwint.game.debug.leaderFirst, registered before OnConfigUI, makes autoplay play a usable leader first."""
    menu = (board / "GwintGameMenu.as").read_text(encoding="utf-8")
    register = menu.index('"gwint.game.debug.leaderFirst"')
    assert register < menu.index('GameEvent.CALL,"OnConfigUI"')
    assert "this.duelDebugLeaderFirst = enabled" in function_body(menu, "function setDuelDebugLeaderFirst(")
    tick = function_body((board / "HumanPlayerController.as").read_text(encoding="utf-8"), "function duelAutoplayTick(")
    assert tick.index("DuelSession.active == null") < tick.index("duelDebugLeaderFirst")
    assert tick.index("duelSuggestMove()") < tick.index("duelDebugLeaderFirst") < tick.index("commitTransaction(")
    assert 'SetFlashBool("gwint.game.debug.leaderFirst", manager.duelDebugLeaderFirst)' in gwent_duel_script()


@needs_vanilla
def test_waiting_boards_say_so(board: Path) -> None:
    """R33: the board that waits for the opponent's coin choice or mulligan shows a message."""
    flow = (board / "GwintGameFlowController.as").read_text(encoding="utf-8")
    toss = function_body(flow, "function duelScoiataelToss(")
    assert "chooser == CardManager.PLAYER_2" in toss and "PushMessage(DUEL_COIN_WAIT_TEXT)" in toss
    update = function_body(flow, "function state_update_Mulligan(")
    assert "!DuelSession.active.mulligan.remoteDone" in update and "PushMessage(DUEL_MULLIGAN_WAIT_TEXT)" in update
    assert 'DUEL_MULLIGAN_WAIT_TEXT:String = "Waiting for your opponent"' in flow


def test_second_decide_is_documented() -> None:
    """R34: a second decide while one is open stays a local desync, and the reason is written down (Task 13: cards
    landing together, such as two birna_bran medics of the Skellige round 3 perk, ask one after the other because
    their effects are deferred)."""
    text = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    decide = function_body(text, "public function decide(")
    assert 'localDesync("decision " + kind + " while another is open")' in decide
    doc = text[text.rindex("/**", 0, text.index("public function decide(")):text.index("public function decide(")]
    assert "R34" in doc and "deferEffect" in doc and "birna_bran" in doc


def test_decisions_are_typed() -> None:
    """Finding 6: the open decisions are DuelDecision instances, not Objects."""
    text = (SRC / "DuelSession.as").read_text(encoding="utf-8")
    assert "private var _localDecision:DuelDecision;" in text
    assert "private var _remoteDecision:DuelDecision;" in text
    assert ":Object = {" not in text
    assert "public class DuelDecision" in (SRC / "DuelDecision.as").read_text(encoding="utf-8")
    assert "public class DuelMulligan" in (SRC / "DuelMulligan.as").read_text(encoding="utf-8")


def test_self_test_runs_the_routing() -> None:
    """Finding 5: DuelSelfTest feeds synthetic D and M through the routing (it runs in game, gwent_selftest)."""
    text = (SRC / "DuelSelfTest.as").read_text(encoding="utf-8")
    assert 'test.guard("decisions",test.checkDecisions)' in text
    body = function_body(text, "private function checkDecisions(")
    for needle in ("DuelDecision.route(nur,null,null,true) == DuelDecision.WAIT",
                   "DuelDecision.route(nur,remote,null,false) == DuelDecision.WAIT",
                   "another kind", "another asker", "while the local player decides", "a move while a D is awaited",
                   "a third redraw", "local done first", "opponent done first", "after round 1 started"):
        assert needle in body, needle


@needs_vanilla
def test_mulligan_guard_sends_outside_the_condition(board: Path) -> None:
    """Finding 7: the redraw guard has no mixed && / || and the send is a statement of its own."""
    accept = function_body((board / "GwintGameFlowController.as").read_text(encoding="utf-8"),
                           "function handleAcceptMulligan(")
    assert "var duelMayRedraw:Boolean = this.duelSendRedraw(selectedCard);" in accept
    assert "if(!duelMayRedraw)" in accept
    assert "&& this._mulliganDecided ||" not in accept


@needs_vanilla
def test_leader_routing_relies_on_is_ai_false(board: Path) -> None:
    """Finding 8: neither duel controller sets isAI, so ApplyLeaderAbility takes the human branches on both boards."""
    net = (SRC / "NetOpponentController.as").read_text(encoding="utf-8")
    human = (board / "HumanPlayerController.as").read_text(encoding="utf-8")
    assert re.search(r"\bisAI\s*=", net) is None
    assert re.search(r"\bisAI\s*=", human) is None
    assert "protected var isAI:Boolean = false;" in (board / "BasePlayerController.as").read_text(encoding="utf-8")
    leader = (board / "CardLeaderInstance.as").read_text(encoding="utf-8")
    at = leader.index("private function duelDecide(")
    assert "isAI false for both seats" in leader[leader.rindex("/**", 0, at):at]


def test_autoplay_mulligan_logs_what_it_did() -> None:
    """Finding 9: the autoplay mulligan line says decline when it declined."""
    body = function_body((SRC / "DuelSession.as").read_text(encoding="utf-8"), "private function autoplay(")
    assert '(flow.duelAutoMulligan(menu.duelDebugMulligan) ? "redraw" : "decline")' in body
