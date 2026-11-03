"""Tests for duel_logdiff.py, the comparison of two clients' duel logs (spec 14, "Log comparison")."""
import subprocess
import sys
from pathlib import Path

import duel_logdiff

TOOL_PATH = Path(__file__).resolve().parent.parent / "tools" / "duel_logdiff.py"

MATCH = "3039g0"
HELLO_A = f"1.{MATCH}.1.H.1a2b3c4d,0000beef,0000cafe.0badf00d"
HELLO_B = f"1.{MATCH}.1.H.1a2b3c4d,0000beef,0000cafe.0badf00d"
PASS_A = f"1.{MATCH}.2.S._.11112222"
PASS_B = f"1.{MATCH}.2.S._.33334444"


def log_lines(sent: list[str], applied: list[tuple[str, str]], rounds: list[tuple[int, str, str]], seat: str) -> str:
    """Builds a bot log in the w3test format, with the duel lines between other lines."""
    out = ["12:00:00.000 SCENARIO gwent_duel start", f"12:00:01.000 GwentDuel: DUEL HELLO ok seat={seat}"]
    stamp = 2
    for token in sent:
        out.append(f"12:00:{stamp:02d}.000 GwentDuel: DUEL SEND {token}")
        stamp += 1
    for token, mine in applied:
        out.append(f"12:00:{stamp:02d}.000 GwentDuel: DUEL APPLY {token} mine={mine}")
        stamp += 1
    for number, scores, digest in rounds:
        out.append(f"12:00:{stamp:02d}.000 GwentDuel: DUEL ROUND {number} scores={scores} hash={digest}")
        stamp += 1
    out.append(f"12:00:{stamp:02d}.000 GwentDuel: DUEL END result=draw reason=match game=0")
    out.append(f"12:00:{stamp:02d}.500 GWENT watch frames=10 board=none paused=false")
    return "\n".join(out) + "\n"


def mirrored_logs() -> tuple[str, str]:
    """Two logs of one match in which every message and round agrees."""
    rounds = [(1, "0,0", "aaaa0001"), (2, "0,0", "aaaa0002")]
    log_a = log_lines([HELLO_A, PASS_A], [(HELLO_B, "0badf00d"), (PASS_B, "33334444")], rounds, "A")
    log_b = log_lines([HELLO_B, PASS_B], [(HELLO_A, "0badf00d"), (PASS_A, "11112222")], rounds, "B")
    return log_a, log_b


def write_pair(tmp_path: Path, log_a: str, log_b: str) -> tuple[str, str]:
    """Writes both logs and returns their paths."""
    path_a, path_b = tmp_path / "BotA.log", tmp_path / "BotB.log"
    path_a.write_text(log_a, encoding="utf-8")
    path_b.write_text(log_b, encoding="utf-8")
    return str(path_a), str(path_b)


def test_logdiff_identical(tmp_path: Path, capsys) -> None:
    """Logs that mirror each other agree: exit 0."""
    path_a, path_b = write_pair(tmp_path, *mirrored_logs())
    assert duel_logdiff.main([path_a, path_b]) == 0
    out = capsys.readouterr().out
    assert "DIVERGED" not in out


def test_logdiff_hash_mismatch(tmp_path: Path, capsys) -> None:
    """One APPLY hash differs from the hash the sender put in the message: exit 1, the message names the seq."""
    log_a, log_b = mirrored_logs()
    log_b = log_b.replace(f"DUEL APPLY {PASS_A} mine=11112222", f"DUEL APPLY {PASS_A} mine=11112223")
    path_a, path_b = write_pair(tmp_path, log_a, log_b)
    assert duel_logdiff.main([path_a, path_b]) == 1
    out = capsys.readouterr().out
    assert "DIVERGED at seq=2:" in out


def test_logdiff_round_mismatch(tmp_path: Path, capsys) -> None:
    """One DUEL ROUND 2 hash differs: exit 1, the message names round=2."""
    log_a, log_b = mirrored_logs()
    log_b = log_b.replace("DUEL ROUND 2 scores=0,0 hash=aaaa0002", "DUEL ROUND 2 scores=0,0 hash=aaaa0003")
    path_a, path_b = write_pair(tmp_path, log_a, log_b)
    assert duel_logdiff.main([path_a, path_b]) == 1
    out = capsys.readouterr().out
    assert "DIVERGED at round=2:" in out


def test_logdiff_token_mismatch(tmp_path: Path, capsys) -> None:
    """The token one side applied is not the token the other sent with that seq: exit 1, names the seq."""
    log_a, log_b = mirrored_logs()
    changed = PASS_A.replace(".S._.", ".L._.")
    log_b = log_b.replace(f"DUEL APPLY {PASS_A} mine=11112222", f"DUEL APPLY {changed} mine=11112222")
    path_a, path_b = write_pair(tmp_path, log_a, log_b)
    assert duel_logdiff.main([path_a, path_b]) == 1
    assert "DIVERGED at seq=2:" in capsys.readouterr().out


def test_logdiff_applied_but_never_sent(tmp_path: Path, capsys) -> None:
    """An APPLY with no matching SEND on the other side is a divergence."""
    log_a, log_b = mirrored_logs()
    log_a = log_a.replace(f"GwentDuel: DUEL SEND {PASS_A}\n", "")
    path_a, path_b = write_pair(tmp_path, log_a, log_b)
    assert duel_logdiff.main([path_a, path_b]) == 1
    assert "DIVERGED at seq=2:" in capsys.readouterr().out


def test_logdiff_unapplied_tail_is_fine(tmp_path: Path) -> None:
    """A last message the other side never applied (the match ended first) is not a divergence."""
    log_a, log_b = mirrored_logs()
    log_b = log_b.replace(f"GwentDuel: DUEL APPLY {PASS_A} mine=11112222\n", "")
    path_a, path_b = write_pair(tmp_path, log_a, log_b)
    assert duel_logdiff.main([path_a, path_b]) == 0


def test_logdiff_round_missing(tmp_path: Path, capsys) -> None:
    """A round one side logged and the other did not is a divergence at that round."""
    log_a, log_b = mirrored_logs()
    log_b = log_b.replace("GwentDuel: DUEL ROUND 2 scores=0,0 hash=aaaa0002\n", "")
    path_a, path_b = write_pair(tmp_path, log_a, log_b)
    assert duel_logdiff.main([path_a, path_b]) == 1
    assert "DIVERGED at round=2:" in capsys.readouterr().out


def test_logdiff_command_line(tmp_path: Path) -> None:
    """The script runs on its own and reports through its exit code."""
    log_a, log_b = mirrored_logs()
    path_a, path_b = write_pair(tmp_path, log_a, log_b)
    ok = subprocess.run([sys.executable, "-I", str(TOOL_PATH), path_a, path_b], capture_output=True, text=True, check=False)
    assert ok.returncode == 0, ok.stdout + ok.stderr
    log_b = log_b.replace("DUEL ROUND 2 scores=0,0 hash=aaaa0002", "DUEL ROUND 2 scores=1,0 hash=aaaa0002")
    path_a, path_b = write_pair(tmp_path, log_a, log_b)
    bad = subprocess.run([sys.executable, "-I", str(TOOL_PATH), path_a, path_b], capture_output=True, text=True, check=False)
    assert bad.returncode == 1
    assert "DIVERGED at round=2:" in bad.stdout


def test_logdiff_missing_file(tmp_path: Path) -> None:
    """A log that does not exist is a usage error (exit 2), not a pass."""
    log_a, _ = mirrored_logs()
    path_a, _ = write_pair(tmp_path, log_a, log_a)
    assert duel_logdiff.main([path_a, str(tmp_path / "missing.log")]) == 2
