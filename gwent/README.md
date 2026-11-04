# Gwent duels on The Witcher 3 Remastered 5.01

This folder builds the Gwent board for Witcher Online duels on The Witcher 3 Remastered 5.01. It takes CDPR's own
5.01 Flash Gwent board from the player's game, applies our patches, adds our own duel classes (lockstep play over the
Witcher Online connection) and writes a mod bundle that replaces the board in `modWitcherOnline`. The design is in
[`docs/superpowers/specs/2026-11-02-gwent-duels-5.01-design.md`](../docs/superpowers/specs/2026-11-02-gwent-duels-5.01-design.md).

Tested game build: **5.0.0.1048522**, the only one in `KNOWN_BOARDS` (`gwent/build/build.py`). The build refuses
any other vanilla board unless `--allow-unknown-board` is given (see "Build commands"). The witcher3-coop package itself
also runs on Steam's update of 2026-10-29 (build 5.0.0.1090142, through its own bridge fix), but no duel board has been
built or tested on that build: both duel players need 5.0.0.1048522.

## Provenance and licensing

- This code was written from the design document and from the vanilla 5.01 board. The implementers did not read
  x4lva's `gwent-multiplayer` repository or the board shipped in Witcher Online while writing it. Witcher Online's
  GPL-3.0 scripts were read freely, since this builds on them.
- Licensed GPL-3.0, like Witcher Online.
- This replaces x4lva's board on the 5.01 branch. The original duel feature is by x4lva and rejuvenate7; x4lva is
  invited to review.
- The repository contains no CDPR code beyond the context lines of the patches in `gwent/patches/`. The vanilla board
  is read from the player's own game at build time and is never stored here.

## Layout

| Path | What it holds |
|---|---|
| `gwent/build/` | The build pipeline: `build.py` (commands), `tools.py` (pinned FFDec and JRE), `ffdec.py` (decompile and recompile), `bundle.py` (CDPR bundle reader and writer, `metadata.store`), `redswf.py` (finds the Flash movie inside the `.redswf` and rewraps it), `patches.py` (appends our classes to a host script), `vectors.py` (writes `DuelVectors.as`) |
| `gwent/patches/` | One unified diff per patched vanilla class (8 files) |
| `gwent/src/` | Our new ActionScript 3 classes (`DuelSession`, `DuelCodec`, `DuelWindow`, `DuelRandom`, `DuelStateHash`, `NetOpponentController`, `DuelEnd`, `DuelWait`, `DuelClock`, `DuelTimer`, `DuelTimerView`, `DuelSelfTest` and others) |
| `gwent/tools/` | `duelref.py` (Python reference of the random streams, hash, codec and message window; writes the test vectors) and `duel_logdiff.py` (compares the duel logs of the two clients) |
| `gwent/tests/` | pytest tests and `vectors.json` |
| `gwent/.tools/`, `gwent/work/`, `gwent/out/` | Downloads, scratch files and build output. Git ignores all three. |

The script side (challenge, deck exchange, bets, the opponent-left check) is in
`witcher/mods/modWitcherOnline/content/scripts/local/gwentDuel.ws` and `client.ws`.

## Build prerequisites

For `gwent/build/build.py` and the pytest suite:

| Need | Version | Notes |
|---|---|---|
| Windows | 10 or 11 | The tools are pinned for Windows x64. |
| Python | 3.10 or newer (built and tested with 3.14) | `build.py` imports its sibling modules, so run it as `python gwent/build/build.py`, not with `python -I`. |
| pytest | 9 (tested with 9.x) | `pip install pytest` |
| Git | any recent | `build.py` uses `git apply` and `git diff --no-index` for the patches. |
| The Witcher 3 Remastered, build 5.0.0.1048522 | exactly this build | Read only: `content\content0\bundles\r4gui.bundle` is opened to extract the vanilla board, and its sha256 must be `aeb1255be5a4d218bf41a7630dd27e4b25b32936c0f06055fa77e7aec4d5664e`. |
| JPEXS Free Flash Decompiler (FFDec) | 26.4.0 | Pinned: the patches depend on its exact decompiler output. |
| Java runtime | Temurin 21.0.13+9 | Runs FFDec. |

FFDec and the JRE are downloaded by `python gwent/build/build.py tools` into `gwent/.tools/` and checked against their
sha256. A zip that is already in `gwent/.tools/` with the right checksum is used without any download.

| Tool | Pinned download | sha256 |
|---|---|---|
| FFDec 26.4.0 | https://github.com/jindrapetrik/jpexs-decompiler/releases/download/version26.4.0/ffdec_26.4.0.zip | `56ce960aeafc7caf034e2052ba49f878a883f7c7ca690da6eeffca9587b5e4b9` |
| Temurin 21.0.13+9 JRE | https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_windows_hotspot_21.0.13_9.zip | `2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628` |

For the automated game tests (`gwent_vanilla`, `gwent_selftest`, `gwent_duel`, `run_suite.py`) you also need the
[witcher3-coop](https://github.com/Emillock/witcher3-coop) harness next to this repository, its "Building" section
(Visual Studio with the C++ desktop workload, JDK 21, Git Bash) and these builds:

| Need | Version | Notes |
|---|---|---|
| WitcherNativeBridge | upstream commit `382898a` for game build 5.0.0.1048522 | The commit right before upstream's "update for 5.01c". The newer upstream master matches only the 5.0.0.1090142 exe and makes this one crash about 6 s after start when a script native takes a string. (The witcher3-coop package bundles a bridge with a local fix that accepts both builds, see its README.) |
| Witcher Online client | this repository, `client/` | `msbuild MultiplayerClient.sln -p:Configuration=Release -p:Platform=x64 -p:OutDir=<root>\WitcherOnline\client\build\Release\`. The `client/asio` submodule must be initialised (`git submodule update --init client/asio`). |
| Witcher Online server | this repository, `server/` | `javac` and `jar` with a JDK 21 (see the coop README). |
| `w3test.asi` | witcher3-coop, `w3test\build.cmd` | The test bot. |
| Ultimate ASI Loader | v9.7.4, `Ultimate-ASI-Loader-NoPDB_x64.zip`, sha256 `e5860e7d9a1805267535b65749575b5e406cc6ea3325c7392189c578815045d1` | https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/tag/v9.7.4 ; `dinput8.dll` goes to `<root>\deps\ultimate-asi-loader-9.7.4\`. |
| Temurin JDK 21.0.13+9 | sha256 `a4dbaa05fca4bd89d84584e58c459bd732efebb1722af80ab13c6516832004f9` | https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_windows_hotspot_21.0.13_9.zip ; `java` must be on `PATH` for the harness. |

Environment for the harness: `W3_GAME_DIR` (the game folder), `W3C_WORK` (a short work folder, for example
`C:\w3build\work`, so run folder paths stay under the Windows path limit), and, if mods installed in the game fail to
compile on 5.01, `W3T_DISABLE_MODS=<comma separated mod names>` (edits the test games' `mods.settings` only).

## Build commands

Run from the repository root. `<game>` is the game folder (the one that holds `content\` and `bin\`).

```
python gwent/build/build.py tools
python gwent/build/build.py vanilla --game "<game>" [--out <file>] [--allow-unknown-board]
python gwent/build/build.py build   --game "<game>" [--out <dir>] [--work <dir>] [--allow-unknown-board]
python gwent/build/build.py diff    [--work <dir>]
```

- `tools` downloads, verifies and unpacks FFDec and the JRE.
- `vanilla` extracts the vanilla board to `gwent/work/vanilla.redswf` and checks it against the known sha256.
- `build` runs the whole pipeline and writes `gwent/out/modWitcherOnline/content/blob0.bundle` and `metadata.store`
  (about 15 s once the tools are there). It only reads the game folder.
- `diff` regenerates `gwent/patches/*.patch` from `gwent/work/edit` (see the next section).

`--allow-unknown-board` extracts and patches a board whose sha256 is not in `KNOWN_BOARDS` in `build.py`. Use it only to
look at a new game build: the patches may not apply, and the result is untested.

To use the board in the game, install it together with the Witcher Online scripts. The tested route is the
witcher3-coop `deploy.py`, which backs up what it replaces and restores it on uninstall. It needs the whole
witcher3-coop checkout next to this repository (its "Building" section) and these builds on the same PC: the Witcher
Online client `.asi` and the WitcherNativeBridge `.asi` of commit `382898a` (see "Build prerequisites"; `deploy.py`
installs the bridge of `<root>\WitcherNativeBridge` unless an `--extra` replaces it). A player's install, run from the
witcher3-coop folder:

```
python -I deploy.py install --scripts-only --dlc --extra <WitcherOnline>\client\build\Release\WitcherOnlineClient.asi=bin\x64_dx12\WitcherOnlineClient.asi --extra <bridge 382898a build>\WitcherNativeBridge.asi=bin\x64_dx12\WitcherNativeBridge.asi --extra <WitcherOnline>\gwent\out\modWitcherOnline\content=mods\modWitcherOnline\content
python -I deploy.py uninstall
```

The game tests add the test bot on top (`--extra <witcher3-coop>\w3test\modW3Test=mods\modW3Test` and
`--extra <witcher3-coop>\w3test\build\w3test.asi=bin\x64_dx12\w3test.asi`). A player without this checkout
cannot follow this route alone yet; for the manual test the author helps with the install.

Only this board replaces Witcher Online's 4.04 board (`blob0.bundle` and `metadata.store`); the old 4.04 Gwent
script overrides (`gwintManager.ws`, `gwintGameMenu.ws`) are not installed. The witcher3-coop release package does not
include a Gwent board yet: every player builds it from their own game with the commands above. A player who has the
scripts but not this board (the vanilla 5.01 board, the 4.04 bundle or another Gwent mod in its place) plays the duel
against the AI without knowing it: Witcher Online's script sees that the board never sent its Hello and cancels the
duel when the menu closes ("this game does not have Witcher Online's Gwent duel board", reason `board`), and the
opponent's board ends by its own Hello wait (no contest, `hello_timeout`, after 2 minutes). Nobody pays.

## How the board patches are made

The vanilla board is the Flash movie `gameplay\gui_new\swf\gwint\gwint_game.redswf` inside `r4gui.bundle`.

1. `build.py build` extracts the `.redswf`, takes the Flash movie out of it (`redswf.read_movie`) and has FFDec 26.4.0
   export every ActionScript 3 class to `gwent/work/vanilla/`. Line endings are normalised to LF.
2. It copies that tree to `gwent/work/build/` and applies `gwent/patches/*.patch` with `git apply -p1`. Each patch is a
   unified diff of one vanilla class (`AIPlayerController`, `CardInstance`, `CardLeaderInstance`, `CardManager`,
   `GwintDeck`, `GwintGameFlowController`, `GwintGameMenu`, `HumanPlayerController`). A patch that does not apply stops
   the build with the git message, which is how a different game build is noticed.
3. It appends every class in `gwent/src/` to one host script (`CardTransaction.as`), because FFDec can replace
   existing scripts but cannot add new ones, while a second class in an existing script of the same package compiles and
   registers on its own.
4. It has FFDec recompile only the scripts that differ from vanilla, restores the movie's original version byte, wraps the
   movie back into the `.redswf` (`redswf.rewrap`, which also fixes the CR2W sizes and checksum) and checks the result.
5. It writes the board into a version 3 bundle and generates `metadata.store`.

To change a patch: run `build.py build` once, copy `gwent/work/vanilla` to `gwent/work/edit`, edit the classes in
`gwent/work/edit`, then run `build.py diff`. That rewrites `gwent/patches/` from the difference between `edit` and
`vanilla`. New classes do not go in a patch: they belong in `gwent/src/` (`diff` refuses a new file). Hooks in patched
classes call `DuelSession.active` and fall through to the vanilla code when it is `null`, so single-player Gwent runs
the vanilla paths.

`gwent/src/DuelVectors.as` is generated from `gwent/tests/vectors.json`, which `gwent/tools/duelref.py` writes. After
changing the Python reference run `python gwent/tools/duelref.py vectors`, then
`python gwent/build/vectors.py`, and rebuild: the board's self-test replays those vectors through the AS3 classes.

## Automated tests

Unit and source tests (no game needed apart from one slow test), from the repository root:

```
python -m pytest gwent/tests -q
python -m pytest gwent/tests -q -m "not slow"
```

The `slow` test (`test_build.py`, about 15 seconds) runs the real FFDec pipeline against the installed game; it reads the
game folder from `WITCHER3_GAME_DIR` (default: the GOG install path) and skips itself when `r4gui.bundle` is not there.
`build.py build` itself ends with a smoke check: it lists the classes of the recompiled movie and stops with an error
unless every `gwent/src` class (`NetOpponentController` included) is in it; the fast tests cover that check.
It needs the tools from `build.py tools`. The Python reference, the codec, the message window, the logdiff, the match
end, the stuck-wait rule, Timed mode and the patches each have a test file.

Game tests (witcher3-coop, `[game]`: they start Witcher 3 test games, minimized, inside your installation; deploy first
as described under "Build commands", end with `python -I deploy.py uninstall`). Run from the `witcher3-coop`
folder:

| Command | What it checks |
|---|---|
| `python run_test.py gwent_vanilla` | A vanilla match against the AI on the rebuilt board; the bot plays and surrenders once the board is up. Passes when the match ends with a result and the board logged no `DUEL ` line (single-player Gwent must not reach the duel code); any such line fails it. |
| `python run_test.py gwent_selftest` | The board replays the test vectors and its own rule checks through the AS3 duel classes and logs `DUEL SELFTEST pass=<n> fail=<m>`. Passes only with `fail=0`. |
| `python run_test.py gwent_duel` | Two games: a duel between two bots through the real challenge. Both boards play themselves. The duel logs are compared by `gwent/tools/duel_logdiff.py` and the two results and the money must fit. The `W3T_GWENT_*` switches (decks, seed, mulligan, Timed, forced draw, replay, surrender, quit, idle, corrupt, no duel board) are described in the witcher3-coop README. |
| `python run_test.py --matrix <file>` | Several `gwent_duel` entries with their own settings in one game launch. |
| `python run_suite.py gwent_vanilla gwent_selftest gwent_duel` | The whole Gwent subset with a summary table. `gwent_duel` runs every entry of `GWENT_DUEL_MATRIX` in `run_suite.py` (32 entries: decks and seeds, decisions, mulligan, the match end cases, stuck waits, an opponent that quits, Timed mode, a client without the duel board) as `--matrix` sessions; `--no-session` gives every duel fresh games (slower). Allow about 1.5 to 2 hours. |

Results of the last full run are under "Results". Log lines of the board are `DUEL HELLO`, `DUEL SEND`, `DUEL APPLY`,
`DUEL ROUND`, `DUEL END`, `DUEL DESYNC` and others; `python gwent/tools/duel_logdiff.py <logA> <logB>` reports the
first step where two logs differ.

The automated tests cannot judge how the board looks or feels, and the bots never zoom a card, take the coin-toss popup
as a human does, or think for a long time. That is what the manual checklist is for.

## What a duel does (for the tester)

- Challenge the other player with the console command `duel("<their username>")` (`-debugscripts`, then `~`). The id
  the command takes is the other player's Witcher Online username, exactly as in the `<Username>` line of their
  `bin\WitcherOnline\config.xml` (on Remastered the client uses the username as the player id; the harness log shows
  it as `challenge BotB (id BotB, ...)`). Ask the other player for it before you start. The other player must be near
  you (their character in your world), out of combat and out of dialog. Witcher Online's player menu, which also offers
  the challenge, shows no entries on Remastered yet (see the witcher3-coop README). Choose Normal or Timed mode in the
  popup, then the bet. The other player accepts in a popup. Both need the same game build, the same Witcher Online
  build and no Gwent card mods.
- Normal mode has no turn clock, but it is not unlimited: a player who takes more than 2 minutes to make a move (or to
  answer the mulligan or a choice) cancels the match as no contest for both, and no money moves. Timed mode gives each
  player 60 seconds per turn, mulligan and decision; when it runs out, the turn is passed (or the first option is
  taken). The opponent's turn shows a countdown.
- A surrender loses the bet for the one who quits and wins it for the other player, except when it is confirmed while
  the board still waits for the opponent's first message (right at the start): then the match is no contest. A surrender
  confirmed after the game already ended (the popup was opened before the last card) does nothing: the result of the
  game counts.
- A win pays the bet, a loss costs it, each client settles its own bet. A draw is replayed by both with the same bet;
  if one closes the end screen instead, nobody pays.
- If the match is cancelled (out of sync, opponent left, nobody answers in time) it ends as "no contest": no money moves
  on either side.

## Manual test checklist

Two players on two PCs over the Steam relay (or one PC and the bot harness for the single-player rows), both on game
build 5.0.0.1048522 with this branch installed. Both players need a deck for every faction. Write down both players'
gold before and after every match. Both players try both seats (host and guest) wherever a row says "both seats".
Record each result in the table under "Results". Mark a row passed only when you saw it.

Before the first match, both players check that they run the same thing, and stop if anything differs:

1. **The same game build.** In PowerShell:
   `(Get-Item "<game>\bin\x64_dx12\witcher3.exe").VersionInfo.FileVersion` (or right-click `witcher3.exe`,
   Properties, Details, File version). Both must show **5.0.0.1048522**. The duel board is built and tested on that
   build only. Steam's update of 2026-10-29 is build 5.0.0.1090142: the witcher3-coop package runs on it, but no duel
   board has been built or tested on it yet. If one PC shows another build, or its `build.py build` stops with "not a
   known board", stop and report the build: do not pass `--allow-unknown-board` for the test.
2. **The same Witcher Online commit** (`git rev-parse HEAD` in this repository) on both PCs.
3. **The same board.** `build.py build` prints `board matches game build 5.0.0.1048522` and
   `smoke check: all 20 gwent/src classes are in the built board`. The build is deterministic, so the md5 of
   `gwent/out/modWitcherOnline/content/blob0.bundle` (`Get-FileHash -Algorithm MD5 <file>`) must be the same on both
   PCs. A board from another commit passes the Hello but can go out of sync minutes later.

Things that always hold, and that you should watch in every match:

- The two boards show the same cards, the same scores and the same rows after every move.
- No card stays stuck in the middle of the board, and the board never freezes without a message.
- The winner gains the bet, the loser loses it, in both clients; a draw or a cancelled match moves nothing.

### A. Single player (the board must still behave like vanilla)

- **A1** One normal match against the AI with your usual deck. Expect: it plays and ends like before, gold changes only
  as the game normally does.
- **A2** One quest Gwent match (any Gwent quest or a player in the world). Expect: the quest advances as normal.
- **A3** The Gwent tutorial (from a new save or the tutorial NPC). Expect: the tutorial prompts appear and finish.

### B. Starting a duel

- **B1** Challenge in Normal mode with `duel("<their username>")` (see "What a duel does"), accept, play a short match.
  Do it once with each player hosting. If the other player gets no challenge popup, check the exact spelling of the
  username and that the other player is near you. If the mode popup or the bet window does not appear on Remastered,
  write down exactly what you see and stop: nothing else can start.
- **B2** Challenge in Timed mode, accept. Expect: the turn clock is visible (see section H).
- **B3** Choose a bet higher than your own gold: a message appears and no challenge is sent. Challenge a player who is
  in combat or in a dialog: expect the challenge to be declined, no board opens, and you can challenge again later.
- **B4** Refused challenge: challenge a player whose Witcher Online has another Gwent duel version (a 4.04 client or an
  older 5.x build). Expect: "No Gwent duel with <name>: their Witcher Online has another Gwent duel version", no board
  opens. (Not seen in game before.) A player who just arrived and has sent nothing yet gets "their Gwent duel version
  is unknown, try again in a moment"; check that this clears after a moment.
- **B5** Refused match: one player has a Gwent card mod or a different card table. Expect: the board opens, then the
  match ends as no contest with the reason shown, and no money moves. (Not seen in game before; skip it if you have no
  such mod.)
- **B6** The player who is "in Gwent" can start another duel after any of the endings below (no leftover "already in a
  Gwent game" message).

### C. Factions and mirror matches

Play one full match for each row. Both seats see the same result.

- **C1** Northern Realms vs Nilfgaard. Northern Realms must draw its extra card when it wins a round; Nilfgaard must win
  a tied round.
- **C2** Scoia'tael vs Monsters. Scoia'tael decides who goes first (see E1 and E2). Monsters keep one creature on the
  board after round 1.
- **C3** Skellige vs Northern Realms. The Skellige round 3 perk returns two cards from the graveyard at the start of
  round 3. If Northern Realms won round 2 it draws at that same round start (both effects at one round start).
- **C4** Mirror match: Monsters vs Monsters.
- **C5** Mirror match: Skellige vs Skellige.
- **C6** Mirror match: Northern Realms vs Northern Realms, Nilfgaard vs Nilfgaard, Scoia'tael vs Scoia'tael (one short
  match each is enough).
- **C7** Nilfgaard with the leader Invader of the North (it brings back a random card): play it in a match where the
  graveyard holds several cards. Expect: the same card comes back on both boards.

### D. Cards and rules

Use decks that hold the cards named in each row. Each row: play the card on your turn, and also watch the opponent play
it. Both boards must end in the same state.

- **D1** Medic resurrecting an agile card. If the agile card can go to two rows, check that it lands in the same row
  on both boards, also when the choice is a tie.
- **D2** Medic chains (a medic brings back another medic) and a medic with several targets (the pick dialog appears for
  the player who played it; the other board waits and then shows the same card).
- **D3** Two medics landing together (for example the Skellige birna_bran perk for both players).
- **D4** Spies, including the spies that come back to the opponent's row through the Skellige perk.
- **D5** Decoy on a normal card and on a spy.
- **D6** Scorch variants: the scorch card, scorch leaders, a scorch that burns three or more cards at once (they now
  leave one after another, so look for stuck cards), two scorches in one round.
- **D7** Weather: each weather card, then Clear Weather. The weather slot is not on either seat's side; check both boards
  show the same weather.
- **D8** Commander's horn on a row and a horn leader.
- **D9** Morph and summon cards: a berserker with a mushroom must transform into the same card on both boards; cards that
  spawn another card when the board clears at the end of a round (cow and Kambi) must spawn it on both boards.
- **D10** Berserker and mardroeme together.
- **D11** Muster (play the first card, the rest of the group follows; with four or more cards the deploy animations run
  one after another, slower than in single player).
- **D12** Banish (5.01 card).
- **D13** 5.01 King cards.
- **D14** Opponent-row modifiers (5.01 cards that change the opponent's row).
- **D15** Two cards landing at once (muster, scorch, perks at a round start): the order of effects is the same on both
  boards. Watch for a visibly slower resolution than in single player and say if it is annoying.
- **D16** Cards that steal from the other side, if any are in your decks. (No 5.01 card in the shipped game calls the
  steal code today; report it if one does.)
- **D17** The game ends while effects are still playing (the last card of the last round is a muster or a scorch).
  Expect: the end screen opens once, the result is the same on both sides.
- **D18** Both players each play at least one card from every leader ability with a choice: resurrect (leader), pick a
  weather card from the deck, discard two cards then take one from the deck, view the opponent's hand (the last one is
  shown to its owner only).
- **D19** Leader abilities without a choice (horn, scorch, clear weather, and the leader that shuffles the graveyards back
  into the decks) for each faction. The shuffled cards must end in the same order on both boards.

### E. Choices and waiting

- **E1** Coin toss: one player plays Scoia'tael, the other another faction. The Scoia'tael player gets the popup (go
  first or let the opponent go first). Expect: the other player sees "Your opponent is choosing who goes first" while it
  waits, then the match starts with the chosen player. Do it both seats, and answer "let the opponent start" once.
- **E2** Close the coin popup without answering. Expect: it counts as the first option (you go first) and the match
  continues. (Not seen in game before.)
- **E3** Mulligan: redraw two cards on one side and none on the other, and let one player take much longer. Expect:
  after you press done you see "Waiting for your opponent" while the other player is still choosing, and the match
  starts when both are done. The message is shown once: say whether the board looks frozen after it fades.
- **E4** Open a card zoom on a card in your hand or on the board during your own turn, pick a card from the zoom, and
  also close the zoom without picking.
- **E5** Open a card zoom while the opponent is about to play. Expect: the opponent's move waits until you close the
  zoom, then applies. A choice dialog that a zoom replaced and that you then close is shown again (the board does not
  take a default). (Not seen in game before.)
- **E6** Think for 100 seconds on your turn in Normal mode, then play. Expect: the match goes on. Then, once, think
  for more than 2 minutes while the other player waits. Expect: the match ends as no contest ("No answer in time") for
  both, and no money moves. (The limit is a guess; say if 2 minutes is too short for a real player.)
- **E7** Play a duel where one player has the Witcher Online scripts but not the built board (uninstall the board only,
  or skip `--extra ...\gwent\out\...` in that player's install). Expect: that player sees an ordinary match against
  the AI, and when it closes, "this game does not have Witcher Online's Gwent duel board ... No bet was paid"; the other
  player's board ends after about 2 minutes as no contest. Nobody pays on either side. (Covered by the `noboard` entry
  of the automated matrix; do it only if the install is easy to change.)

### F. Match end

- **F1** Win and loss: gold moves by the bet on both sides, once, and the end screen appears for both only after the
  result is confirmed (it can take a second or two longer than in single player).
- **F2** A drawn match, both press Replay. Expect: "Waiting for your opponent", then a new game with the same bet, a fresh
  shuffle, and a later win or loss that pays. The "Waiting for your opponent" message is shown once; see how long the
  board looks still if the other player takes a while (if the other player never presses Replay, the wait ends after 2
  minutes in Normal mode, 90 seconds in Timed mode, as a draw with no money, as if they had pressed Leave; see F4).
- **F3** A drawn match, one presses Replay and the other closes the end screen. Expect: both end as a draw and no money
  moves.
- **F4** A drawn match, one presses Replay and the other does nothing for over 2 minutes. Expect: the waiting player's
  match ends as a draw with no money moved, and the other player's end screen closes.
- **F5** A natural draw (equal scores in all rounds) followed by a replay and another draw in the replayed game.
- **F6** Surrender: one player closes the board with the close button and confirms. Expect: the quitter loses the bet,
  the other wins it, both see the result. Do it in game 1, in a replayed game 2 (also during its mulligan), and while
  the other player is still in the mulligan.
- **F7** Both players surrender at the same moment. Expect: each loses their own bet, nobody wins it. (Hard to time; try
  it once.)
- **F8** Surrender over the relay: the other player must see it within a few seconds. (The surrender keeps being sent
  for 30 s after the board closes. If it never arrives, the other side ends as no contest after its wait limit and
  nobody pays.)
- **F9** Close the end screen of a win or loss right away and after waiting a while. Expect: the result is the same
  either way and the gold is paid once.
- **F10** On a drawn match one player presses Replay at once and the other waits some seconds before pressing it.
  Expect: the new game starts when the second player presses Replay too.
- **F11** A surrender popup left open across the end: player 1 presses the close button on their own turn and leaves the
  surrender popup open without answering; player 2 plays the last card or passes so the game ends; once the end screen
  is behind the popup, player 1 confirms the surrender. Expect: the surrender does nothing (no "forfeit" close), the end
  screen stays, and the game's own result is paid once on each side (or nothing, on a draw). (Not seen in game before.)

### G. Failures

Decision: the deliberate desync of spec 14 is not a manual row. The shipped board can only corrupt a card through
the test switch `CR4GwintManager.duelDebugCorruptAt` (the board's `gwint.game.debug.corruptAt`), which only the w3test
bot sets; no console command or menu sets it. The automated tests use it (the `corrupt` entries of `gwent_duel`, one at
a move and one at the last message) and must report `DUEL DESYNC` and no contest on both sides.

- **G1** The opponent closes the game (Alt+F4) during a match. Expect: about 30 seconds later the other player sees
  "Your opponent left. The match was cancelled", nobody pays, and they are free to start another duel.
- **G2** The opponent closes the game while the end screen of a win or loss is open (the result was confirmed). Expect: the
  result stands and is paid once.
- **G3** The opponent closes the game while the end screen of a drawn match is open. Expect: a draw, no money moved.
- **G4** The opponent pauses their game (Alt+Tab to the desktop for 10 to 20 seconds, then back). Expect: the match goes
  on and is not ended as "left". Repeat once with 40 seconds and write down what happens (it may end as left); in no case
  may only one side be paid. Do it on both machines: the player who paused also checks that their own board does not
  end the match as "left" when they come back (a hitch on the local side restarts the silence clock).
- **G5** The opponent closes the game at different stages: while the boards are still exchanging their first messages,
  during the mulligan, and right as the last card of the match is played (while the boards confirm the result). Write
  down the money on both sides each time; expect no contest and no money, or, if the result was already confirmed, one
  payment on each side as the result says.
- **G6** The opponent's connection drops (unplug the cable for 40 seconds, then reconnect). Expect: the player whose
  connection stayed up sees the opponent-left message after about 30 seconds and nobody is paid alone. Write down what
  the player who dropped sees.
- **G7** The opponent leaves their board untouched on their own turn for more than 2 minutes in Normal mode. Expect: both
  end as no contest ("No answer in time"), nobody pays, and both are free to start another duel. (This is the same rule
  as E6: in Normal mode a move that takes more than 2 minutes cancels the match.)
- **G8** If a duel is accepted but its board never opens (for example a menu was open at the moment): after 120 seconds
  "The Gwent duel could not start. No bet was paid." appears and you are not stuck "in Gwent". (Not seen in game; only
  if it happens by itself.)
- **G9** A 4.04 Witcher Online client challenges a 5.01 player and the other way round, if you have one. Expect: the
  refusal of B4 on the 5.01 side and no duel. (A 4.04 client that is not near the 5.01 player may open its own board
  before the refusal reaches it; write down what it does.)

### H. Timed mode

- **H1** The clock (a ring and the seconds, red under 10 seconds) shows next to your player panel on your own turn and counts
  down from 60; on the opponent's turn it shows a countdown next to the opponent's panel. Check position, font and that it does not cover cards, the score,
  the round markers or a dialog. Check it over the mulligan dialog and over a choice dialog.
- **H2** Let your own turn run out. Expect: the turn is passed, and the opponent sees your pass.
- **H3** Let the clock run out with a card picked (before you place it) and with a card waiting for a row or a target.
  Expect: the card goes back and the turn is passed.
- **H4** Let the clock run out while a card zoom is open on your own turn. Expect: the zoom closes and the turn is passed.
- **H5** Let the clock run out during the mulligan. Expect: the mulligan counts as done with the redraws made so far.
- **H6** Let the clock run out during a choice dialog (medic pick, leader pick). Expect: the first option is taken, and a
  second choice in the same turn is answered at once.
- **H7** Let the coin popup time out as the Scoia'tael player. Expect: the first option (you go first) is taken and the
  popup closes.
- **H8** Open a card zoom on the opponent's turn and keep it open for more than 60 seconds while the opponent's move is
  waiting. Expect: after the 60 seconds the zoom closes, the move applies, and your turn starts already expired (it is
  passed at once). The time spent in the zoom is lost from your own turn; the match is not ended as stuck.
- **H9** Play a full Timed match to the end without letting the clock run out. Expect: the same result and gold as in
  Normal mode, and the clock stops when the match ends.
- **H10** A normal Normal-mode match shows no clock at all.

### I. Touch input

- **I1** If a touchscreen is available: play a short match by touch (pick a card, place it on a row, pass, zoom, the
  dialogs, the end screen buttons). Expect the same behaviour as with mouse or pad. Skip it otherwise.

### Items carried from the build

These are the paths the bots and unit tests could not reach. They are covered above where a row says so; the short list:
the human coin popup (E1, E2, H7), waiting messages (E3, F2), zoom holding the opponent's move (E5, H8), decisions that
time out (H6), the Timed clock layout (H1), cancel-before-pass (H3), the one-by-one landing of cards (D11, D15), the
berserker morph with mushroom (D9), two medics landing together (D3), a Northern Realms draw with a Skellige perk (C3),
spies from the Skellige perk (D4), cow and Kambi spawns (D9), game end with effects queued (D17), simultaneous surrender
(F7), the replay timeouts (F2 to F4), a natural draw in a replayed game (F5), the opponent leaving at each stage
(G1 to G6), Hello refusal paths (B4, B5), the agile medic tie (D1), a surrender popup left open across the end (F11).

Not reachable by hand (source tests and the self-test only; no row): a move or a decision that arrives after the
opponent's end of game message ("move after the opponent's end", a desync); the late X or QUITGAME that crosses a replay
(the opponent leaves or surrenders the old game while this board already started the replayed one); the end timeout
(`end_timeout`: the opponent's game stays alive but never sends its end of game message, which G5 and G7 do not
produce); the empty-hand auto-pass (R21); a QUITGAME that arrives behind a move this board still holds when the opponent
then leaves (it settles as a surrender, not as "left").

## Results

### Automated (last full run)

Run on 2026-11-04 with the final board (`blob0.bundle` md5 `96254ad6b30c282f1bdcce9aa4d229cf`) on game build
5.0.0.1048522, minimized test games, command `python run_suite.py gwent_vanilla gwent_selftest gwent_duel` in
`witcher3-coop` (branch `gwent-duels-5.01`):

- **34 of 34 passed**, wall-clock 98 minutes (05:45 to 07:23): `gwent_duel` 32 of 32 in one game launch (5775 s),
  `gwent_vanilla` PASS (48 s; it now fails on any `DUEL ` line, and the bot log had none), `gwent_selftest` PASS
  (48 s, `DUEL SELFTEST pass=538 fail=0`).
- The 32 `gwent_duel` entries: five pirate_ske seeds, two muster seeds, five deck pairs with mulligan (two seeds each),
  the corrupt check (desync at seq 8), a tricks pair, two leader-first pairs, the forced draw with replay, with leave, with
  no answer, a surrender at message 4, a replayed game surrendered through the close button, a desync on the last message,
  a bot that stops playing (stuck wait), Timed idle seat, Timed both play, a guest whose board runs as the vanilla board
  (`noboard`: guest `nocontest reason=board`, host `nocontest reason=hello_timeout`, no money on either side), and a bot
  that quits its game. All with `duel_logdiff` clean and the money right.
- The game window was the foreground window 0 times in 52772 samples.
- `python -m pytest gwent/tests -q` in the WitcherOnline repository: 202 passed. `python -m pytest tests -q` in
  `witcher3-coop`: 55 passed.
- The run folders are under `<W3C_WORK>\runs\`: `20261104-054532-matrix32`, `20261104-072147-gwent_vanilla`,
  `20261104-072235-gwent_selftest`.
- `python -I deploy.py uninstall` afterwards: manifest empty, no `witcher3.exe` or `java` process left.

### Manual

All rows are pending. Fill in the result (pass, fail, skipped), date, the two players and notes when a row is done.

| ID | Check | Result | Date / players | Notes |
|---|---|---|---|---|
| A1 | Single player: vanilla match against the AI | pending | | |
| A2 | Single player: one quest Gwent match | pending | | |
| A3 | Single player: Gwent tutorial | pending | | |
| B1 | Challenge, Normal mode, both seats host | pending | | |
| B2 | Challenge, Timed mode | pending | | |
| B3 | Challenge refused (bet too high, combat, dialog) | pending | | |
| B4 | Challenge refused by another duel version | pending | | |
| B5 | Match refused by a card mod or table mismatch | pending | | |
| B6 | Free to start another duel afterwards | pending | | |
| C1 | Northern Realms vs Nilfgaard | pending | | |
| C2 | Scoia'tael vs Monsters | pending | | |
| C3 | Skellige vs Northern Realms (perk and draw together) | pending | | |
| C4 | Mirror: Monsters | pending | | |
| C5 | Mirror: Skellige | pending | | |
| C6 | Mirrors: Northern Realms, Nilfgaard, Scoia'tael | pending | | |
| C7 | Invader of the North random medic | pending | | |
| D1 | Medic on an agile card | pending | | |
| D2 | Medic chains and medic pick | pending | | |
| D3 | Two medics landing together | pending | | |
| D4 | Spies, also from the Skellige perk | pending | | |
| D5 | Decoy | pending | | |
| D6 | Scorch variants | pending | | |
| D7 | Weather and Clear Weather | pending | | |
| D8 | Commander's horn | pending | | |
| D9 | Morph, summon, mushroom with berserker, cow and Kambi | pending | | |
| D10 | Berserker and mardroeme | pending | | |
| D11 | Muster | pending | | |
| D12 | Banish | pending | | |
| D13 | King cards | pending | | |
| D14 | Opponent-row modifiers | pending | | |
| D15 | Two cards landing at once | pending | | |
| D16 | Steal cards (if any) | pending | | |
| D17 | Game ends with effects playing | pending | | |
| D18 | Leader abilities with a choice | pending | | |
| D19 | Leader abilities without a choice | pending | | |
| E1 | Coin toss, both seats, waiting message | pending | | |
| E2 | Coin popup closed without an answer | pending | | |
| E3 | Mulligan and "Waiting for your opponent" | pending | | |
| E4 | Card zoom on your own turn | pending | | |
| E5 | Card zoom on the opponent's turn | pending | | |
| E6 | Thinking time in Normal mode | pending | | |
| E7 | A player without the built board | pending | | |
| F1 | Win and loss pay once | pending | | |
| F2 | Draw, both Replay | pending | | |
| F3 | Draw, one Replay, one closes | pending | | |
| F4 | Draw, Replay, no answer | pending | | |
| F5 | Natural draw, then a draw in the replay | pending | | |
| F6 | Surrender (game 1, replayed game, mulligan) | pending | | |
| F7 | Both surrender at once | pending | | |
| F8 | Surrender arrives over the relay | pending | | |
| F9 | End screen closed right away or late | pending | | |
| F10 | Replay pressed at different times | pending | | |
| F11 | Surrender popup left open across the end | pending | | |
| G1 | Opponent closes the game during a match | pending | | |
| G2 | Opponent closes the game on a confirmed win or loss | pending | | |
| G3 | Opponent closes the game on a confirmed draw | pending | | |
| G4 | Opponent pauses (Alt+Tab) | pending | | |
| G5 | Opponent leaves at different stages | pending | | |
| G6 | Connection drops | pending | | |
| G7 | Opponent does nothing for over 2 minutes | pending | | |
| G8 | Board never opens | pending | | |
| G9 | 4.04 client challenge | pending | | |
| H1 | Timer layout and layering over dialogs | pending | | |
| H2 | Own turn runs out | pending | | |
| H3 | Clock runs out with a card picked | pending | | |
| H4 | Clock runs out with a zoom open | pending | | |
| H5 | Clock runs out in the mulligan | pending | | |
| H6 | Clock runs out in a choice dialog | pending | | |
| H7 | Coin popup times out | pending | | |
| H8 | Zoom held over 60 s on the opponent's turn | pending | | |
| H9 | Full Timed match | pending | | |
| H10 | Normal mode shows no clock | pending | | |
| I1 | Touch input | pending | | |
