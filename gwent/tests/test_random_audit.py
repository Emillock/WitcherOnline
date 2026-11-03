"""The Math.random audit (spec 7.3) against the board: the audit block in DuelRandom.as names every Math.random of the
decompiled vanilla board, and after our patches only the sites it calls "local only" still use Math.random."""
import re
import shutil
from pathlib import Path

import pytest

import build

GWENT_DIR = Path(__file__).resolve().parent.parent
VANILLA = GWENT_DIR / "work" / "vanilla"
DUEL_RANDOM = GWENT_DIR / "src" / "DuelRandom.as"
PATCHES = GWENT_DIR / "patches"
SCRIPTS = Path("red") / "game" / "witcher3"
# stream sites whose vanilla line stays in the single-player branch next to the duel branch (the coin toss, R17)
VANILLA_BRANCH_KEPT = {("GwintGameFlowController.as", 298)}

needs_vanilla = pytest.mark.skipif(not (VANILLA / SCRIPTS).is_dir(),
                                   reason="no decompiled vanilla board (run build.py build first)")


def random_lines(root: Path) -> dict[tuple[str, int], str]:
    """Every line with Math.random under root/red/game/witcher3: (file name, line number) -> stripped text."""
    found = {}
    for path in sorted((root / SCRIPTS).rglob("*.as")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if "Math.random" in line:
                found[(path.name, number)] = line.strip()
    return found


def audit_sections() -> dict[str, set[tuple[str, int]]]:
    """The (file name, line) pairs the DuelRandom audit lists under "Stream" and under "Local only"."""
    text = DUEL_RANDOM.read_text(encoding="utf-8")
    start = text.index("Math.random audit")
    stream_at = text.index("Stream (", start)
    local_at = text.index("Local only:", stream_at)
    end = text.index("*/", local_at)
    sections = {"stream": text[stream_at:local_at], "local": text[local_at:end]}
    result = {}
    for name, body in sections.items():
        pairs = set()
        for file_stem, numbers in re.findall(r"(\w+)\.as:([0-9 ,/()]+)", body):
            for number in re.findall(r"\d+", re.sub(r"\(\d+\)", "", numbers)):
                pairs.add((file_stem + ".as", int(number)))
        result[name] = pairs
    return result


@needs_vanilla
def test_audit_names_every_vanilla_math_random() -> None:
    sections = audit_sections()
    listed = sections["stream"] | sections["local"]
    vanilla = set(random_lines(VANILLA))
    assert len(vanilla) == 33
    assert sorted(vanilla - listed) == []
    assert sorted(listed - vanilla) == []


@needs_vanilla
def test_only_local_sites_keep_math_random_after_the_patches(tmp_path: Path) -> None:
    target = tmp_path / "board"
    shutil.copytree(VANILLA / "red", target / "red")
    build.apply_patches(target, PATCHES)
    by_text: dict[str, set[tuple[str, int]]] = {}
    for site, text in random_lines(VANILLA).items():
        by_text.setdefault(text, set()).add(site)
    local = audit_sections()["local"]
    left = []
    for (file_name, number), text in random_lines(target).items():
        if text.startswith("*"):
            continue  # a doc comment that names Math.random
        sites = {site for site in by_text.get(text, set()) if site[0] == file_name}
        if not sites or not sites <= local | VANILLA_BRANCH_KEPT:
            left.append(f"{file_name}:{number}: {text}")
    assert left == []


@needs_vanilla
def test_stream_sites_draw_through_duel_session(tmp_path: Path) -> None:
    target = tmp_path / "board"
    shutil.copytree(VANILLA / "red", target / "red")
    build.apply_patches(target, PATCHES)
    gwint = target / SCRIPTS / "menus" / "gwint"
    expected = {
        "GwintDeck.as": ["DuelSession.randomInt(ownerPlayer,originalIndices.length)",
                         "DuelSession.randomInt(ownerPlayer,this.cardIndicesInDeck.length)"],
        "CardManager.as": ["DuelSession.randomInt(playerIndex,elligibleCardList.length)",
                           "DuelSession.randomInt(stolenPlayerId,enemyHandCardList.length)",
                           "DuelSession.randomInt(playerID,elligibleCardListFromOpponentsGrave.length)",
                           "shuffleDeck(player2Deck.originalStength(),PLAYER_1)",
                           "shuffleDeck(player1Deck.originalStength(),PLAYER_2)",
                           "readdCard(cardInstance.templateId,true,listPlayer)",
                           "function hasCreatureToExclude("],
        "CardInstance.as": ["DuelSession.randomInt(this.owningPlayer,copyList.length)",
                            "DuelSession.randomInt(this.owningPlayer,2)",
                            "this.duelPlaceResurrected(cardManagerRef,cardInstance)"],
        "CardLeaderInstance.as": ["DuelSession.randomInt(owningPlayer,cardsInGraveyard.length)"],
        "GwintGameFlowController.as": ["random.nextInt(DuelRandom.STREAM_SHARED,2)",
                                       "this.cardManager.hasCreatureToExclude(CardManager.PLAYER_1) || "
                                       "this.cardManager.hasCreatureToExclude(CardManager.PLAYER_2)"],
    }
    missing = [f"{name}: {needle}" for name, needles in expected.items()
               for needle in needles if needle not in (gwint / name).read_text(encoding="utf-8")]
    assert missing == []
