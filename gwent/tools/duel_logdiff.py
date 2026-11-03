"""Compares the duel logs of the two clients of one Gwent duel and reports the first step where they differ.

usage:
  duel_logdiff.py <logA> <logB>

Each log is any text file that holds the board's pinned duel lines (for example a w3test bot log, where they
appear as "<time> GwentDuel: DUEL ..."); everything else in it is ignored:
  DUEL SEND <token>
  DUEL APPLY <token> mine=<hashHex8>
  DUEL ROUND <n> scores=<a>,<b> hash=<hashHex8>

Checks, messages first, then rounds:
  - for each direction (A to B, B to A) and each seq the receiver applied: the receiver applied exactly the token the
    sender sent with that seq, and the receiver's own hash (mine=) equals the hash in the token. A message the
    receiver never applied is fine (the match ended first).
  - the n-th DUEL ROUND line of both logs has the same round number, scores and hash, and both logs have the same
    number of rounds.

Exit codes: 0 when everything agrees, 1 with "DIVERGED at <seq=n|round=n>: <detail>" on the first difference,
2 when a log cannot be read.
"""
import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SEND_RE = re.compile(r"DUEL SEND (\S+)")
APPLY_RE = re.compile(r"DUEL APPLY (\S+) mine=([0-9a-f]{8})")
ROUND_RE = re.compile(r"DUEL ROUND (\d+) scores=(\S+) hash=([0-9a-f]{8})")


@dataclass(frozen=True)
class Round:
    """One DUEL ROUND line."""
    number: int
    scores: str
    digest: str


@dataclass
class DuelLog:
    """The duel lines of one client's log."""
    sent: dict[int, str]
    applied: dict[int, tuple[str, str]]
    rounds: list[Round]


def token_seq(token: str) -> int:
    """The seq field of a wire token (version.matchId.seq.type.args.hash), or -1 if it has none."""
    fields = token.split(".")
    return int(fields[2]) if len(fields) == 6 and fields[2].isdigit() else -1


def token_hash(token: str) -> str:
    """The hash field of a wire token."""
    return token.split(".")[-1]


def parse(text: str) -> DuelLog:
    """Collects the SEND, APPLY and ROUND lines of a log."""
    log = DuelLog(sent={}, applied={}, rounds=[])
    for line in text.splitlines():
        if match := APPLY_RE.search(line):
            log.applied[token_seq(match.group(1))] = (match.group(1), match.group(2))
        elif match := SEND_RE.search(line):
            log.sent[token_seq(match.group(1))] = match.group(1)
        elif match := ROUND_RE.search(line):
            log.rounds.append(Round(int(match.group(1)), match.group(2), match.group(3)))
    return log


def message_divergences(sender: DuelLog, receiver: DuelLog, names: str) -> list[tuple[int, str]]:
    """Every (seq, detail) where `receiver` applied something other than what `sender` sent, in seq order."""
    found = []
    for seq in sorted(receiver.applied):
        token, mine = receiver.applied[seq]
        sent = sender.sent.get(seq)
        if sent is None:
            found.append((seq, f"{names}: applied {token} that was never sent"))
        elif sent != token:
            found.append((seq, f"{names}: sent {sent}, applied {token}"))
        elif token_hash(token) != mine:
            found.append((seq, f"{names}: sender hash {token_hash(token)}, receiver mine={mine} ({token})"))
    return found


def round_divergence(log_a: DuelLog, log_b: DuelLog) -> str | None:
    """The first round line that differs, as "round=<n>: <detail>", or None."""
    for index in range(max(len(log_a.rounds), len(log_b.rounds))):
        mine = log_a.rounds[index] if index < len(log_a.rounds) else None
        theirs = log_b.rounds[index] if index < len(log_b.rounds) else None
        if mine is None or theirs is None:
            present = mine or theirs
            missing = "A" if mine is None else "B"
            return f"round={present.number}: logged by one client only (missing in {missing})"
        if mine != theirs:
            return (f"round={mine.number}: A scores={mine.scores} hash={mine.digest}, "
                    f"B round {theirs.number} scores={theirs.scores} hash={theirs.digest}")
    return None


def compare(log_a: DuelLog, log_b: DuelLog) -> str | None:
    """The first divergence between the two logs ("seq=<n>: ..." or "round=<n>: ..."), or None."""
    found = message_divergences(log_a, log_b, "A to B") + message_divergences(log_b, log_a, "B to A")
    if found:
        seq, detail = min(found)
        return f"seq={seq}: {detail}"
    return round_divergence(log_a, log_b)


def main(argv: list[str] | None = None) -> int:
    """Command line entry point; returns the exit code."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log_a", type=Path)
    parser.add_argument("log_b", type=Path)
    args = parser.parse_args(argv)
    logs = []
    for path in (args.log_a, args.log_b):
        try:
            logs.append(parse(path.read_text(encoding="utf-8", errors="replace")))
        except OSError as exc:
            print(f"error: cannot read {path}: {exc}", file=sys.stderr)
            return 2
    log_a, log_b = logs
    divergence = compare(log_a, log_b)
    if divergence:
        print(f"DIVERGED at {divergence}")
        return 1
    print(f"OK: {len(log_a.applied)} + {len(log_b.applied)} applied messages and {len(log_a.rounds)} rounds agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
