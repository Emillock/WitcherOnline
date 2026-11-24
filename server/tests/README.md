# Server tests

Run from the repository root with JDK 21 and Python 3:

```sh
mkdir -p server/build/test
javac -encoding UTF-8 -Xlint:all -d server/build/test server/src/*.java server/tests/*.java
java -cp server/build/test SessionTimeoutTest
java -cp server/build/test CoopOrderingTest
java -cp server/build/test SessionLockScopeTest
python3 server/tests/udp_review_test.py server/build/test
```

The timeout regression exercises stale cleanup decisions with synthetic timestamps.
The co-op test checks channel ordering and the existing channel-capacity behavior.
The session-lock test pauses one player's UDP send and verifies that another player
can send, that a console kick for another player proceeds, and that a kick for the
first player waits for its in-flight update.
The UDP test runs the real Java server with three loopback clients; one disconnects
and rejoins with its original ID while the others keep exchanging updates.

To check that the session-lock test really pins the behaviour rather than merely
passing, build it against the server as it was before the change and watch it fail:

```sh
mkdir -p server/build/baseline
git show <an earlier commit>:server/src/WitcherServer.java > server/build/baseline/WitcherServer.java
javac -encoding UTF-8 -d server/build/baseline server/build/baseline/WitcherServer.java \
    server/src/ClientEndpoint.java server/src/PlayerSession.java \
    server/src/UsernameReservation.java server/tests/SessionLockScopeTest.java
java -cp server/build/baseline SessionLockScopeTest   # must fail
```

It fails with "the registry lock is held while forwarding a UDP datagram". This is a
check to make by hand against an earlier commit, not one for CI: once the change is
on main, main is no longer a baseline to compare against.

These tests do not require the game or native WitcherScript compiler.
