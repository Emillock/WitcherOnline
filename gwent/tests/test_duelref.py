"""Tests for the Python reference of the duel random streams, hash, codec and message window."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

import duelref
from duelref import STREAM_A, STREAM_B, STREAM_SHARED, DuelRandom, Window, decode, encode, hash_words

VECTORS_PATH = Path(__file__).resolve().parent / "vectors.json"
TOOL_PATH = Path(__file__).resolve().parent.parent / "tools" / "duelref.py"
MASK32 = 0xFFFFFFFF
CRLF = bytes([13, 10])
LF = bytes([10])


def independent_uints(seed: int, game: int, stream: int, count: int) -> list[int]:
    """Re-derives the stream with unbounded Python ints (multiplication, floor division), sharing no code with duelref."""
    s = (seed ^ (((stream + 1) * 0x9E3779B9) % 2**64) ^ ((game * 0x85EBCA6B) % 2**64)) & MASK32
    if s == 0:
        s = 0x6D2B79F5
    out = []
    for step in range(8 + count):
        s = (s ^ (s * 8192)) & MASK32
        s = s ^ (s // 131072)
        s = (s ^ (s * 32)) & MASK32
        if step >= 8:
            out.append(s)
    return out


def fnv1a(data: bytes) -> int:
    """Plain byte-wise FNV-1a, 32 bit."""
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 16777619) % 2**32
    return h


@pytest.fixture(scope="module")
def vectors() -> dict:
    """The checked-in vectors file."""
    return json.loads(VECTORS_PATH.read_text(encoding="ascii"))


def test_random_first_values(vectors):
    expected = independent_uints(1, 0, STREAM_A, 3)
    rng = DuelRandom(1, 0)
    assert [rng.next_uint(STREAM_A) for _ in range(3)] == expected
    row = next(r for r in vectors["random"]["uint"] if r[:3] == [1, 0, STREAM_A])
    assert row[3:6] == expected


def test_random_zero_state_guard():
    seed = 0x9E3779B9  # seed ^ stream-0 constant == 0 for game 0
    rng = DuelRandom(seed, 0)
    assert [rng.next_uint(STREAM_A) for _ in range(3)] == independent_uints(seed, 0, STREAM_A, 3)


def test_next_int_range():
    rng = DuelRandom(42, 3)
    draws = [rng.next_int(STREAM_B, 7) for _ in range(10000)]
    assert min(draws) == 0
    assert max(draws) == 6


def test_next_int_rejects_biased_tail():
    n = 1431655766  # 2**32 // n == 2, so about a third of raw draws are rejected
    limit = (2**32 // n) * n
    rng = DuelRandom(5, 1)
    raw = independent_uints(5, 1, STREAM_SHARED, 40)
    expected = [v % n for v in raw if v < limit][:10]
    assert [rng.next_int(STREAM_SHARED, n) for _ in range(10)] == expected
    assert len(expected) < len(raw)


def test_next_int_one_is_zero():
    rng = DuelRandom(9, 0)
    assert {rng.next_int(STREAM_A, 1) for _ in range(20)} == {0}


def test_streams_independent():
    mixed = DuelRandom(7, 0)
    for _ in range(25):
        mixed.next_uint(STREAM_A)
    fresh = DuelRandom(7, 0)
    assert mixed.next_uint(STREAM_B) == fresh.next_uint(STREAM_B)
    assert mixed.next_uint(STREAM_SHARED) == fresh.next_uint(STREAM_SHARED)
    streams = [DuelRandom(7, 0).next_uint(s) for s in (STREAM_A, STREAM_B, STREAM_SHARED)]
    assert len(set(streams)) == 3


def test_games_differ():
    assert DuelRandom(7, 0).next_uint(STREAM_A) != DuelRandom(7, 1).next_uint(STREAM_A)


def test_hash_known():
    assert hash_words([]) == 0x811C9DC5
    assert hash_words([1]) == fnv1a(bytes([1, 0, 0, 0]))
    assert hash_words([0x04030201]) == fnv1a(bytes([1, 2, 3, 4]))
    assert hash_words([1, 2]) == fnv1a(bytes([1, 0, 0, 0, 2, 0, 0, 0]))


def test_hash_negative_words_use_uint_form():
    assert hash_words([-1]) == hash_words([0xFFFFFFFF]) == fnv1a(b"\xff\xff\xff\xff")
    assert hash_words([-2147483648]) == fnv1a(bytes([0, 0, 0, 0x80]))


MESSAGES = {
    "H": ["1a2b3c4d", "00ff00ff", "deadbeef"],
    "P": ["A17", "3", "B"],
    "C": ["A17", "B9"],
    "G": ["A4"],
    "L": [],
    "S": [],
    "D": ["NUR", "A12", "B3"],
    "M": [],
    "QUITGAME": ["1"],
    "Y": ["deadbeef", "12"],
    "R": [],
    "X": [],
}


def message_of(msg_type: str, seq: int = 5) -> dict:
    """Builds a valid message of the given type."""
    return {"version": 1, "matchId": "1a2b3c4dg2", "seq": seq, "type": msg_type,
            "args": list(MESSAGES[msg_type]), "hash": 0x0BADF00D}


def test_codec_covers_every_type():
    assert set(MESSAGES) == set(duelref.TYPES)


@pytest.mark.parametrize("msg_type", sorted(MESSAGES))
def test_codec_roundtrip(msg_type):
    msg = message_of(msg_type)
    token = encode(msg)
    assert decode(token) == msg
    assert " " not in token and "~" not in token


def test_codec_wire_shape():
    assert encode(message_of("P")) == "1.1a2b3c4dg2.5.P.A17,3,B.0badf00d"
    assert encode(message_of("S")) == "1.1a2b3c4dg2.5.S._.0badf00d"


def test_codec_surrender_contains_quitgame():
    assert "QUITGAME" in encode(message_of("QUITGAME"))


def test_codec_surrender_carries_settles_flag():
    """QUITGAME has exactly one argument: 1 if the quitter settles (its Hello was complete), else 0."""
    for flag in ("0", "1"):
        msg = {**message_of("QUITGAME"), "args": [flag]}
        assert decode(encode(msg)) == msg
    for args in ("_", "2", "1,0", "11", "A1"):
        assert decode(f"1.1a2b3c4dg2.5.QUITGAME.{args}.0badf00d") is None, args
    with pytest.raises(ValueError):
        encode({**message_of("QUITGAME"), "args": []})


def test_codec_rejects_malformed():
    assert decode("1.abc.x.P._.0") is None
    for token in ["", "none", "1.a1g1.1.P._", "1.a1g1.1.P._.00000000.x", "1.a1g1.0.S._.00000000",
                  "1.a1g1.1.Z._.00000000", "1.a1g1.1.P.A17,,B.00000000", "1.a1g1.1.P..00000000",
                  "1.a1g1.1.P._.0000000G", "1.a1g1.1.P._.0000000"]:
        assert decode(token) is None, token


def test_encode_rejects_invalid_message():
    for patch in [{"type": "Z"}, {"seq": 0}, {"args": ["a b"]}, {"args": [""]}, {"matchId": "abc"}]:
        with pytest.raises(ValueError):
            encode({**message_of("S"), **patch})


def make_window_tokens(match_id: str, seqs: range, version: int = 1) -> list[str]:
    """Encodes pass messages for the given sequence numbers."""
    return [encode({"version": version, "matchId": match_id, "seq": s, "type": "S", "args": [], "hash": s})
            for s in seqs]


def drain(window: Window) -> list[int]:
    """Pops everything currently available and returns the sequence numbers."""
    out = []
    while window.peek() is not None:
        out.append(window.pop()["seq"])
    return out


def test_window_dedupe_and_gap():
    mine = "1a2b3c4dg2"
    window = Window(mine)
    first = "~".join(make_window_tokens(mine, range(1, 4)))
    window.ingest("none")
    assert window.peek() is None and not window.gap
    window.ingest(first)
    window.ingest(first)
    window.ingest("~".join(make_window_tokens(mine, range(5, 8))))
    assert drain(window) == [1, 2, 3]
    assert window.peek() is None
    assert window.gap is True
    window.ingest("~".join(make_window_tokens("ffffffffg9", range(4, 6))))
    assert window.peek() is None and window.gap is True
    window.ingest(first)
    assert drain(window) == []


def test_window_gap_clears_when_missing_arrives():
    mine = "1a2b3c4dg2"
    window = Window(mine)
    window.ingest("~".join(make_window_tokens(mine, range(2, 4))))
    assert window.gap is True and window.peek() is None
    window.ingest("~".join(make_window_tokens(mine, range(1, 4))))
    assert window.gap is False
    assert drain(window) == [1, 2, 3]


def test_window_ignores_garbage_and_other_version():
    mine = "1a2b3c4dg2"
    window = Window(mine)
    junk = ["", "none", "junk", *make_window_tokens(mine, range(1, 2), version=2)]
    window.ingest("~".join(junk))
    assert window.peek() is None and not window.gap
    window.ingest("~".join(make_window_tokens(mine, range(1, 2))))
    assert drain(window) == [1]


def test_vectors_replay_against_reference(vectors):
    assert set(vectors) == {"random", "hash", "codec", "window"}
    for row in vectors["random"]["uint"]:
        seed, game, stream, *values = row
        rng = DuelRandom(seed, game)
        assert [rng.next_uint(stream) for _ in values] == values
        assert values == independent_uints(seed, game, stream, len(values))
    for row in vectors["random"]["int"]:
        seed, game, stream, n, *values = row
        rng = DuelRandom(seed, game)
        assert [rng.next_int(stream, n) for _ in values] == values
    assert len(vectors["hash"]["words"]) == len(vectors["hash"]["expected"])
    for words, expected in zip(vectors["hash"]["words"], vectors["hash"]["expected"]):
        assert hash_words(words) == expected
    assert {row[4] for row in vectors["codec"]["valid"]} == set(duelref.TYPES)
    for token, version, match_id, seq, msg_type, args_csv, hash_value in vectors["codec"]["valid"]:
        msg = decode(token)
        assert msg == {"version": version, "matchId": match_id, "seq": seq, "type": msg_type,
                       "args": args_csv.split(",") if args_csv else [], "hash": hash_value}
        assert encode(msg) == token
    assert len(vectors["codec"]["malformed"]) >= 8
    for token in vectors["codec"]["malformed"]:
        assert decode(token) is None, token
    for scenario in vectors["window"]:
        window = Window(scenario["matchId"])
        steps = zip(scenario["ingest"], scenario["pops"], scenario["gap"])
        for ingest, pops, gap in steps:
            window.ingest(ingest)
            assert ",".join(str(s) for s in drain(window)) == pops, scenario["name"]
            assert window.gap == bool(gap), scenario["name"]


def test_vectors_file_is_current(tmp_path):
    out = tmp_path / "vectors.json"
    subprocess.run([sys.executable, "-I", str(TOOL_PATH), "vectors", "--out", str(out)], check=True)
    expected = VECTORS_PATH.read_bytes().replace(CRLF, LF)  # tolerate autocrlf checkouts
    assert out.read_bytes() == expected
