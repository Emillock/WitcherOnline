# Gwent duels on The Witcher 3 Remastered 5.01: design

Status: draft for review, 2026-11-02. Target branch: Emillock/WitcherOnline `shared-enemies`, later rejuvenate7/WitcherOnline.

Sections 8.2, 9.8, 9.10, 10 and 15 were brought in line with the build on 2026-11-04. Each change is marked
"Amended after the build"; the code in `gwent/src/` is the final word.

## 1. Intent

Witcher Online lets two players play Gwent against each other. On the game's 4.04 build this runs on a modified Flash
Gwent board written by x4lva. CDPR rebuilt the Gwent board for 5.0, and Emillock's 5.01 port turns duels off
(`#ifdef WO_GWENT_PVP`). This design brings duels back on 5.01 with a new implementation written for this project.

Why a new implementation and not a port of x4lva's board: x4lva's source repo (x4lva/gwent-multiplayer) has no
license file, so we cannot be sure we may reuse it. The shipped board is in the GPL-3.0 Witcher Online repo, but that
was committed by rejuvenate, not x4lva. Writing our own removes the doubt, lets us license the result under GPL-3.0,
and lets us pick a design that fits the 5.01 board.

(Amended after the build: the board is built and tested on game build 5.0.0.1048522 only, see section 12, and both
duel players need that build.)

Success looks like: two friends, one on Steam and one on GOG, both on game build 5.0.0.1090142 (5.01c) with Witcher
Online on the `shared-enemies` branch over the w3relay Steam relay, play a full Gwent duel with their own decks,
in Normal or Timed mode, with a bet, and the result and payout match on both sides in normal play. Each client
settles its own bet as Witcher Online does today (decided by the user, 2026-11-02): if the very last message of a
match is lost, the two sides can end up with different payouts, and that rare case is accepted.

## 2. Goals

- G1. Full Gwent duels on the 5.01 board: coin toss, mulligan, three rounds, all faction perks, all leader abilities,
  all card effects in the 5.01 card set, surrender.
- G2. Normal and Timed mode, as Witcher Online offers today.
- G3. Every input method the 5.01 board supports works in a duel: mouse, keyboard, controller, touch.
- G4. Desyncs are detected right away and end the match as "no contest" instead of letting the two boards drift apart.
- G5. Single-player Gwent behaves exactly as vanilla 5.01 when no duel is running.
- G6. Reproducible build from the player's own game files, with no Adobe Animate and no CDPR source in our repo.
- G7. Works with Witcher Online's existing script-side transport and duel flow (challenge, bet, timed flag, names).

## 3. Non-goals

- Anti-cheat. Both clients know both decks and the seed, so either side could compute the opponent's hand. The
  feature is for friends.
- Spectators, more than two players, or reconnecting to a match in progress. A dropped connection ends the match.
- Changes to the 4.04 build. 4.04 users keep x4lva's board.
- Deck building, the card collection or the Gwent UI outside the match board.
- Custom Player Characters support (separate effort).

## 4. Anti-goals (failure even if it "works")

- A match that silently desyncs and still pays out a bet.
- Any change in behavior for single-player Gwent (quests, tournaments, tutorial).
- Copying or translating code from x4lva's repo or from the board shipped in Witcher Online. See section 13.
- A build that only works on one developer's machine.

## 5. Constraints and facts the design rests on

Facts from the decompiled vanilla 5.01 board (JPEXS FFDec 26.4.0) and Witcher Online's scripts:

- The board is asymmetric. On each client the local player is always `CardManager.PLAYER_1` and the opponent is
  `PLAYER_2`. `GwintGameFlowController.playerControllers[PLAYER_2]` is normally an `AIPlayerController`.
- The board uses integer card template ids. Scripts use card names (`SDeckDefinition.cards : array<name>`) and convert
  with `CreateDeckDefinitionFlash` before setting `gwint.game.player.deck` and `gwint.game.enemy.deck`.
- Card instance ids come from one global counter in `CardManager` (`lastInstanceID`, set in `spawnCardInstance`). The
  two clients spawn cards in a different order (each spawns its own `PLAYER_1` first), so raw instance ids differ.
- All local moves pass through `HumanPlayerController`: three places build a `CardTransaction` and switch to
  `ApplyingCard` (`state_update_WaitConfirmation`, `handleCardChosen`, `handleHolderChosen`), and passing goes through
  `skipTurn`. Mouse clicks, controller input and touch gestures (`handleGesture` to `GwintBoardRenderer.handleGestureTap`)
  all end in those handlers.
- `BasePlayerController.state_begin_ApplyingCard` applies a transaction the same way for any controller: leader ability,
  play to a row, play onto a card, or global effect.
- Choice dialogs (`mcChoiceDialog`) are opened by rules code, with `isAI` deciding whether to pick automatically:
  medic/nurse (`CardInstance.handleNurseChoice`), and leader abilities in `CardLeaderInstance` (resurrect, weather pick,
  discard-and-draw "bin", pick a card, show opponent's cards). Mulligan uses the dialog from `GwintGameFlowController`.
- Random draws that affect game state (5.01 line numbers): `GwintDeck.shuffleDeck` (169), `GwintDeck.readdCard` (206),
  `CardManager.chooseCreatureToExclude` (555, Monsters perk), `CardManager.stealCards` (874, no caller today),
  `CardManager.ressurectFromGraveyard` (1374, Skellige perk), `CardInstance.updateEffectsApplied` (1357, random medic
  when `randomResEnabled`), `CardLeaderInstance` (611, resurrect pick), `GwintGameFlowController.state_begin_CoinToss`
  (298), `CardManager.shuffleGraveyards` (1431). `CardLeaderInstance` 583 only picks which opponent cards to show
  (display only). Mulligan redraws are not random: `readdCard` without the random flag puts the card at the bottom.
- `CardInstance.recalculatePowerPotential` is mostly AI evaluation, but not only: `onNurseEffectEnded` (1535-1542)
  places every medic-resurrected card with it and `getOptimalTransaction()`. For agile cards the row is a
  `Math.random() < 0.5` coin flip on ties (334, 340), and the `ImproveNeighbours` branch reads `PLAYER_1`'s rows
  hard-coded (330, 332). `GetRessurectionTargets(..., true)` also runs it for every graveyard candidate (1351;
  `CardLeaderInstance` 606).
- The Monsters perk draws twice: `GwintGameFlowController.state_begin_ClearingBoard` calls `chooseCreatureToExclude`
  to decide whether to show the perk message (726-733, and skips `PLAYER_2` when `PLAYER_1` triggered), and
  `CardManager.clearBoard` calls it again for each player (499-504).
- Rule effects fire when card tweens finish (`GwintCardHolder` 763-769, `CardInstance.onFinishedMovingIntoHolder`
  942 onward). Tween time is distance / 2000 (`CardTweenManager` 24, 203-211), and the board is mirrored, so when
  several cards land at once the order of their effects can differ between the two clients.
- Only `PLAYER_1`'s hand is sorted (`CardManager` 955, 1082), so hand order differs between the clients. Nothing that
  changes game state indexes into a hand.
- When both players are Skellige, the round-3 perk runs `PLAYER_1`'s resurrection first (`GwintGameFlowController`
  401-410), so a resurrected spy lands in a different row position on each client (`CardManager` 1393-1404).
- The Scoia'tael "who goes first" choice is a script popup: the board calls `OnChooseCoinFlip`, the script shows the
  popup, and the answer comes back through the flash function `setFirstTurn` (`GwintGameMenu.as` 363-380).
- Card zoom opens the same `mcChoiceDialog` the rules use (`HumanPlayerController` 747-751), and the game flow pauses
  while it is shown (`GwintGameFlowController` 116).
- A drawn match shows a Replay button (`GwintEndGameDialog` 219-233, 306-311) that goes to the `Reset` state and
  reshuffles (`GwintGameFlowController` 846-864). Closing a drawn match reports a loss (257-266).
- The template objects the board receives include localized text and an `imageLoc` that depends on the alt-art
  setting. Decks carry `specialCard` (pushed on top after the shuffle, so drawn first), `dynamicCards` looked up by
  deck name, and for the AI deck `additionalCards` (vanilla `gwintBaseMenu.ws` `CreateDeckDefinitionFlash`;
  `GwintDeck.as` 173-199).
- Scripts can inject cards mid-match through `gwent.spawnCardInstance`, `gwent.addCardToDeck` and `gwent.killCard`.
  These are reachable only from debug console commands (vanilla `game/temp.ws` 42-158).
- Bets are not escrowed: each client settles at its own menu close, the winner calls `AddMoney` and the loser
  `RemoveMoney` (`client.ws` 1754-1772, 1874-1925). The duel challenge handshake has no build or version field
  (`client.ws` 1627-1700, 2040-2071, `wo_get3` 6425-6480).
- On surrender, Witcher Online's `OnQuitGameConfirmed` calls `onQuitConfirmed` and closes the menu in the same call.
  The close clears the outgoing window unless `setLastGwentAction` has seen a message containing `QUITGAME`
  (`client.ws` 1836-1839, 1874-1893).
- `gwentHooks.ws` wraps `HandleOutgoingGwentAction` and `NotifyGwentMatchEnded`, which exist only in the 4.04
  `gwintGameMenu.ws` override.
- Transport (Witcher Online `client.ws`): the board raises the script event `OnMultiplayerMessage(message)`; the script
  appends it to a window of the last 20 messages, joined with `~`, and sends the window inside the space-separated
  `wo3` player packet together with a counter. The receiving script passes the whole window to the board in
  `gwint.game.remoteInput` whenever the counter changes. Delivery is "latest window wins": duplicates are normal, and
  more than 20 messages between two received packets would lose messages. Messages must not contain spaces or `~`.
- Existing script-to-board inputs: `gwint.game.seed` (int, 0 means not a duel), `gwint.game.isHost`,
  `gwint.game.isTimed`, `gwint.game.remoteInput`, `gwint.player.name.one/two`. Board-to-script: the
  `OnMultiplayerMessage` event, the vanilla `OnMatchResult(hasWon)` call, and the flash function `onQuitConfirmed`
  that the script calls after a surrender confirmation. The script reports the result with `NotifyGwentMatchEnded(won)`.
- The 5.01 game loads Witcher Online's old-format `blob0.bundle` from `mods\modWitcherOnline\content` and the board in
  it replaces the vanilla one.
- FFDec's `-importScript` replaces existing classes in the vanilla board. It cannot add new classes, but a script file
  that defines a second public class in the same package compiles and registers that class (tested with `-dumpAS3`;
  not yet tested at runtime in the game).

## 6. Design overview

Both clients run the full game simulation. Only player intents travel over the network: "play card X to row Y",
"pass", "picked card Z in this dialog". Because both sides start from the same decks and the same seed, and every
random draw comes from the shared seed, applying the same intents in the same order gives the same board. A hash of
the game state travels with every message, so the first difference is caught.

New pieces (names are proposals; the builder may rename):

| Piece | Role |
|---|---|
| `DuelSession` | Singleton active only in a duel. Seat mapping, outgoing message numbering, incoming window parsing and ordering, decision routing, desync handling, timer authority. |
| `DuelRandom` | Seeded random streams, one per seat plus one shared. |
| `DuelIds` | Seat-stable card ids ("net ids") and the map to local instance ids. |
| `DuelHash` | Hash of the logical game state. |
| `NetOpponentController` | `PLAYER_2` controller in a duel. Applies the opponent's moves through the vanilla transaction path. |
| `DuelTimerView` | Turn countdown drawn in code for Timed mode. |

Changed vanilla classes (as small hooks): `GwintGameMenu` (duel setup, new flash values, script calls),
`GwintGameFlowController` (controller setup, coin toss, mulligan, perks, timer), `HumanPlayerController` (send moves),
`CardManager` (ids, random sites, script card injection guard), `GwintDeck`, `CardInstance`, `CardLeaderInstance`
(random sites and decisions), `GwintEndGameDialog` if the end screen needs a "no contest" state.

When `gwint.game.seed` is 0, `DuelSession` stays inactive and every hook falls through to vanilla code (G5).

## 7. Seats, ids and randomness

### 7.1 Seats

The host is seat A, the guest is seat B. On each client: `seatOf(PLAYER_1)` is A on the host and B on the guest, and
`PLAYER_2` is the other seat. Everything that crosses the network or feeds randomness or the hash uses seats, never
local player indices.

### 7.2 Net ids

Every card instance gets a net id when it is spawned: the seat it is spawned for plus a per-seat counter, for example
`A17`. A card keeps its net id for its whole life, even when it changes side (spies, stolen cards) or changes template
(morph). Net ids are stable across clients because each seat's spawns happen in the same order on both clients, even
though the interleaving of the two seats differs. `DuelIds` keeps both maps (net id to local instance id and back),
filled from a hook in `CardManager.spawnCardInstance` and cleared when instances are deleted or the match resets.

Messages always name cards by net id. A message naming an unknown net id is a desync (section 10), not something to
guess around.

### 7.3 Random streams

`DuelRandom` holds three independent streams derived from the match seed: seat A, seat B and shared. Every random
draw that affects game state takes from the stream of the seat it concerns:

| Site | Stream |
|---|---|
| Deck shuffle, card re-added at a random deck position, graveyard shuffle | owner of the deck |
| Monsters perk, keep one creature | owner of the creatures |
| Skellige perk, resurrect two | owner of the graveyard |
| Random medic (`randomResEnabled`) | owner of the medic |
| Row choice on ties when a medic resurrects an agile card | owner of the medic |
| Leader resurrect pick | owner of the leader |
| Card stealing (`stealCards`, if anything calls it) | seat being stolen from |
| Coin toss | shared |

Per-seat streams make the result independent of which seat's code runs first on a given client, so most vanilla loops
that handle `PLAYER_1` then `PLAYER_2` need no reordering. The exception is code that draws a different number of
times depending on local player order. Known case: the Monsters perk message check in `state_begin_ClearingBoard`.
In duels that check tests eligibility only, with no draw, so the only draws are the ones in `clearBoard`.

Requirements for the generator: exact 32-bit integer arithmetic in AS3 (shifts and xor, such as xorshift32, or
multiplication split into 16-bit halves; AS3 has no `Math.imul` and a plain `uint * uint` loses precision), a fixed
seed derivation per stream, and a `nextInt(n)` without modulo bias worth caring about. The generator choice is the
builder's.

Display-only and AI-only randomness (`CardLeaderInstance` 583, `AIPlayerController`, and the rest of
`recalculatePowerPotential` at 591, 789, 818, 868) keeps using `Math.random` and must never touch the seeded streams,
because it runs a different number of times on each client. The one rules use of `recalculatePowerPotential`, medic
placement in `onNurseEffectEnded`, gets a duel-specific placement: seat-relative row evaluation (no hard-coded
`PLAYER_1`) with ties broken from the medic owner's stream. The hash excludes `powerPotential`.

The builder audits every `Math.random` in the board, not only the sites listed above, and records each one as
"stream X" or "local only, because ...". This audit list goes into the code as a comment block in `DuelRandom`.

### 7.4 Canonical order for things that happen at once

Rules results must not depend on animation timing or on which player is local. In duels:

- When several cards finish moving in the same step, their rule effects run in a canonical order (seat A before
  seat B, then by net id), not in tween-completion order. The builder picks the mechanism (for example queue the
  effects and run them once all tweens of that step have settled).
- Paired faction perks that touch both seats (both Skellige in round 3, both Monsters at round end, Northern Realms
  draw) run seat A first, then seat B, on both clients.
- Any rules code that reads `PLAYER_1` or `PLAYER_2` as "the human" or "the AI" is converted to seat-relative logic
  where it affects game state.

This is my call; the alternative (accept whatever order and rely on the hash to catch problems) would turn ordinary
plays into cancelled matches.

## 8. Messages

### 8.1 Envelope

Each message is one ASCII token with no spaces and no `~`, for example fields joined with `.`. Every message carries:

- protocol version,
- match id (derived from the seed, so a late window from a previous match is ignored),
- sender's sequence number, starting at 1 and increasing by 1,
- message type and arguments,
- `DuelHash` of the sender's state at the moment it created the message.

Keep messages short: the window holds 20 of them and is resent in every `wo3` packet. The exact grammar is the
builder's.

### 8.2 Types

| Type | Sent when | Arguments |
|---|---|---|
| Hello | board ready | protocol version, hash of the gameplay fields of the card template table (index, power, faction, types, effect flags, summon flags; not localized text or art), hash of both decks as this client sees them (leader, special card, cards) |
| Play to row | local move | net id, target row, target seat |
| Play on card | local move (decoy, mardroeme on a card, and similar) | net id, target net id |
| Play global | local move (scorch, weather clear, and similar) | net id |
| Leader | local leader ability | none (choices follow as Decision) |
| Pass | local pass, or timer expiry in Timed mode | none |
| Decision | local answer to a choice the rules asked this seat for | decision kind, net id of the card that asked (or "perk"/"coin"), chosen net id or template id, or "none" |
| Mulligan done | local player finished or skipped mulligan | none |
| Surrender | local player confirmed quit | one argument (amended after the build): `1` when the quitter settles the bet (its Hello exchange is complete), `0` when it quit while still waiting for the opponent's Hello; the token must contain the literal `QUITGAME` so Witcher Online's script keeps the window alive after the menu closes |
| Desync | local client detected a mismatch, or a wait ran out | its hash, the sequence it failed on (`0` when no sequence applies), and (amended after the build) an optional third argument: `stuck` when a wait on the opponent expired or the opponent was taken as gone, `hello` when the Hello wait expired. A receiver of a plain Desync ends as no contest with reason desync; with `stuck` as no contest with reason stuck_wait, with `hello` as no contest with reason hello_timeout |
| Replay | local player clicked Replay after a draw | none |
| Leave | local player closed the end screen of a draw without replaying | none |
| End of game (amended after the build) | a game ended and the board has settled; sent by both seats | the winner as the sender sees it (`A`, `B`, or `N` for a draw), and the whole-state `DuelHash` of the final state in the envelope |

The type letters on the wire are `H` Hello, `P` play to row, `C` play on card, `G` play global, `L` leader, `S` pass,
`D` decision, `M` mulligan done, `QUITGAME` surrender, `Y` desync, `R` replay, `X` leave and `E` end of game.

Decision kinds: mulligan redraw, Scoia'tael who-goes-first, medic pick, leader resurrect pick, leader weather pick,
leader bin pick, leader card pick. The builder adds any further choice the audit in 7.3 or a survey of
`mcChoiceDialog` callers turns up.

### 8.3 Ordering

The receiver parses the window, drops messages with a different match id or a sequence number it already applied,
and applies the next expected sequence number only. A gap (next expected number missing while a higher one is
present) is a lost message and ends the match as no contest. Messages that arrive early wait in a queue until the board
is ready for them (section 9).

### 8.4 Hash check

When the receiver is about to apply message n, it computes its own `DuelHash` and compares it with the hash in the
message. Both clients compute it at the same logical point:

- Moves (play, leader, pass): the sender is idle when it creates the message, and the receiver applies it only when
  idle, after fully applying messages 1 to n-1. The hash covers the whole state.
- Decisions inside a move, or inside a perk at round start (Skellige): both clients reach the decision point after
  the same steps (given the canonical order in 7.4), so the hash covers the whole state as it stands at that point.
- Mulligan and the coin-toss decision: the two seats mulligan at the same time, so each client's view of the other
  seat's mulligan progress differs. These messages carry a hash of the sender's own seat only (its hand, deck order and
  mulligan count). The first move of round 1 carries the first whole-state hash.

`DuelHash` covers, in seat order: every card's net id, template id, location list, owning seat and current power;
hands as sets (hand order differs between clients, see section 5); decks, graveyards and rows in order (random picks
index into them); round number; round wins; scores; passed flags; leader usable flags; active weather. It
excludes animation state, UI state and AI evaluation fields. Any fast non-cryptographic hash with exact integer math
is fine.

## 9. Match flow in a duel

1. **Setup.** The script sets seed, host flag, timed flag, names and both decks as today. `GwintGameMenu` creates the
   `DuelSession` when the seed is not 0, forces tutorials and AI off, and installs `NetOpponentController` as
   `PLAYER_2`. The board sends Hello and waits for the opponent's Hello. A mismatched template hash, deck hash or
   protocol version ends the match as no contest, with a message naming the reason (most likely cause: different game
   builds or a Gwent card mod on one side).
2. **Leaders.** Vanilla `spawnLeaders`, with net ids assigned. Counter-king logic is deterministic.
3. **Coin toss.** If exactly one seat plays Scoia'tael, that seat decides who starts: the local Scoia'tael player gets
   the vanilla script popup, and the board sends a Decision when the answer comes back through `setFirstTurn`;
   otherwise the board waits for the opponent's Decision. Otherwise the shared
   stream decides which seat starts. The result is mapped to the local player index.
4. **Mulligan.** Both players mulligan at the same time. The local dialog works as vanilla; each redraw is sent as a
   Decision and the dialog close as Mulligan done. Opponent redraws are applied to `PLAYER_2` as they arrive. Round 1
   starts when both seats are done.
5. **Turns.** On the local turn `HumanPlayerController` works as vanilla. When it commits a transaction (the three
   places in section 5) or passes, it sends the matching message before the transaction is applied. On the opponent's
   turn `NetOpponentController` takes the next queued move, maps net ids to local instances, builds a
   `CardTransaction` and runs it through the vanilla `ApplyingCard` path, then waits for effects to finish like the
   human controller does.
6. **Decisions inside a move.** Rules code that would open `mcChoiceDialog` or pick for the AI asks
   `DuelSession` who decides: the local human (show the dialog, send a Decision with the answer), the opponent (wait
   for its Decision, then call the same handler with the mapped id), or the AI (vanilla, outside duels). This replaces
   the `isAI` checks at those sites in duels only.
7. **Round end and perks.** Vanilla logic, with randomness from the streams in 7.3. Northern Realms draw, Nilfgaard
   tie win and the counter-king checks are deterministic.
8. **Match end.** The vanilla end flow runs and reports `OnMatchResult(hasWon)`. Surrender sends Surrender, and the
   receiver ends the match as a win for itself. Each client settles its own bet (user decision, see section 1).
   **Amended after the build (end of game confirmation):** a win or loss is not settled when the board reaches the
   end of a game. Both boards first send the end of game message (E: the winner as the sender sees it, and the hash of
   the final state) and wait for the opponent's. Only when it arrives with the same winner and the same hash does the end
   screen open (its close then settles the bet). A Desync in that wait, an E that differs, or no E within the stuck-wait
   limit ends the match as no contest, so a desync on the last message of a match pays neither side. The cost is that
   the end screen opens up to one round trip later than in single player. A surrender sends Surrender with the argument
   of section 8.2: with `1` the receiver ends as a win for itself, with `0` as no contest. If both players surrender
   before either sees the other's message, each settles its own loss. A surrender that crosses a Desync stays as it is:
   the quitter pays its loss and the other side ends as no contest.

   **Draws** (user decision, 2026-11-02): both players replay together with the same bet.
   - Clicking Replay sends Replay and shows "Waiting for your opponent". The new match starts only when both seats
     have sent Replay.
   - Both clients then run the vanilla `Reset` path with a new game number: match id, random streams and net ids are
     derived from (seed, game number) and start fresh; sequence numbers keep counting up so the window logic needs no
     reset.
   - If either player closes the end screen instead (Leave), or no Replay arrives within the stuck-wait limit, the
     match ends as a draw with no money moving on either side. My call: the user chose replay over "both lose", so a
     draw that is not replayed should not cost anyone.
   - Amended after the build: a draw is replayed only after both boards confirmed it with E (see above). Closing the
     end screen sends Leave, also while the board waits for the opponent's Replay; a board whose Replay wait runs out
     sends Leave itself and ends the draw. A Leave or surrender that the opponent sent just after its Replay (it left
     while this board already had both Replays and started the next game) is still taken until a message of the
     opponent's next game has been applied. The wait after Replay shows "Waiting for your opponent" once.
   - This needs a script-side change: a draw result that skips settlement, in place of today's "closing a draw counts
     as a loss".
9. **Script card injection.** In a duel, `gwent.spawnCardInstance`, `gwent.addCardToDeck` and `gwent.killCard` are
   ignored and logged.
10. **Card zoom during the opponent's turn.** Zoom uses the rules' choice dialog and pauses the flow. An opponent move
    that arrives while zoom is open waits until the player closes it. That costs the local player no time, because
    the local turn timer starts only on the local turn. My call.
    **Amended after the build (Timed mode only):** in Normal mode this stays as written. In Timed mode the zoom would
    let a player hold the opponent's move for a long time and then use a whole turn, which would push the opponent
    past the stuck-wait limit (turn time plus 30 s) and end the match as no contest. So in Timed mode the local clock
    starts when the opponent message that hands over the turn (or a decision, or the mulligan) arrives, even while a
    zoom holds it. If the clock runs out with the zoom still open, the zoom closes, the held message applies, and the
    stretch it hands over is already expired (the turn is passed, the decision takes its first option, the mulligan
    counts as done). A zoom that does not hold anything (the opponent is waiting for its own next move, or the local
    seat already passed this round) is not touched. The cost is that a Timed player who zooms on the opponent's turn
    loses that time from their own turn. A zoom on the player's own turn keeps the clock running.
11. **Deck contents.** Duel decks carry leader, special card and cards. `dynamicCards` and `additionalCards` are AI
    deck balancing and are forced empty on both sides in duels. My call.

## 10. Failure handling

- **Desync** (hash mismatch, unknown net id, sequence gap, Hello mismatch): the detecting client sends Desync, shows
  "The match went out of sync and was cancelled", writes both hashes and the last 20 messages to the log, and ends the
  match as no contest. A client receiving Desync does the same.
- **No contest** needs a new board-to-script call (proposal: `OnMultiplayerAbort(reason)`), and the script must refund
  or cancel the bet and skip `NotifyGwentMatchEnded`. This is a script-side contract change (section 11).
- **Opponent leaves** (disconnect, game closed, menu closed): Witcher Online's script already tracks the opponent's
  presence. The script tells the board through a new flash value or function, and the board ends the match as no
  contest. The builder decides the exact mechanism with the script side.
  **Amended after the build:** Witcher Online's own presence check counts engine time, which stands still while the
  Gwent board is up, so the client watches the opponent's movement sequence in real time instead. When it has not
  changed for 30 s (the clock starts again if this client itself stalled for more than 3 s), the script sets the board's
  `opponentLeft` flag. The board first applies the opponent messages that are already in the window (for at most 5 s),
  then sends Desync marked `stuck` (so an opponent that was only paused or lagging ends as no contest too instead of
  settling alone) and ends as no contest with reason opponent_left. Exceptions: a win or loss whose end of game
  messages were confirmed stands and settles; a confirmed draw ends as a draw with no money (reason opponent_leave);
  while the board waits for the opponent's E it ends through the stuck path below.
- **Stuck waiting**: if the board waits for an opponent message for longer than a generous limit (proposal: 120 s in
  Normal mode, turn time plus 30 s in Timed mode) it ends the match as no contest. My call; adjust after testing.
  **Amended after the build:** one rule covers every wait on an opponent message (Hello once this board sent its own, a
  move, a decision including the coin toss, the mulligan, E and Replay). The wait starts over whenever any opponent
  message arrives. The limit is 120 s in Normal mode and 90 s (turn time 60 s plus 30 s) in Timed mode. Past it the
  board sends Desync marked `stuck` (`hello` for the Hello wait) and then ends as no contest (reasons stuck_wait and
  hello_timeout); the opponent ends the same way when that message arrives. The Replay wait is the exception: it sends
  Leave and ends as a draw with no money (section 9.8). A decision that the local player never answers is not a wait on
  the opponent: the script's coin popup closed without an answer counts as its first option (in Timed mode its clock
  does the same), and a board decision dialog, which the player cannot cancel, is shown again when a card zoom that
  replaced it closes.

## 11. Script side (WitcherScript, Emillock's `shared-enemies` branch)

- Remove the `WO_GWENT_PVP` fences in `client.ws` (duel start, `gwentGameLoop`, state clear, deck packet) and
  `remotePlayer.ws:389`.
- Deck exchange: send the deck as card names (leader, special card, cards) in the `wo3` packet instead of the old int
  indices. The receiver builds an `SDeckDefinition` and lets `CreateDeckDefinitionFlash` convert it, so both boards get
  template ids from their own card table. The builder confirms that card names contain no spaces; if they can, encode
  them.
- Rewrite Witcher Online's `gwintGameMenu.ws` override as `@wrapMethod`/`@addMethod` against the 5.01
  `CR4GwintGameMenu`: duel flash values, `OnMultiplayerMessage`, `ReceiveRemoteGwentAction`, `onQuitConfirmed`,
  `NotifyGwentMatchEnded`, player names, enemy deck from the duel instead of the AI deck. Drop the old 4.04
  `gwintManager.ws` and `gwintGameMenu.ws` overrides.
- New: `OnMultiplayerAbort(reason)` handling, and telling the board when the opponent left. Bets are not escrowed, so
  "refund" means skipping `settleGwentBet` on that client.
- Add `@addMethod` versions of `HandleOutgoingGwentAction` and `NotifyGwentMatchEnded` (used by `gwentHooks.ws`)
  before the 4.04 override is removed.
- Add a protocol version to the duel challenge handshake and refuse challenges between different versions before any
  board opens. A 4.04 client would otherwise run x4lva's board on our messages and read our name-based deck as
  integers. My call: cheap, and the only protection the 4.04 side gets.
- Keep the 20-message window and the `~` join; the board is built for it.

## 12. Build and packaging

- Repo layout (proposal): `gwent/src/` for our new classes, `gwent/patches/` for unified diffs against the vanilla
  5.01 classes as decompiled by FFDec 26.4.0, `gwent/build.py` for the pipeline.
- `build.py`: locate the player's `content\content0\bundles\r4gui.bundle`, check the vanilla board's checksum against
  the known value (amended after the build: only the board of game build 5.0.0.1048522 is known; the build refuses
  any other unless `--allow-unknown-board` is given), extract `gameplay\gui_new\swf\gwint\gwint_game.redswf`, pull
  out the Flash movie, decompile with FFDec, apply the patches, append the new classes to host scripts, import with
  `-importScript`, compress back to
  the CFX format with the original version byte, write it back into the `.redswf` (replace the length-prefixed blob,
  fix the CR2W sizes and checksum), and pack it into the mod bundle with its `metadata.store`.
- FFDec and a Java runtime are downloaded by the build with pinned versions and checksums, or documented as a
  prerequisite. Patches depend on FFDec's exact output, so the FFDec version is pinned.
- Our repo contains no CDPR code beyond patch context lines.
- Smoke check after build: decompile the result and confirm every new class is listed and every patched class contains
  its hooks.

## 13. Provenance and licensing

- Written from this design and from the vanilla 5.01 board. The implementers do not read x4lva's repo or the board
  shipped in Witcher Online while writing it. Witcher Online's GPL-3.0 scripts are read freely, since we build on them.
- Licensed GPL-3.0, like Witcher Online.
- The PR description says plainly that this replaces x4lva's board on the 5.01 branch, credits the original duel
  feature to x4lva and rejuvenate, and invites x4lva to review.

## 14. Testing

- **Build checks**: the smoke check in section 12; a WitcherScript compile check with the existing tools in
  Emillock/witcher3-coop (`compile.sh`, `ws_type_check.py`, `ws_undefined_check.py`).
- **Log comparison**: in a duel each client logs every message it sends and applies, with its hash. A small script
  takes both logs after a match and reports the first step where they differ.
- **Single-player regression**: one vanilla match against the AI, one quest Gwent match, the tutorial.
- **Duel checklist** (two clients, both seats tried as host): every faction; mirror matches Monsters vs Monsters and
  Skellige vs Skellige; a medic resurrecting an agile card; two cards landing at once; a drawn match; every leader ability with a choice;
  medic chains; spies; decoy; scorch variants; weather and clear; horn; morph and summon; berserker and mardroeme;
  muster; banish; 5.01 King cards and opponent-row modifiers; surrender; Timed mode expiry; opponent closing the game;
  deliberate desync (debug flag that corrupts one card's power) to prove detection and no contest.
- **Two clients**: two PCs over the Steam relay. Running two game instances on one PC may be possible with Emillock's
  harness (`sandbox.py`, `arrange_windows.py`); the builder checks.

## 15. Decisions made in this document (my calls, open to change)

- Separate seat streams and net ids instead of reordering vanilla loops by host/guest.
- Desync ends the match as no contest; no attempt to resync.
- Timer authority sits with the active player's client; on expiry it sends Pass. The opponent's view only counts down.
  Turn length 60 s (proposal). In Timed mode the mulligan and decisions also time out: mulligan counts as done,
  a decision takes the first option.
  **Amended after the build:** one local clock of 60 s covers each stretch in which the board waits on local input and
  has not yet sent the message that ends it: a turn (card pick, the move and every decision the move raises, leader
  abilities), the mulligan, and a decision raised outside the local turn (the coin toss, a perk's medic). Decisions inside
  a turn share the turn's 60 s and have none of their own; once the turn's time is up, each further decision of that
  turn takes its first option at once. On expiry an open card zoom closes, open decisions take their first option, a
  card that was picked but not yet played goes back, and the board sends Pass (turn), Mulligan done with the redraws so
  far (mulligan), or the first-option answer (decision); the Scoia'tael coin popup, which belongs to the script, is closed
  by the board's timeout too. The 60 s clock keeps running while the player zooms on their own turn. On the opponent's
  turn the view counts down from 60 s when that turn starts; it is display only and never acts. The 60 s plus transit
  stays under the 90 s Timed stuck limit, so a player who is still thinking is never ended as stuck. Normal mode has no
  clock and no view. See also 9.10 for the zoom on the opponent's turn.
- Turn timer drawn in code, not copied art.
- Stuck-wait limits in section 10.
- Canonical effect order and seat-relative rules code (7.4).
- Medic placement for agile cards made seat-relative with seeded ties (7.3).
- Remote moves wait while card zoom is open (9.10).
- `dynamicCards` and `additionalCards` empty in duels (9.11).
- Version marker in the duel challenge (11).
- A draw that is not replayed ends with no money moving; sequence numbers keep counting across replays (9.8).

Decided by the user on 2026-11-02: replay together on a draw; each client settles its own bet, with no result
confirmation between the clients.

## 16. Left to the builder

Class and message naming, the message grammar, the random generator and hash function, where exactly each hook goes,
the timer's look, the log format, and the mechanism for "opponent left".

## 17. Open questions for the maintainers

- Replace x4lva's board on the 5.x branch: are rejuvenate and x4lva fine with that, or does x4lva want to port theirs?
- Branch strategy: 5.x work must not break 4.04 users on `main`.
- Script contract changes: `OnMultiplayerAbort` and skipped settlement, a draw result without settlement, deck
  exchange by card names, a version field in the duel challenge.
