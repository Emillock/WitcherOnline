# Gwent Duels on 5.01 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Witcher Online Gwent duels back on The Witcher 3 5.01 with our own lockstep multiplayer code on CDPR's 5.01 Flash Gwent board.

**Architecture:** A Python build tool decompiles the player's own vanilla 5.01 board with JPEXS FFDec, applies our patches to CDPR classes, appends our new `Duel*` classes to a host script, recompiles with FFDec `-importScript`, re-wraps the movie into the `.redswf` and packs a mod bundle. In the board, both clients run the full match; only moves and choices travel, through Witcher Online's existing 20-message window. Seeded per-seat random streams, seat-stable card ids and a state hash on every message keep the two boards identical or end the match as no contest.

**Tech Stack:** ActionScript 3 (Scaleform AVM2, compiled by FFDec 26.4.0), WitcherScript (5.01 annotations `@wrapMethod`/`@addMethod`), Python 3.14 + pytest 9, Emillock/witcher3-coop test harness (`run_test.py`, `compile.sh`, `deploy.py`).

**Spec:** `docs/superpowers/specs/2026-11-02-gwent-duels-5.01-design.md` (same repo). Read it before any task; section numbers below refer to it.

## Global Constraints

- Repos and branches: `Emillock/WitcherOnline` clone, new branch `gwent-duels-5.01` off `shared-enemies`; `Emillock/witcher3-coop` clone, new branch `gwent-duels-5.01` off `main`. Commit locally only; pushing and PRs need the user's explicit OK.
- Never open `x4lva/gwent-multiplayer` or the board shipped in Witcher Online (`witcher/mods/modWitcherOnline/content/blob0.bundle` and anything decompiled from it). Spec section 13.
- Any step marked **[game]** installs into the user's game folder (`C:\Program Files (x86)\GOG Galaxy\Games\The Witcher 3 Wild Hunt GOTY`) through `deploy.py` and launches the game. Ask the user before the first [game] step of each working session, and run `python deploy.py uninstall` when the session's testing ends.
- Pinned tools: FFDec 26.4.0 `https://github.com/jindrapetrik/jpexs-decompiler/releases/download/version26.4.0/ffdec_26.4.0.zip` sha256 `56ce960aeafc7caf034e2052ba49f878a883f7c7ca690da6eeffca9587b5e4b9`; Temurin JRE `https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_windows_hotspot_21.0.13_9.zip` sha256 `2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628`.
- Known vanilla boards (`gameplay\gui_new\swf\gwint\gwint_game.redswf` from `content\content0\bundles\r4gui.bundle`): game 5.0.0.1048522 sha256 `aeb1255be5a4d218bf41a7630dd27e4b25b32936c0f06055fa77e7aec4d5664e`. Add the 5.01c (5.0.0.1090142) hash when a 5.01c install is available; both duel players need the same build.
- Movie inside the vanilla `.redswf`: `CFX` magic at offset `0x35b`, version byte 12, preceded by a u32 length. Re-wrapped movies keep magic `CFX` and version 12.
- Message tokens contain no spaces and no `~`. The Surrender token contains the literal `QUITGAME`.
- All new AS3 classes live in package `red.game.witcher3.menus.gwint`, are named `Duel*` or `NetOpponentController`, and are appended to the host script `red/game/witcher3/menus/gwint/CardTransaction.as` at build time.
- 32-bit integer math in AS3 must be exact: wrap every shift result in `uint(...)`, never multiply two values that can exceed 2^21 each without splitting.
- When `gwint.game.seed` is 0 every hook falls through to vanilla behavior.
- Timed mode turn length: 60 s. Stuck-wait limits: 120 s in Normal mode, turn time + 30 s in Timed mode.
- No em dashes in code, comments, docs or commit messages.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Single-player Gwent with no duel running (quest match against the AI, tutorial): must behave exactly as vanilla. Test: `gwent_vanilla` scenario in Task 5 and Task 16.
2. The same window delivered again and again, out of order, or a late window from the previous game after a Replay: must apply each message exactly once. Test: window vectors in Task 6, parity in Task 7.
3. One side has a different card table (Gwent card mod, different build): must end as no contest at Hello, no money moves. Test: `gwent_duel` with `W3T_GWENT_BREAK_TEMPLATES=1` in Task 9.
4. The opponent's game closes mid-match: the survivor must end as no contest within the stuck-wait limit and pay nothing. Test: `gwent_duel` with `W3T_GWENT_EXIT_AT=6` in Task 15.
5. In Timed mode a player does nothing: their turn must auto-pass after 60 s and the match must finish. Test: `gwent_duel` with `W3T_GWENT_IDLE_SEAT=B` in Task 16.

## File Map

WitcherOnline repo (`gwent/` is new):

| Path | Responsibility |
|---|---|
| `gwent/build/build.py` | CLI: `tools`, `vanilla`, `diff`, `build` |
| `gwent/build/tools.py` | download and verify FFDec and the JRE into `gwent/.tools/` |
| `gwent/build/bundle.py` | read 4.x/5.x POTATO70 bundles, write 4.x bundles, read/write `metadata.store` |
| `gwent/build/redswf.py` | extract and re-wrap the movie in a `.redswf` |
| `gwent/build/ffdec.py` | FFDec wrapper: export scripts, import scripts, dump AS3 |
| `gwent/build/patches.py` | apply/generate patches, append `gwent/src` classes to the host script |
| `gwent/build/vectors.py` | generate `gwent/src/DuelVectors.as` from `gwent/tests/vectors.json` |
| `gwent/tools/duelref.py` | Python reference of DuelRandom, DuelHash words, DuelCodec, DuelWindow (source of test vectors) |
| `gwent/tools/duel_logdiff.py` | compare two clients' duel logs, report first divergence |
| `gwent/tests/` | pytest suites and `vectors.json` |
| `gwent/src/*.as` | our AS3 classes |
| `gwent/patches/*.patch` | unified diffs against FFDec 26.4.0 output of the vanilla board |
| `gwent/out/` (ignored) | build output `modWitcherOnline/content/{blob0.bundle,metadata.store}` |
| `witcher/mods/modWitcherOnline/content/scripts/local/gwentDuel.ws` | new: 5.01 `CR4GwintGameMenu` wrappers and duel script logic |
| `witcher/mods/modWitcherOnline/content/scripts/local/client.ws`, `remotePlayer.ws`, `gwentHooks.ws` | modified |

witcher3-coop repo: `deploy.py`, `run_test.py`, `run_suite.py`, `w3test/modW3Test/content/scripts/local/w3test_gwent.ws` (new).

## Shared Interfaces (used by several tasks)

```
// gwent/src/DuelRandom.as
public class DuelRandom {
	public static const STREAM_A:int = 0; public static const STREAM_B:int = 1; public static const STREAM_SHARED:int = 2;
	public function DuelRandom(seed:uint, gameNumber:int)
	public function nextUint(stream:int):uint
	public function nextInt(stream:int, n:int):int        // 0 <= result < n, n >= 1
}
// gwent/src/DuelHash.as  (pure FNV-1a style accumulator)
public class DuelHash { public function DuelHash(); public function addInt(v:int):void; public function value():uint }
// gwent/src/DuelIds.as
public class DuelIds {
	public static const SEAT_A:int = 0; public static const SEAT_B:int = 1;
	public function assign(seat:int, instanceId:int):int   // returns netId = seat * 65536 + ordinal, ordinal from 1
	public function toLocal(netId:int):int                 // -1 if unknown
	public function toNet(instanceId:int):int              // -1 if unknown
	public function forget(instanceId:int):void
	public function reset():void
	public static function format(netId:int):String        // "A17"
	public static function parse(s:String):int             // -1 if malformed
}
// gwent/src/DuelMessage.as, DuelCodec.as
public class DuelMessage { public var version:int; public var matchId:String; public var seq:int; public var type:String; public var args:Array; public var hash:uint }
public class DuelCodec { public static function encode(m:DuelMessage):String; public static function decode(token:String):DuelMessage /* null if malformed */ }
// gwent/src/DuelWindow.as
public class DuelWindow {
	public function DuelWindow(matchId:String)
	public function ingest(window:String):void            // splits on "~", ignores "none", other matchId, other version, seq already queued or applied
	public function peek():DuelMessage                    // next expected seq or null
	public function pop():DuelMessage
	public function get gap():Boolean                     // true if a seq > expected was seen while expected is missing
}
// gwent/src/DuelSession.as (board-aware)
public class DuelSession {
	public static function get active():DuelSession      // null outside duels
	public function get localSeat():int
	public function seatOf(player:int):int; public function playerOf(seat:int):int
	public function get random():DuelRandom; public function get ids():DuelIds
	public function send(type:String, args:Array, scope:int):void   // scope: DuelStateHash.SCOPE_FULL or SCOPE_SEAT
	public function onRemoteInput(window:String):void
	public function update():void                         // called every frame from GwintGameFlowController
	public function decide(kind:String, seat:int, askerNetId:int, showLocal:Function, apply:Function):void
	public function abort(reason:String):void
	public function log(line:String):void                 // calls script OnDuelLog(line)
	public static function randomInt(ownerPlayer:int, n:int):int   // owner's seat stream in duels; vanilla Math.min(Math.floor(Math.random() * n), n - 1) outside
	public function deferEffect(card:CardInstance, run:Function):void   // Task 13
}
```

Wire format (spec 8.1, decided here): `1.<matchId>.<seq>.<type>.<arg1>,<arg2>,...  .<hashHex8>` with fields joined by `.`, args joined by `,`, empty args written as `_`. `matchId` = `<seed as uint, lowercase hex>g<gameNumber>`. Types: `H` hello (tplHashHex, deckHashAHex, deckHashBHex), `P` play to row (netId, slotId, targetSeat `A`/`B`), `C` play on card (netId, targetNetId), `G` global (netId), `L` leader, `S` pass, `D` decision (kind, asker netId or `perk` or `coin`, choice), `M` mulligan done, `QUITGAME` surrender, `Y` desync (hashHex, seq), `R` replay, `X` leave. Decision kinds: `MUL`, `COIN`, `NUR`, `LRES`, `LWEA`, `LBIN`, `LPICK`. Choice: netId, `t<templateId>`, `1`/`0`, or `none`.

Duel log lines (pinned, used by `duel_logdiff.py` and bot assertions): `DUEL HELLO ok seat=<A|B>`, `DUEL SEND <token>`, `DUEL APPLY <token> mine=<hashHex8>`, `DUEL ROUND <n> scores=<a>,<b> hash=<hashHex8>` (seat order, logged when round n starts, after perks and before the first turn; the hash is `DuelStateHash.compute(SCOPE_FULL, 0)`), `DUEL DESYNC seq=<n> mine=<h> theirs=<h>`, `DUEL END result=<win|loss|draw|nocontest> reason=<text> game=<n>`.

Script surface (decided here): board to script calls `OnMultiplayerMessage(token)` (existing), `OnMultiplayerAbort(reason)`, `OnMultiplayerDraw()`, `OnDuelLog(line)`; script to board flash values `gwint.game.seed`, `gwint.game.isHost`, `gwint.game.isTimed`, `gwint.game.remoteInput` (existing), `gwint.game.opponentLeft` (bool), `gwint.game.debug.autoplay` (bool), `gwint.game.debug.corruptAt` (int seq, 0 off), `gwint.game.debug.forceDraw` (bool), `gwint.game.debug.breakTemplates` (bool), `gwint.game.debug.selfTest` (bool). Script method `r_MultiplayerClient.duelLog(line : string)` writes `LogChannel('GwentDuel', line)`; the test mod wraps it to also call `W3T_Log`.

---

### Task 1: Pinned tools and vanilla board extraction

**Files:**
- Create: `gwent/build/build.py`, `gwent/build/tools.py`, `gwent/build/bundle.py` (port of the scratchpad reader with a writer added in Task 3), `gwent/.gitignore` (`.tools/`, `work/`, `out/`)
- Test: `gwent/tests/test_tools.py`, `gwent/tests/test_bundle_read.py`

**Interfaces:**
- Produces: `tools.ensure() -> ToolPaths(java: Path, ffdec_cli_jar: Path)`; `bundle.entries(path) -> Iterator[Entry(name, size, csize, offset, comp)]`; `bundle.extract(path, name) -> bytes`; `build.py vanilla --game <dir>` writes `gwent/work/vanilla.redswf` and refuses a board whose sha256 is not in `KNOWN_BOARDS` unless `--allow-unknown-board`.

- [ ] **Step 1: Write failing tests**: `test_verify_rejects_bad_checksum` (a temp file with wrong content makes `tools.verify(path, sha)` raise `ToolChecksumError`); `test_entries_reads_v5_and_v3` (a synthetic v5 bundle and a synthetic v3 bundle, built in the test with `struct.pack`, each list one entry with the right name, size and offset); `test_known_board_hash` (`build.KNOWN_BOARDS["5.0.0.1048522"] == "aeb1255be5a4d218bf41a7630dd27e4b25b32936c0f06055fa77e7aec4d5664e"`).
- [ ] **Step 2: Run** `python -m pytest gwent/tests/test_tools.py gwent/tests/test_bundle_read.py -v`. Expected: FAIL (modules missing).
- [ ] **Step 3: Implement** `tools.verify`, `tools.ensure` (download the two pinned zips from Global Constraints into `gwent/.tools/`, verify, unzip each into its own empty folder), `bundle.entries`/`bundle.extract` (v5: 0x130-byte entries, u64 offset at 0x110, zlib when size != csize; v3: 0x140-byte entries, size/csize/offset u32 at 0x114, comp u32 at 0x13C, LZ4 block = 4 or 5), and `build.py vanilla`.
- [ ] **Step 4: Run** the tests again. Expected: PASS. Then run `python gwent/build/build.py vanilla --game "C:\Program Files (x86)\GOG Galaxy\Games\The Witcher 3 Wild Hunt GOTY"` (read-only on the game folder). Expected: `gwent/work/vanilla.redswf`, 12284472 bytes, hash matches.
- [ ] **Step 5: Commit** `feat(gwent): pinned build tools and vanilla board extraction`.

### Task 2: `.redswf` movie extract and re-wrap

**Files:**
- Create: `gwent/build/redswf.py`
- Test: `gwent/tests/test_redswf.py`

**Interfaces:**
- Produces: `redswf.read_movie(data: bytes) -> Movie(fws: bytes, version: int, blob_offset: int)`; `redswf.rewrap(data: bytes, fws: bytes) -> bytes` (zlib-compresses the FWS body, writes `CFX` + version + length header, replaces the length-prefixed blob, fixes every CR2W size, offset and checksum field the change affects).

- [ ] **Step 1: Write failing tests** on `gwent/work/vanilla.redswf` (skip if absent): `test_read_movie` (`len(fws) == 6490511`, `fws[:3] == b"FWS"`, version 12); `test_rewrap_roundtrip_identity` (`rewrap_raw(data, original_compressed_blob) == data`, where `rewrap_raw` replaces the blob without recompressing; this pins the CR2W bookkeeping); `test_rewrap_changed_movie` (`fws2` = the movie with one byte of an ASCII string constant changed, so the compressed size changes; `read_movie(rewrap(data, fws2)).fws == fws2`, and the CR2W header parses with its sizes consistent with the new file length).
- [ ] **Step 2: Run** `python -m pytest gwent/tests/test_redswf.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement.** Approach: parse the CR2W v164 header and tables enough to find every size/offset that lies after or around `0x357`, and the header CRC32 if present (`CR2W` header layout from WolvenKit's documented format; confirm field by field against the identity test). Keep everything after the blob byte-identical except shifted.
- [ ] **Step 4: Run** the tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(gwent): redswf movie extract and rewrap`.

### Task 3: Mod bundle and `metadata.store` writer

**Files:**
- Modify: `gwent/build/bundle.py`
- Test: `gwent/tests/test_bundle_write.py`

**Interfaces:**
- Produces: `bundle.write_v3(path, files: list[tuple[str, bytes]])` (uncompressed entries, comp 0); `bundle.read_metadata(path) -> Metadata`; `bundle.write_metadata(path, bundles: list[Path])`.

- [ ] **Step 1: Write failing tests**: `test_write_v3_roundtrip` (write one 1000-byte entry named `gameplay\gui_new\swf\gwint\gwint_game.redswf`, read back with `entries`/`extract`, identical); `test_metadata_reproduces_existing` (parse `witcher/mods/modWitcherOnline/content/metadata.store`, 332 bytes, then `write_metadata` for that folder's `blob0.bundle` gives the same bytes, allowed to read the bundle's entry table only; this is the one permitted use of that file and does not decompile its contents).
- [ ] **Step 2: Run** `python -m pytest gwent/tests/test_bundle_write.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** the writer and the `metadata.store` reader/writer; derive the field layout from the 332-byte file and the bundle's header.
- [ ] **Step 4: Run** the tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(gwent): mod bundle and metadata.store writer`.

### Task 4: Decompile, patch, host classes, recompile

**Files:**
- Create: `gwent/build/ffdec.py`, `gwent/build/patches.py`, `gwent/src/DuelProbe.as`, `gwent/patches/GwintGameMenu.patch`
- Modify: `gwent/build/build.py` (commands `diff` and `build`)
- Test: `gwent/tests/test_patches.py`, `gwent/tests/test_build.py`

**Interfaces:**
- Consumes: Task 1 `tools.ensure`, Task 2 `redswf`, Task 3 `bundle.write_v3`/`write_metadata`.
- Produces: `ffdec.export_scripts(swf, out_dir)` (LF line endings), `ffdec.import_scripts(swf, scripts_dir, out_swf)`, `ffdec.dump_as3(swf) -> list[str]` (class names); `patches.host(host_text: str, sources: list[str]) -> str` (merges import lines into the host package block, appends each source's class body after the host class); `build.py build` writes `gwent/out/modWitcherOnline/content/{blob0.bundle,metadata.store}`; `build.py diff` regenerates `gwent/patches/*.patch` from `gwent/work/edit/` against `gwent/work/vanilla/` (`git diff --no-index`, prefixes rewritten so `git apply -p1` works from the scripts root).
- `DuelProbe`: `public static function ping(menu:GwintGameMenu):void` dispatches `GameEvent.CALL "OnDuelProbe"` with `["probe-1"]`. The patch makes `GwintGameMenu.configUI` call `DuelProbe.ping(this)` once.

- [ ] **Step 1: Write failing tests**: `test_host_merges_imports` (host with `import a.B;`, source with `import a.B; import c.D;` gives one `a.B` and one `c.D` import and both classes inside one package block); `test_build_lists_probe_class` (run `build.py build` into a temp out dir, `dump_as3` of the result contains `red.game.witcher3.menus.gwint.DuelProbe` and `...CardTransaction`; decompiled `GwintGameMenu` contains `DuelProbe.ping`).
- [ ] **Step 2: Run** `python -m pytest gwent/tests/test_patches.py gwent/tests/test_build.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** `ffdec.py`, `patches.py`, `build.py diff` and `build.py build` (vanilla extract, decompile into `work/vanilla`, copy to `work/build`, `git apply -p1` each patch, host `gwent/src/*.as` into `CardTransaction.as`, import only the changed files, re-wrap, write bundle and metadata).
- [ ] **Step 4: Run** the tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(gwent): decompile, patch and rebuild the board`.

### Task 5: In-game go/no-go for hosted classes **[game]**

**Files:**
- Create: `witcher/mods/modWitcherOnline/content/scripts/local/gwentDuel.ws` with `@addMethod(CR4GwintGameMenu) event OnDuelProbe(arg : string)` that logs `GwentDuel: probe <arg>`. This is the second go/no-go: whether `@addMethod` can add an `event` that Flash calls. Fallback if the compiler rejects it or the event never fires: ship a full copy of the 5.01 `gwintGameMenu.ws` with the additions, as Witcher Online's 4.04 override does, and adjust Task 8 accordingly.
- witcher3-coop: modify `deploy.py` (drop `gwintManager.ws`/`gwintGameMenu.ws` 4.04 overrides always; take the board from `--extra <WitcherOnline>\gwent\out\modWitcherOnline\content=mods\modWitcherOnline\content` instead of the repo's 4.04 `blob0.bundle`); create `w3test/modW3Test/content/scripts/local/w3test_gwent.ws` with scenario `gwent_vanilla` (bot starts a vanilla match against deck `W3T_GWENT_DECKS` first entry, default `North`, sets `gwint.game.debug.autoplay`, waits for the result); modify `run_test.py` (`gwent_vanilla` single bot, 300 s) and `run_suite.py` (add it).

**Interfaces:**
- Produces: scenario `gwent_vanilla`; bot log line `GWENT RESULT <won|lost>`; the probe log `GwentDuel: probe probe-1`.

- [ ] **Step 1: Ask the user** for the go-ahead to deploy and launch the game.
- [ ] **Step 2: Run** `python run_test.py gwent_vanilla --bots 1` (witcher3-coop root) with the probe build deployed. Expected: `RESULT: PASS`, bot log contains `GwentDuel: probe probe-1` and `GWENT RESULT`. If the probe line is missing, stop: the hosted-class approach fails at runtime and the plan needs a new build strategy (report to the user).
- [ ] **Step 3: Run** `python deploy.py uninstall`. Expected: manifest emptied, game folder restored.
- [ ] **Step 4: Commit** both repos `test(gwent): in-game probe for hosted board classes`.

Note: `gwent.game.debug.autoplay` outside a duel is implemented in Task 9; until then the bot finishes the vanilla match by surrendering after the probe line appears.

### Task 6: Python reference and test vectors

**Files:**
- Create: `gwent/tools/duelref.py`, `gwent/tests/test_duelref.py`, `gwent/tests/vectors.json` (generated by `python gwent/tools/duelref.py vectors`)

**Interfaces:**
- Produces: `DuelRandom(seed, game).next_uint(stream)`, `.next_int(stream, n)`; `hash_words(words: list[int]) -> int`; `encode(msg: dict) -> str`, `decode(token) -> dict | None`; `Window(match_id).ingest(window: str)`, `.peek()`, `.pop()`, `.gap`; vectors file with keys `random`, `hash`, `codec`, `window`.

Algorithms (pinned; the AS3 versions must match bit for bit):

```
xorshift32(x): x ^= (x << 13) & 0xFFFFFFFF; x ^= x >> 17; x ^= (x << 5) & 0xFFFFFFFF; return x
stream seed:   s = (seed ^ ((stream + 1) * 0x9E3779B9 & 0xFFFFFFFF) ^ (game * 0x85EBCA6B & 0xFFFFFFFF)) & 0xFFFFFFFF
               if s == 0: s = 0x6D2B79F5;  then apply xorshift32 8 times (discarded)
next_uint:     state = xorshift32(state); return state
next_int(n):   limit = (2**32 // n) * n; repeat v = next_uint() until v < limit; return v % n
hash:          h = 0x811C9DC5; for each word as 4 little-endian bytes b: h ^= b; h = (h * 16777619) & 0xFFFFFFFF
               (AS3: h = uint(uint(h << 24) + h * 403) after h ^= b, which equals the multiply mod 2^32)
```

- [ ] **Step 1: Write failing tests**: `test_random_first_values` (`DuelRandom(1, 0)` stream A first three values match the vectors file entries generated once and checked by hand against an independent 64-bit computation in the test); `test_next_int_range` (10000 draws of `next_int(STREAM_B, 7)` all in 0..6); `test_streams_independent` (drawing from A does not change the next value of B); `test_hash_known` (`hash_words([]) == 0x811C9DC5`, `hash_words([1])` equals FNV-1a of bytes `01 00 00 00`); `test_codec_roundtrip` (`decode(encode(m)) == m` for one message of every type; `decode("1.abc.x.P._.0")` is None; no token contains a space or `~`; the Surrender token contains `QUITGAME`); `test_window_dedupe_and_gap` (ingest `"none"`, then the same 3-message window twice, then a window with seqs 5..7: pops 1, 2, 3 once each, then `gap` is True; a window with another matchId is ignored).
- [ ] **Step 2: Run** `python -m pytest gwent/tests/test_duelref.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** `duelref.py` and its `vectors` command.
- [ ] **Step 4: Run** the tests. Expected: PASS. Generate `vectors.json`.
- [ ] **Step 5: Commit** `feat(gwent): python reference and test vectors`.

### Task 7: Pure AS3 classes and in-game self-test **[game]**

**Files:**
- Create: `gwent/src/DuelRandom.as`, `DuelHash.as`, `DuelIds.as`, `DuelMessage.as`, `DuelCodec.as`, `DuelWindow.as`, `DuelSelfTest.as`; `gwent/build/vectors.py` (writes `gwent/src/DuelVectors.as` from `vectors.json`, as static arrays)
- Modify: `gwent/patches/GwintGameMenu.patch` (replace the probe with: if `gwint.game.debug.selfTest` is true, run `DuelSelfTest.run()` and report through `OnDuelLog`); delete `gwent/src/DuelProbe.as`
- witcher3-coop: `w3test_gwent.ws` scenario `gwent_selftest`; `run_test.py`/`run_suite.py` entries
- Test: `gwent/tests/test_vectors_gen.py`

**Interfaces:**
- Consumes: Shared Interfaces block; Task 6 algorithms and vectors.
- Produces: the pure classes; `DuelSelfTest.run():Array` (list of failure strings, empty when all pass); log line `DUEL SELFTEST pass=<n> fail=<m>`.

- [ ] **Step 1: Write failing test** `test_vectors_gen` (generated `DuelVectors.as` declares `RANDOM`, `HASH`, `CODEC`, `WINDOW` arrays with the counts in `vectors.json`).
- [ ] **Step 2: Run** `python -m pytest gwent/tests/test_vectors_gen.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** `vectors.py` and the AS3 classes. `DuelSelfTest` replays every vector through the AS3 classes. Every class and public function gets a `/** */` doc comment.
- [ ] **Step 4: Run** the pytest again (PASS), `python gwent/build/build.py build` (PASS: `dump_as3` lists all `Duel*` classes), then **[game]** `python run_test.py gwent_selftest --bots 1`. Expected: `RESULT: PASS` and `DUEL SELFTEST pass=<n> fail=0`.
- [ ] **Step 5: Commit** `feat(gwent): pure duel classes with in-game self-test`.

### Task 8: Script side: menu wrappers, transport, deck exchange, version marker

**Files:**
- Modify: `witcher/mods/modWitcherOnline/content/scripts/local/gwentDuel.ws` (all 5.01 `CR4GwintGameMenu` wrappers: duel flash values from spec 11 and the Script surface block, `OnMultiplayerMessage`, `ReceiveRemoteGwentAction`, `OnQuitGameConfirmed` calling flash `onQuitConfirmed`, `OnMultiplayerAbort`, `OnMultiplayerDraw`, `OnDuelLog`, player names, enemy deck from the duel with empty `dynamicCards`/`additionalCards`); `client.ws` (remove `WO_GWENT_PVP` fences at the duel start, `gwentGameLoop`, state clear and the `wo3` deck field; deck sent as leader, special card and card names; protocol field in the challenge handshake, challenges with a different value refused with a HUD message); `remotePlayer.ws:389` (faction from leader name); `gwentHooks.ws` (`@addMethod` for `HandleOutgoingGwentAction` and `NotifyGwentMatchEnded` on `CR4GwintGameMenu`); add `duelLog` to `r_MultiplayerClient`
- Delete from the 5.x deploy: `gwintManager.ws`, `gwintGameMenu.ws` (4.04 overrides; files stay in the repo for `main`)

**Interfaces:**
- Consumes: Script surface block.
- Produces: a duel opens the Gwent menu on both clients with seed, host flag, timed flag and the opponent's deck; `duelLog`; script-side result handling: win/loss settles as today, `OnMultiplayerDraw` and `OnMultiplayerAbort` skip `settleGwentBet`.

- [ ] **Step 1: Write the failing check**: `bash compile.sh gwent-script` (witcher3-coop) **[game]**, after adding a deliberate use of `OnMultiplayerAbort` in `client.ws` before defining it. Expected: compile error naming it.
- [ ] **Step 2: Implement** the script changes. Card names: confirm in `v501/scripts` (or `GetCardDefs`) that no card name contains a space; if any does, encode spaces as `%20` in the packet.
- [ ] **Step 3: Run** `bash compile.sh gwent-script`, `python ws_type_check.py`, `python ws_undefined_check.py`. Expected: no errors.
- [ ] **Step 4: Commit** `feat(gwent): 5.01 script side for duels`.

### Task 9: Duel session, seats, Hello, net ids, autoplay and the duel harness **[game]**

**Files:**
- Create: `gwent/src/DuelSession.as`, `gwent/src/DuelStateHash.as`, `gwent/src/NetOpponentController.as` (skeleton: holds a move queue, `startTurn` waits), `gwent/tools/duel_logdiff.py`, `gwent/tests/test_logdiff.py`
- Modify patches: `GwintGameMenu` (register the new flash values, create `DuelSession` when seed != 0, force tutorials and AI off, install `NetOpponentController` as `PLAYER_2`), `GwintGameFlowController` (call `DuelSession.active.update()` each frame; block leaving `Initializing` until Hello is done), `CardManager` (`spawnCardInstance` assigns net ids through `ids.assign(seatOf(forPlayer), id)`; deleting instances calls `ids.forget`; script card injection ignored in duels), `HumanPlayerController` (autoplay: when `gwint.game.debug.autoplay` is set, choose moves with the vanilla AI evaluation and feed them through the normal commit points)
- witcher3-coop: `w3test_gwent.ws` scenario `gwent_duel` (bot 0 hosts, bot 1 accepts; env `W3T_GWENT_DECKS` = two entries, each a built-in deck name from `Nilf`, `NilfEasy`, `North`, `nml`, `scotial`, `ske` or an inline custom deck `leaderName+cardName+cardName...`; `W3T_GWENT_SEED` forces the host's seed; `W3T_GWENT_TIMED`; `W3T_GWENT_MULLIGAN` (autoplay redraws when 1, declines when 0, default 0); `W3T_GWENT_EXPECT` (`result` default, or `nocontest`); plus the debug variables named in later tasks; wraps `duelLog` to `W3T_Log`); `w3test/gwent_decks.txt` (named custom decks, one per line `name: leader+card+...`, built from `GetCardDefs` names: `plain_nr`, `plain_nilf`, `plain_nml`, `plain_ske` with unit cards only and a leader whose ability has no choice; `medic_nr` with medics; `leaders_nilf` with a choice leader; `agile_medic` with a medic and agile cards); `run_test.py` (`gwent_duel` two bots, 600 s, expands `gwent_decks.txt` names into `W3T_GWENT_DECKS`, then runs `duel_logdiff.py` on both bot logs and fails on divergence)

**Interfaces:**
- Consumes: Tasks 7 and 8.
- Produces: `DuelSession` per Shared Interfaces; `DuelStateHash.SCOPE_FULL:int = 0`, `SCOPE_SEAT:int = 1`, `DuelStateHash.compute(scope:int, seat:int):uint` covering exactly the fields in spec 8.4 (hands as sets: sort hand net ids before hashing); `duel_logdiff.py <logA> <logB>` exit 0 when the `DUEL SEND`/`DUEL APPLY` streams agree (A's SEND n equals B's APPLY n and the reverse, hashes equal) and every `DUEL ROUND` line pair has the same scores and hash, else prints `DIVERGED at <seq=n|round=n>: <detail>` and exits 1.
- Temporary: a patch to `HumanPlayerController` that passes immediately on every turn in duels ("always pass"), so Tasks 9 and 10 can run whole matches before moves are synced. Task 11 removes it.

- [ ] **Step 1: Write failing tests**: `test_logdiff_identical` (two synthetic logs that mirror each other: exit 0); `test_logdiff_hash_mismatch` (one APPLY hash changed: exit 1, message names the seq); `test_logdiff_round_mismatch` (one `DUEL ROUND 2` hash changed: exit 1, message names `round=2`).
- [ ] **Step 2: Run** `python -m pytest gwent/tests/test_logdiff.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** the logdiff tool, `DuelSession` (seat mapping, outbound seq, inbound `DuelWindow`, Hello send and check, abort path with `DUEL END result=nocontest`), `DuelStateHash`, the patches and the harness scenario. Hello mismatch reasons: `version`, `templates`, `decks`. `gwint.game.debug.breakTemplates` adds 1 to the local template hash.
- [ ] **Step 4: Run** the pytest (PASS), then **[game]** `W3T_GWENT_DECKS=North,North python run_test.py gwent_duel --bots 2` with the always-pass patch. Expected: both logs `DUEL HELLO ok seat=A` / `seat=B`, `DUEL ROUND 1` on both, the match ends, `RESULT: PASS` (the round hashes may still differ until Task 10; logdiff runs in report-only mode for this task via `W3T_GWENT_LOGDIFF=report`). Then **[game]** `W3T_GWENT_BREAK_TEMPLATES=1 ... gwent_duel`. Expected: both logs `DUEL END result=nocontest reason=templates`, no money change logged.
- [ ] **Step 5: Commit** `feat(gwent): duel session, hello and duel harness`.

### Task 10: Seeded random sites and seat-relative rules

**Files:**
- Modify patches: `GwintDeck` (`shuffleDeck`, `readdCard` with random flag), `CardManager` (`chooseCreatureToExclude`, `stealCards`, `ressurectFromGraveyard`, `shuffleGraveyards`), `CardInstance` (random medic in `updateEffectsApplied`; duel medic placement in `onNurseEffectEnded`: seat-relative row evaluation, ties from the medic owner's stream), `CardLeaderInstance` (resurrect pick at 611), `GwintGameFlowController` (coin toss from `STREAM_SHARED`; Monsters perk message check tests eligibility without drawing)
- Modify: `gwent/src/DuelRandom.as` (audit comment block: every `Math.random` in the decompiled board with its stream or "local only, because ...")

**Interfaces:**
- Consumes: `DuelSession.active.random`, `seatOf`.
- Produces: `DuelSession.randomInt(ownerPlayer:int, n:int):int` (Shared Interfaces).

- [ ] **Step 1: Write the failing check** **[game]**: with the Task 9 always-pass patch, `W3T_GWENT_DECKS=North,Nilf python run_test.py gwent_duel --bots 2` for seeds 1, 12345, 4000000000. Expected now: FAIL, logdiff reports different `DUEL ROUND 1` hashes (vanilla shuffle uses `Math.random`).
- [ ] **Step 2: Implement** the random sites and fixes listed above.
- [ ] **Step 3: Run** the same three seeds with deck pairs `North,Nilf`, `nml,nml`, `ske,ske` and `North,ske` (no Scoia'tael yet: its coin choice is synced in Task 12). Expected: `RESULT: PASS`, all `DUEL ROUND` hashes equal.
- [ ] **Step 4: Commit** `feat(gwent): seeded random sites and seat-relative rules`.

### Task 11: Moves, hash check and desync handling

**Files:**
- Modify patches: `HumanPlayerController` (send `P`, `C`, `G` or `L` at the three commit points in spec 5 and `S` in `skipTurn`, before the transaction applies; remove the Task 9 always-pass patch)
- Modify: `gwent/src/NetOpponentController.as` (apply queued moves by mapping net ids and running the vanilla `ApplyingCard` path; define the `ChoosingMove` state that `BasePlayerController.state_update_ApplyingCard` switches to; wait for tweens, FX, message queue and an open card zoom before taking the next move), `gwent/src/DuelSession.as` (compare `DuelStateHash` before applying each message; `Y` handling; `gwint.game.debug.corruptAt` adds 1 to one card's power on the sender right before that seq; on desync show "The match went out of sync and was cancelled" and log both hashes and the last 20 tokens)

**Interfaces:**
- Consumes: Tasks 9 and 10.
- Produces: complete move flow for cards and leaders without choices; desync path logs `DUEL DESYNC` and ends both sides with `DUEL END result=nocontest reason=desync`.

- [ ] **Step 1: Write the failing check** **[game]**: `W3T_GWENT_DECKS=plain_nr,plain_nilf W3T_GWENT_CORRUPT_AT=8 W3T_GWENT_EXPECT=nocontest ... gwent_duel`. Expected now: FAIL (no `DUEL DESYNC`).
- [ ] **Step 2: Implement** the move messages, the opponent apply path and the hash check.
- [ ] **Step 3: Run** **[game]** the corrupt check (expected: both logs `DUEL DESYNC` and `result=nocontest`, PASS), then `plain_nr,plain_nilf`, `plain_nml,plain_nml`, `plain_ske,plain_nr` with seeds 1, 12345 (expected: PASS, opposite win/loss on the two bots, logdiff clean).
- [ ] **Step 4: Commit** `feat(gwent): move sync with hash check`.

### Task 12: Decisions, coin toss and mulligan

**Files:**
- Modify patches: `CardInstance` (medic dialog through `DuelSession.decide("NUR", ...)`), `CardLeaderInstance` (`LRES`, `LWEA`, `LBIN`, `LPICK` through `decide`; the opponent-cards display stays local), `GwintGameFlowController` (mulligan for both seats at once with `MUL` decisions and `M`; round 1 waits for both; Scoia'tael choice), `GwintGameMenu` (`setFirstTurn` sends `COIN` when the local seat chose)
- Modify: `gwent/src/DuelSession.as` (`decide` routing per spec 9.6; mulligan and coin messages hashed with `SCOPE_SEAT`; comment block listing every `showDialogCard` caller in the decompiled board with its decision kind)

**Interfaces:**
- Consumes: `DuelSession.decide` (Shared Interfaces).
- Produces: every rules caller of `mcChoiceDialog` routed in duels; autoplay picks dialog options with the vanilla AI choice where one exists, else the first option, and redraws up to 2 cards at mulligan.

- [ ] **Step 1: Write the failing check** **[game]**: `W3T_GWENT_DECKS=medic_nr,leaders_nilf W3T_GWENT_MULLIGAN=1 ... gwent_duel`. Expected now: FAIL (hang at a dialog or divergence).
- [ ] **Step 2: Implement** the decision routing, concurrent mulligan and coin toss.
- [ ] **Step 3: Run** **[game]** with deck pairs `medic_nr,leaders_nilf`, `agile_medic,plain_nml`, `scotial,nml`, `Nilf,North`, `nml,nml` and seeds 1, 12345. Expected: all PASS.
- [ ] **Step 4: Commit** `feat(gwent): synced decisions, mulligan and coin toss`.

### Task 13: Canonical order for simultaneous effects

**Files:**
- Modify patches: `CardInstance` (`onFinishedMovingIntoHolder` defers rule effects to `DuelSession` in duels), `GwintGameFlowController` (paired perks run seat A then seat B: Skellige round 3, Northern Realms draw; `clearBoard` Monsters loop in seat order)
- Modify: `gwent/src/DuelSession.as` (`deferEffect(card:CardInstance, run:Function):void`; runs deferred effects when no card tween is active, ordered by seat then net id)

**Interfaces:**
- Produces: `DuelSession.deferEffect`.

- [ ] **Step 1: Write the failing check** **[game]**: `W3T_GWENT_DECKS=ske,ske` with seeds 1 to 5 until one run diverges at the Skellige round-3 perk or a multi-card landing (logdiff names the seq). Add the failing seed to the `run_suite.py` matrix.
- [ ] **Step 2: Implement** the deferral and the seat-ordered perks.
- [ ] **Step 3: Run** **[game]** the recorded seed plus the Task 12 matrix. Expected: all PASS.
- [ ] **Step 4: Commit** `feat(gwent): canonical order for simultaneous effects`.

### Task 14: Match end, surrender, draws and replay

**Files:**
- Modify patches: `GwintEndGameDialog` (in duels: Replay sends `R` and shows "Waiting for your opponent"; closing a draw sends `X`), `GwintGameFlowController` (`Reset` path starts game n+1 when both seats sent `R`: new `DuelRandom(seed, n+1)`, `ids.reset()`, `DuelWindow` with the new matchId; outbound seq keeps counting), `GwintGameMenu` (duel draw calls `OnMultiplayerDraw` instead of `OnMatchResult(false)`; surrender sends the `QUITGAME` token before `onQuitConfirmed` closes; `gwint.game.debug.forceDraw` makes the final result a draw)
- Modify: `gwent/src/DuelSession.as` (`QUITGAME` received: local win; `X` or no `R` within the stuck-wait limit: draw with no settlement)

- [ ] **Step 1: Write the failing check** **[game]**: `W3T_GWENT_FORCE_DRAW=1 W3T_GWENT_REPLAY=1 ... gwent_duel`. Expected now: FAIL (no second game).
- [ ] **Step 2: Implement** replay, leave and surrender.
- [ ] **Step 3: Run** **[game]**: force-draw with replay (expected: `DUEL END result=draw game=0`, then a second game with a different first shuffle, ending `game=1` with win/loss); force-draw with `W3T_GWENT_REPLAY=0` on one bot (expected: both `result=draw`, no money change); `W3T_GWENT_SURRENDER_AT=4` on bot 1 (expected: bot 0 `result=win reason=surrender`, bot 1 `result=loss`). All PASS.
- [ ] **Step 4: Commit** `feat(gwent): surrender, draws and replay`.

### Task 15: Opponent leaving and stuck waits

**Files:**
- Modify: `gwentDuel.ws`/`client.ws` (set `gwint.game.opponentLeft` when Witcher Online loses the opponent during a duel), `gwent/src/DuelSession.as` (react to `opponentLeft`; stuck-wait timers per Global Constraints; both end with `result=nocontest`)
- witcher3-coop: scenario variable `W3T_GWENT_EXIT_AT=<seq>` makes that bot quit the game process at that seq

- [ ] **Step 1: Write the failing check** **[game]**: `W3T_GWENT_EXIT_AT=6` on bot 1, `W3T_GWENT_EXPECT=nocontest` on bot 0. Expected now: FAIL (bot 0 hangs until timeout).
- [ ] **Step 2: Implement** the opponent-left signal and stuck-wait limits.
- [ ] **Step 3: Run** **[game]** the same. Expected: bot 0 logs `result=nocontest reason=opponent_left` within 120 s; `RESULT: PASS`.
- [ ] **Step 4: Commit** `feat(gwent): handle opponent leaving and stuck waits`.

### Task 16: Timed mode

**Files:**
- Create: `gwent/src/DuelTimerView.as` (countdown drawn with `Sprite` graphics and a `TextField` next to the active player's renderer)
- Modify: `gwent/src/DuelSession.as` (active seat's client owns the timer: 60 s, on expiry cancel any picked card and send `S`; opponent's view counts down only; mulligan timeout counts as done; decision timeout takes the first option)
- witcher3-coop: `W3T_GWENT_IDLE_SEAT=<A|B>` stops autoplay for that seat

- [ ] **Step 1: Write the failing check** **[game]**: `W3T_GWENT_TIMED=1 W3T_GWENT_IDLE_SEAT=B ... gwent_duel`. Expected now: FAIL (hang).
- [ ] **Step 2: Implement** the timer and view.
- [ ] **Step 3: Run** **[game]** the same (expected: B auto-passes each round, match ends, PASS), then `gwent_vanilla` again (Review Focus 1: still PASS, no `DUEL` lines in the log).
- [ ] **Step 4: Commit** `feat(gwent): timed mode`.

### Task 17: Full checklist, docs and hand-off

**Files:**
- Create: `gwent/README.md` (build prerequisites, `build.py` commands, how patches are made, provenance statement from spec 13)
- Modify: `run_suite.py` (all gwent scenarios and the deck/seed matrix), WitcherOnline `README.md` (5.01 duel notes)

- [ ] **Step 1: Run** **[game]** `python run_suite.py` with the gwent subset. Expected: every scenario PASS.
- [ ] **Step 2: Manual test with the user and their friend** over the Steam relay, both on the same game build, following the duel checklist in spec 14 (every faction, mirror matches, medic on agile card, decoy, scorch, weather, horn, morph, muster, berserker, banish, King cards, opponent-row modifiers, surrender, timed expiry, a drawn match with replay, touch input if a touchscreen is available), plus one quest Gwent match and the Gwent tutorial in single player. Record results in `gwent/README.md`.
- [ ] **Step 3: Run** `python deploy.py uninstall`. Expected: game folder restored.
- [ ] **Step 4: Commit** `docs(gwent): build guide and test record`. Ask the user before pushing or opening PRs.
