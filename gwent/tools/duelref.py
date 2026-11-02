"""Python reference for the Gwent duel primitives that the AS3 classes must match bit for bit.

Covers the seeded random streams (DuelRandom), the state hash accumulator (hash_words), the message
codec (encode, decode) and the opponent message window (Window).

usage:
  duelref.py vectors [--out <file>]   write the test vectors replayed by the in-game self-test
                                      (default: gwent/tests/vectors.json)

Wire format: six fields joined by ".":  version.matchId.seq.type.args.hash
  version  decimal protocol version, 1 to 9 digits, no leading zero
  matchId  lowercase hex of the seed, "g", game number (for example 1a2b3c4dg2)
  seq      positive decimal, 1 to 9 digits, no leading zero
  type     one of TYPES
  args     "_" when empty, else arguments joined by "," (each one of [A-Za-z0-9]+)
  hash     exactly 8 lowercase hex digits
Messages in a window are joined by "~". "none" stands for an empty window.
"""
import argparse
import json
import re
import sys
from collections.abc import Iterable, Sequence
from pathlib import Path
from typing import Any, TypedDict

STREAM_A = 0
STREAM_B = 1
STREAM_SHARED = 2
STREAM_COUNT = 3

PROTOCOL_VERSION = 1
TYPES = ("H", "P", "C", "G", "L", "S", "D", "M", "QUITGAME", "Y", "R", "X")
WINDOW_SEPARATOR = "~"
EMPTY_WINDOW = "none"

MASK32 = 0xFFFFFFFF
FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 16777619
ZERO_STATE_REPLACEMENT = 0x6D2B79F5
DEFAULT_VECTORS_PATH = Path(__file__).resolve().parent.parent / "tests" / "vectors.json"


def xorshift32(x: int) -> int:
    """One xorshift32 step (13, 17, 5) on a 32-bit value."""
    x ^= (x << 13) & MASK32
    x ^= x >> 17
    x ^= (x << 5) & MASK32
    return x


class DuelRandom:
    """Three independent xorshift32 streams (A, B, shared) derived from the match seed and game number."""

    def __init__(self, seed: int, game: int) -> None:
        self._states = [self._seed_stream(seed, game, stream) for stream in range(STREAM_COUNT)]

    @staticmethod
    def _seed_stream(seed: int, game: int, stream: int) -> int:
        """Derives the initial state of one stream and discards the first 8 outputs."""
        s = (seed ^ (((stream + 1) * 0x9E3779B9) & MASK32) ^ ((game * 0x85EBCA6B) & MASK32)) & MASK32
        if s == 0:
            s = ZERO_STATE_REPLACEMENT
        for _ in range(8):
            s = xorshift32(s)
        return s

    def next_uint(self, stream: int) -> int:
        """Advances the stream and returns the new state as a uint."""
        self._states[stream] = xorshift32(self._states[stream])
        return self._states[stream]

    def next_int(self, stream: int, n: int) -> int:
        """Returns a value in 0..n-1 by rejection sampling, so there is no modulo bias (n >= 1)."""
        limit = (2**32 // n) * n
        while True:
            v = self.next_uint(stream)
            if v < limit:
                return v % n


def hash_words(words: Iterable[int]) -> int:
    """FNV-1a over the words, each reduced to its uint form and fed as 4 little-endian bytes."""
    h = FNV_OFFSET
    for word in words:
        w = word & MASK32
        for shift in (0, 8, 16, 24):
            h ^= (w >> shift) & 0xFF
            h = (h * FNV_PRIME) & MASK32
    return h


class Message(TypedDict):
    """A decoded duel message."""

    version: int
    matchId: str
    seq: int
    type: str
    args: list[str]
    hash: int


_VERSION_RE = re.compile(r"[1-9][0-9]{0,8}")
_MATCH_ID_RE = re.compile(r"[0-9a-f]+g[0-9]+")
_ARG_RE = re.compile(r"[A-Za-z0-9]+")
_HASH_RE = re.compile(r"[0-9a-f]{8}")


def encode(msg: Message) -> str:
    """Encodes a message as one wire token. Raises ValueError when the message cannot round-trip."""
    args = ",".join(msg["args"]) if msg["args"] else "_"
    token = ".".join([str(msg["version"]), msg["matchId"], str(msg["seq"]), msg["type"], args,
                      format(msg["hash"] & MASK32, "08x")])
    if decode(token) is None:
        raise ValueError(f"message does not encode to a valid token: {token!r}")
    return token


def decode(token: str) -> Message | None:
    """Parses a wire token. Returns None for anything outside the grammar."""
    fields = token.split(".")
    if len(fields) != 6:
        return None
    version, match_id, seq, msg_type, args, hash_hex = fields
    if not (_VERSION_RE.fullmatch(version) and _MATCH_ID_RE.fullmatch(match_id)
            and _VERSION_RE.fullmatch(seq) and msg_type in TYPES and _HASH_RE.fullmatch(hash_hex)):
        return None
    arg_list: list[str] = []
    if args != "_":
        arg_list = args.split(",")
        if not all(_ARG_RE.fullmatch(a) for a in arg_list):
            return None
    return {"version": int(version), "matchId": match_id, "seq": int(seq), "type": msg_type,
            "args": arg_list, "hash": int(hash_hex, 16)}


class Window:
    """Receiving side of the message window: the opponent's messages, applied strictly in sequence order."""

    def __init__(self, match_id: str) -> None:
        self._match_id = match_id
        self._next_seq = 1
        self._queue: dict[int, Message] = {}

    def ingest(self, window: str) -> None:
        """Queues every well-formed message of this match and version that is neither applied nor queued."""
        for token in window.split(WINDOW_SEPARATOR):
            if token == EMPTY_WINDOW:
                continue
            msg = decode(token)
            if msg is None or msg["version"] != PROTOCOL_VERSION or msg["matchId"] != self._match_id:
                continue
            if msg["seq"] < self._next_seq or msg["seq"] in self._queue:
                continue
            self._queue[msg["seq"]] = msg

    def peek(self) -> Message | None:
        """The queued message with the next expected sequence number, or None."""
        return self._queue.get(self._next_seq)

    def pop(self) -> Message | None:
        """Removes and returns the next expected message and advances the expected sequence number."""
        msg = self._queue.pop(self._next_seq, None)
        if msg is not None:
            self._next_seq += 1
        return msg

    @property
    def gap(self) -> bool:
        """True when the next expected message is missing while a later one is queued."""
        return bool(self._queue) and min(self._queue) > self._next_seq


# ---------------------------------------------------------------------------------------------
# Test vectors
# ---------------------------------------------------------------------------------------------

VECTOR_SEEDS = (0, 1, 12345, 4000000000, 0xFFFFFFFF, 0x9E3779B9)  # last one makes the stream-A state 0
VECTOR_GAMES = (0, 1)
VECTOR_INT_BOUNDS = (1, 2, 7, 1000, 1431655766, 2147483647)  # the last two exercise rejection
VECTOR_COUNT = 8


def _random_vectors() -> dict[str, list[list[int]]]:
    """Rows of numbers: [seed, game, stream, v1..v8] and [seed, game, stream, n, v1..v8]."""
    uint_rows: list[list[int]] = []
    int_rows: list[list[int]] = []
    for seed in VECTOR_SEEDS:
        for game in VECTOR_GAMES:
            for stream in range(STREAM_COUNT):
                rng = DuelRandom(seed, game)
                uint_rows.append([seed, game, stream] + [rng.next_uint(stream) for _ in range(VECTOR_COUNT)])
                for n in VECTOR_INT_BOUNDS:
                    rng = DuelRandom(seed, game)
                    int_rows.append([seed, game, stream, n] + [rng.next_int(stream, n) for _ in range(VECTOR_COUNT)])
    return {"uint": uint_rows, "int": int_rows}


def _as_int32(value: int) -> int:
    """Reinterprets the low 32 bits as a signed int, like an AS3 int."""
    value &= MASK32
    return value - 2**32 if value >= 2**31 else value


def _hash_vectors() -> dict[str, list[Any]]:
    """Word lists (signed int32 values) and the expected hash of each."""
    state = 20261102
    long_list: list[int] = []
    for _ in range(50):
        state = (state * 1664525 + 1013904223) & MASK32
        long_list.append(_as_int32(state))
    words = [[], [1], [-1], [0], [2147483647, -2147483648], long_list]
    return {"words": words, "expected": [hash_words(w) for w in words]}


def _msg(match_id: str, seq: int, msg_type: str, args: Sequence[str], hash_value: int) -> Message:
    """Builds a current-version message."""
    return {"version": PROTOCOL_VERSION, "matchId": match_id, "seq": seq, "type": msg_type,
            "args": list(args), "hash": hash_value}


def _codec_vectors() -> dict[str, list[Any]]:
    """Valid tokens as rows [token, version, matchId, seq, type, argsCsv, hash] and malformed tokens."""
    examples = [
        ("1a2b3c4dg2", 1, "H", ["1a2b3c4d", "00ff00ff", "deadbeef"], 0),
        ("1a2b3c4dg2", 2, "P", ["A17", "3", "B"], 0x0BADF00D),
        ("0g0", 3, "C", ["A17", "B9"], 0xFFFFFFFF),
        ("ee6b2800g12", 4, "G", ["B65537"], 0x811C9DC5),
        ("1a2b3c4dg2", 5, "L", [], 1),
        ("1a2b3c4dg2", 6, "S", [], 0xDEADBEEF),
        ("1a2b3c4dg2", 7, "D", ["NUR", "A12", "B3"], 0x00000A0B),
        ("1a2b3c4dg2", 8, "D", ["LPICK", "perk", "t1234"], 0x12345678),
        ("1a2b3c4dg2", 9, "D", ["COIN", "coin", "1"], 0x9ABCDEF0),
        ("1a2b3c4dg2", 10, "D", ["LRES", "A1", "none"], 7),
        ("1a2b3c4dg2", 11, "M", [], 0x0000FFFF),
        ("1a2b3c4dg2", 12, "QUITGAME", [], 0x7FFFFFFF),
        ("1a2b3c4dg2", 13, "Y", ["deadbeef", "12"], 0x80000000),
        ("1a2b3c4dg2", 14, "R", [], 0x01020304),
        ("1a2b3c4dg2", 999999999, "X", [], 0xCAFEBABE),
    ]
    valid = []
    for match_id, seq, msg_type, args, hash_value in examples:
        msg = _msg(match_id, seq, msg_type, args, hash_value)
        valid.append([encode(msg), msg["version"], match_id, seq, msg_type, ",".join(args), hash_value])
    ok = "1a2b3c4dg2"
    malformed = [
        "",
        "none",
        "1.abc.x.P._.0",
        f"1.{ok}.1.S._",
        f"1.{ok}.1.S._.00000000.extra",
        f"1.{ok}.0.S._.00000000",
        f"1.{ok}.01.S._.00000000",
        f"1.{ok}.-1.S._.00000000",
        f"1.{ok}.x.S._.00000000",
        f"1.{ok}.1000000000.S._.00000000",
        f"1.{ok}.1.Z._.00000000",
        f"1.{ok}.1.p._.00000000",
        f"1.{ok}.1.P.A17,,B.00000000",
        f"1.{ok}.1.P..00000000",
        f"1.{ok}.1.P.A-17.00000000",
        f"1.{ok}.1.P.A17,.00000000",
        f"1.{ok}.1.S._.0000000G",
        f"1.{ok}.1.S._.0000000",
        f"1.{ok}.1.S._.000000000",
        f"1.{ok}.1.S._.0000000A",
        f"1.abcd.1.S._.00000000",
        f"1.1A2B3C4DG2.1.S._.00000000",
        f"x.{ok}.1.S._.00000000",
        f"0.{ok}.1.S._.00000000",
        f"1.{ok}.1.S._ .00000000",
        f"1.{ok}.1.S._.00000000~1.{ok}.2.S._.00000000",
    ]
    return {"valid": valid, "malformed": malformed}


def _window_vectors() -> list[dict[str, Any]]:
    """Scenarios as parallel per-step lists: window text, popped seqs (csv) after draining, and gap (0 or 1)."""
    mine = "1a2b3c4dg2"
    other = "ffffffffg9"

    def window(match_id: str, seqs: Iterable[int], version: int = PROTOCOL_VERSION) -> str:
        types = ("S", "P", "M")
        tokens = []
        for s in seqs:
            args = ["A17", "3", "B"] if types[s % 3] == "P" else []
            msg = _msg(match_id, s, types[s % 3], args, s * 2654435761 & MASK32)
            msg["version"] = version
            tokens.append(encode(msg))
        return WINDOW_SEPARATOR.join(tokens)

    def scenario(name: str, steps: list[tuple[str, list[int], int]]) -> dict[str, Any]:
        return {"name": name, "matchId": mine, "ingest": [s[0] for s in steps],
                "pops": [",".join(str(p) for p in s[1]) for s in steps], "gap": [s[2] for s in steps]}

    return [
        scenario("dedupe_and_gap", [
            (EMPTY_WINDOW, [], 0),
            (window(mine, range(1, 4)), [1, 2, 3], 0),
            (window(mine, range(1, 4)), [], 0),
            (window(mine, range(5, 8)), [], 1),
            (window(other, range(4, 6)), [], 1),
        ]),
        scenario("queued_dedupe_out_of_order", [
            (window(mine, range(2, 4)), [], 1),
            (window(mine, range(2, 4)), [], 1),
            (window(mine, range(1, 4)), [1, 2, 3], 0),
        ]),
        scenario("late_window_other_match", [
            (window(other, range(1, 5)), [], 0),
            (window(mine, range(1, 2)), [1], 0),
            (window(other, range(2, 6)), [], 0),
            (window(mine, range(1, 3)), [2], 0),
        ]),
        scenario("skips_ahead", [
            (window(mine, range(3, 5)), [], 1),
            (window(mine, range(3, 6)), [], 1),
            (window(mine, range(1, 6)), [1, 2, 3, 4, 5], 0),
        ]),
        scenario("sliding_window", [
            (window(mine, range(1, 3)), [1, 2], 0),
            (window(mine, range(1, 5)), [3, 4], 0),
            (window(mine, range(2, 6)), [5], 0),
            (window(mine, range(6, 26)), list(range(6, 26)), 0),
        ]),
        scenario("garbage_and_other_version", [
            ("", [], 0),
            (WINDOW_SEPARATOR.join([EMPTY_WINDOW, "junk", "1.abc.x.P._.0", window(mine, [1], version=2)]), [], 0),
            (WINDOW_SEPARATOR.join(["junk", window(mine, [1]), "", window(mine, [2], version=2)]), [1], 0),
            (window(mine, [1, 1, 2, 2]), [2], 0),
        ]),
    ]


def build_vectors() -> dict[str, Any]:
    """All test vectors, keyed random, hash, codec and window."""
    return {"random": _random_vectors(), "hash": _hash_vectors(), "codec": _codec_vectors(),
            "window": _window_vectors()}


def _is_scalar(value: Any) -> bool:
    return not isinstance(value, (list, dict))


def format_json(value: Any, indent: int = 0) -> str:
    """Pretty JSON that keeps lists of scalars on one line (wrapped at 200 columns) for readable rows."""
    pad = " " * (indent + 1)
    if isinstance(value, dict):
        items = [f'{pad}{json.dumps(k)}: {format_json(v, indent + 1)}' for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + " " * indent + "}"
    if isinstance(value, list):
        flat = json.dumps(value)
        if all(_is_scalar(v) for v in value) and indent + len(flat) <= 200:
            return flat
        items = [f"{pad}{format_json(v, indent + 1)}" for v in value]
        return "[\n" + ",\n".join(items) + "\n" + " " * indent + "]"
    return json.dumps(value)


def write_vectors(path: Path) -> None:
    """Writes the vectors file as ASCII with LF line endings and a trailing newline."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((format_json(build_vectors()) + "\n").encode("ascii"))


def main(argv: Sequence[str] | None = None) -> int:
    """Command line entry point."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    vec = sub.add_parser("vectors", help="write the test vectors file")
    vec.add_argument("--out", type=Path, default=DEFAULT_VECTORS_PATH)
    args = parser.parse_args(argv)
    write_vectors(args.out)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
