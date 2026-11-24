"""Game-free integration test of the compiled Witcher Online UDP server."""
import argparse
import contextlib
import select
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def connect(stack, port):
    client = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
    client.bind(("127.0.0.1", 0))
    client.connect(("127.0.0.1", port))
    return client


def round_trip(clients, token, ids, requested=None, payload="x"):
    """All players must receive the current state of every active player."""
    names = {sock: name for name, sock in clients.items()}
    pending = {name: set(clients) for name in clients}
    requested = requested or {}
    deadline = time.monotonic() + 5
    next_send = 0
    while any(pending.values()):
        now = time.monotonic()
        check(now < deadline, f"round {token}: missing states {pending}")
        if now >= next_send:
            for name, sock in clients.items():
                fields = ["COOP"]
                if name in requested:
                    fields.append(str(requested[name]))
                fields.extend([name, "en", token, payload])
                sock.send("\t".join(fields).encode())
            next_send = now + 0.15
        ready, _, _ = select.select(list(names), [], [], 0.05)
        for sock in ready:
            fields = sock.recv(65536).decode().split("\t")
            if len(fields) != 6 or fields[0] != "COOP" or fields[3:5] != ["en", token]:
                continue
            sender = fields[2]
            check(sender in clients, f"unexpected sender {sender}")
            check(fields[5] == payload, f"corrupted state from {sender}")
            player_id = int(fields[1])
            check(player_id > 0, "invalid player ID")
            check(ids.setdefault(sender, player_id) == player_id,
                  f"player ID changed for {sender}")
            pending[names[sock]].discard(sender)
    check(len(set(ids.values())) == len(ids), f"duplicate player IDs: {ids}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("classes", type=Path, help="directory with the compiled Java classes")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="wo-udp-review-") as tmp, contextlib.ExitStack() as stack:
        root = Path(tmp)
        classes = root / "classes"
        shutil.copytree(args.classes.resolve(), classes)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        log = root / "server.log"
        with log.open("wb") as output:
            server = subprocess.Popen(["java", "-cp", str(classes), "WitcherServer", str(port)],
                                      cwd=root, stdin=subprocess.PIPE, stdout=output,
                                      stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while f"Starting Witcher Online server on *:{port}" not in log.read_text(errors="replace"):
                check(server.poll() is None, "server exited during startup")
                check(time.monotonic() < deadline, "server startup timed out")
                time.sleep(0.05)
            clients = {name: connect(stack, port) for name in ("Host", "Guest1", "Guest2")}
            ids = {}
            for i in range(20):
                round_trip(clients, f"initial-{i}", ids)
            print(f"PASS: 20 all-to-all updates per player, IDs {ids}", flush=True)
            round_trip(clients, "large", ids, payload="x" * 20000)
            print("PASS: 20 KB snapshots from all three players", flush=True)

            # Stop sending from Guest1 but keep the other two active until the real timeout.
            departed = clients.pop("Guest1")
            deadline = time.monotonic() + 12
            i = 0
            while "Timed out player Guest1;" not in log.read_text(errors="replace"):
                check(time.monotonic() < deadline, "Guest1 did not time out")
                round_trip(clients, f"survivors-{i}", ids)
                i += 1
                time.sleep(0.25)
            print(f"PASS: inactivity expired Guest1; {i} survivor rounds completed", flush=True)
            # Bind the replacement while the old socket is still open to guarantee a new port.
            replacement = connect(stack, port)
            check(replacement.getsockname() != departed.getsockname(), "endpoint did not change")
            departed.close()
            clients["Guest1"] = replacement
            for i in range(20):
                round_trip(clients, f"rejoined-{i}", ids, {"Guest1": ids["Guest1"]})
            check("Restored reserved username Guest1" in log.read_text(errors="replace"),
                  "rejoin did not restore the reserved username")
            print("PASS: new UDP endpoint, original player ID, all three players active", flush=True)
        finally:
            if server.poll() is None:
                try:
                    server.stdin.write(b"stop\n")
                    server.stdin.flush()
                    server.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    server.kill()
                    server.wait(timeout=5)
            server.stdin.close()
            print(log.read_text(errors="replace"))


if __name__ == "__main__":
    main()
