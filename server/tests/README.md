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
can send, that a console kick for another player proceeds, and that a kick for the\nfirst player waits for its in-flight update.
The UDP test runs the real Java server with three loopback clients; one disconnects
and rejoins with its original ID while the others keep exchanging updates.

These tests do not require the game or native WitcherScript compiler.
