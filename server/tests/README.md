# Server tests

Run from the repository root with JDK 21:

```sh
javac -encoding UTF-8 -d server/build/test server/src/*.java server/tests/SessionTimeoutTest.java
java -cp server/build/test SessionTimeoutTest
```

The test uses synthetic timestamps to reproduce stale timeout decisions without
waiting for a live server or requiring the game.
