"""Tests for vectors.py: the generated DuelVectors.as carries every vector of vectors.json, exactly."""
import json
import re
from pathlib import Path
from typing import Any

import pytest

import vectors

GWENT_DIR = Path(__file__).resolve().parent.parent
VECTORS_JSON = GWENT_DIR / "tests" / "vectors.json"
DUEL_VECTORS_AS = GWENT_DIR / "src" / "DuelVectors.as"
ARRAYS = ("RANDOM", "HASH", "CODEC", "CODEC_MALFORMED", "WINDOW")
INT32_MIN = -2**31
UINT32_MAX = 2**32 - 1


def _load_json() -> dict[str, Any]:
    return json.loads(VECTORS_JSON.read_text(encoding="ascii"))


def _rows(source: str, name: str) -> list[Any]:
    """Parses the rows of one generated array: one JSON-compatible AS3 literal per line."""
    match = re.search(rf"public static function get {name}\(\) : Array\n\s*\{{\n\s*return \[\n(.*?)\n\s*\];",
                      source, re.DOTALL)
    assert match, f"DuelVectors.as does not declare {name}"
    lines = [line.strip() for line in match.group(1).splitlines()]
    return [json.loads(line.rstrip(",")) for line in lines if line]


@pytest.fixture(scope="module")
def generated() -> str:
    assert DUEL_VECTORS_AS.is_file(), "gwent/src/DuelVectors.as is missing (run gwent/build/vectors.py)"
    return DUEL_VECTORS_AS.read_text(encoding="ascii")


def test_declares_every_array_with_the_vector_counts(generated: str) -> None:
    data = _load_json()
    expected = {
        "RANDOM": len(data["random"]["uint"]) + len(data["random"]["int"]),
        "HASH": len(data["hash"]["words"]),
        "CODEC": len(data["codec"]["valid"]),
        "CODEC_MALFORMED": len(data["codec"]["malformed"]),
        "WINDOW": sum(len(scenario["ingest"]) for scenario in data["window"]),
    }
    counts = {name: len(_rows(generated, name)) for name in ARRAYS}
    assert counts == expected
    assert counts == {"RANDOM": 252, "HASH": 6, "CODEC": 15, "CODEC_MALFORMED": 26, "WINDOW": 23}


def test_rows_carry_the_vectors_exactly(generated: str) -> None:
    data = _load_json()
    uint_rows = [row[:3] + [0] + row[3:] for row in data["random"]["uint"]]
    assert _rows(generated, "RANDOM") == uint_rows + data["random"]["int"]
    assert _rows(generated, "HASH") == [
        [expected] + words for expected, words in zip(data["hash"]["expected"], data["hash"]["words"])]
    assert _rows(generated, "CODEC") == data["codec"]["valid"]
    assert _rows(generated, "CODEC_MALFORMED") == data["codec"]["malformed"]
    window = []
    for index, scenario in enumerate(data["window"]):
        for step in range(len(scenario["ingest"])):
            window.append([index, scenario["name"], scenario["matchId"], scenario["ingest"][step],
                           scenario["pops"][step], scenario["gap"][step]])
    assert _rows(generated, "WINDOW") == window


def test_numbers_are_plain_integer_literals(generated: str) -> None:
    """Big uints stay exact in AS3 only as integer literals (no exponent, no fraction)."""
    numbers = [value for name in ("RANDOM", "HASH", "CODEC") for row in _rows(generated, name)
               for value in row if not isinstance(value, str)]
    assert numbers and all(isinstance(value, int) and INT32_MIN <= value <= UINT32_MAX for value in numbers)
    assert max(numbers) == UINT32_MAX


def test_generated_file_is_current(generated: str) -> None:
    assert vectors.render(_load_json()) == generated.replace("\r\n", "\n")


def test_render_is_ascii_and_declares_the_class() -> None:
    text = vectors.render(_load_json())
    text.encode("ascii")
    assert "package red.game.witcher3.menus.gwint" in text
    assert "public class DuelVectors" in text
    assert "/**" in text
