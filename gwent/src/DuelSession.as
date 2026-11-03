package red.game.witcher3.menus.gwint
{
   import flash.utils.getTimer;

   /**
    * The running Gwent duel (spec 6, 7.1, 8, 9.1): exists only while gwint.game.seed is not 0, so every duel hook in
    * the vanilla classes checks DuelSession.active and falls through to vanilla when it is null.
    *
    * Holds the seat mapping (the host is seat A, spec 7.1), the net ids (DuelIds), the random streams (DuelRandom),
    * the outbound sequence numbers and the inbound DuelWindow. update() runs every 20 ms from GwintGameFlowController:
    * it sends Hello once the board has its card table and both decks, checks the opponent's Hello (protocol version,
    * card table, decks), hands the opponent's moves to NetOpponentController in seq order and, for the test bots
    * (gwint.game.debug.autoplay), answers the mulligan dialog and closes the end screen.
    *
    * Every message and result is logged through the script (OnDuelLog) with the pinned duel lines:
    * DUEL HELLO ok seat=<A|B>, DUEL SEND <token>, DUEL APPLY <token> mine=<hash>, DUEL ROUND <n> scores=<a>,<b>
    * hash=<hash>, DUEL END result=<win|loss|draw|nocontest> reason=<text> game=<n>.
    *
    * Hello (type H): args = template hash, deck hash of seat A, deck hash of seat B (hex8 each); the envelope's version
    * field carries the protocol version. A message of another protocol version never gets through DuelWindow (it drops
    * other versions), so before Hello onRemoteInput looks at the first field of every raw token (version).
    * Surrender (QUITGAME, arg 1 = the quitter settles, 0 = it quit during the Hello wait) is handled whenever it is the
    * next message, before or after Hello, and ends the game as a win (or no contest) on the receiver. R41: if both
    * players surrender before either sees the other's QUITGAME, each settles its own loss; the opponent's QUITGAME
    * that arrives after the local surrender is logged (DUEL IGNORED) and ignored. R42: a surrender that crosses a Y
    * stays as is: the quitter pays its loss, the other side ends as no contest (desync) with no money.
    *
    * Moves (spec 5, 9.5): HumanPlayerController sends P, C, G or L (sendMove) at its commit points and S when it passes,
    * before the move applies; NetOpponentController applies the opponent's moves. Move arguments:
    *   P  netId, slot (a CardManager.CARD_LIST_LOC_* number), target seat (A, B, or N for no side: the weather slot)
    *   C  netId, target netId          G  netId          L  none (the sender's leader)          S  none
    * Hash check (spec 8.4): before a message is applied its hash is compared with this client's own hash
    * (checkApply), except QUITGAME (it carries the sender's hash at the menu action, not at a logical point) and Y.
    * Desync (spec 10, R29): a hash mismatch, a move naming an unknown card or with bad arguments, a lost message (gap),
    * a message other than H before Hello, a malformed Hello, a message type this build does not handle and a local move
    * that has no message all send Y (args: this client's hash, the seq that failed, 0 when no seq applies), then the
    * client logs DUEL DESYNC seq=<n> mine=<h> theirs=<h> and the last 20 messages (DUEL RECENT), shows "The match
    * went out of sync and was cancelled" and ends as no contest (reason desync); the receiver of Y does the same,
    * without sending anything. gwint.game.debug.corruptAt=<seq> (test) adds 1 to one card's power right before this
    * client sends that seq, so the opponent's check fails.
    *
    * Decisions (spec 8.2, 9.6): rules code that would open the choice dialog (or pick for the AI) calls decide(kind,
    * seat, asker, showLocal, apply, autoChoice). The seat that decides is the local seat: the dialog is shown (once no
    * card moves and no card FX plays, so both boards hash the same settled state), the player's answer is sent as D
    * (kind, asker net id or "perk" or "coin", choice) and then applied. The other seat: the board holds (decisionOpen)
    * until the opponent's D arrives, checks its hash, then applies the same choice. Choice: a net id (NUR, LRES, LBIN,
    * MUL), t<templateId> (LWEA, LPICK) or 1/0 (COIN: 1 = the Scoia'tael seat starts). A D of another kind or asker, a
    * choice that is not one of the options, or any other message while a decision is awaited is a desync.
    * Mulligan (spec 9.4): both seats mulligan at once. Each local redraw is sent as D MUL,perk,<netId> before it
    * applies, the dialog close as M; the opponent's are applied to PLAYER_2 as they arrive (once this board has drawn
    * its hands), and round 1 starts when both seats are done. Net ids stay equal whatever order the two seats' redraws
    * arrive in, because each seat has its own id counter (DuelIds) and each seat's redraws come in its own seq order.
    * D MUL, M and D COIN carry a SCOPE_SEAT hash (the other seat may be mid-mulligan, spec 8.4); every other D carries
    * SCOPE_FULL. Autoplay (test bots) answers a decision after AUTOPLAY_DELAY_MS with the vanilla AI choice where the
    * vanilla AI has one, else the first option (autoChoice), redraws up to 2 cards at the mulligan with
    * gwint.game.debug.mulligan, and closes the opponent-cards display.
    * Canonical order (spec 7.4): the rule effects of a card that finished moving into a list
    * (CardInstance.onFinishedMovingIntoHolder), the graveyard move at the end of each scorch FX and the effects of a
    * card at the end of its morph FX are queued (deferEffect) and run one at a time in seat, then net id
    * order once the board has settled, never in tween-completion order; the board holds while any is queued
    * (effectsPending), and the queue is emptied when the game ends. The paired perks run seat A first on both boards:
    * the round start perks (Northern Realms draw, Skellige round 3) together in seat order at the first perk message
    * (GwintGameFlowController.duelRunRoundStartPerks), the Monsters round-end loop in seat order
    * (CardManager.duelClearOrder).
    * Match end (spec 9.8, R43, DuelEnd): at the end of a game (gameOver, the board settled) each board sends E (the
    * winner as it sees it: A, B, or N for a draw; SCOPE_FULL hash of the final state) and waits. Neither seat settles
    * until the opponent's E arrives with the same winner and the same hash as its own E: only then the end screen
    * opens (and its close settles a win or loss). A Y in that wait ends as no contest (desync), no E within
    * STUCK_WAIT_MS as no contest (end_timeout), so a desync on the last message of a match pays neither side.
    * gwint.game.debug.forceDraw (test) makes game 0 a draw. A confirmed draw: Replay sends R ("Waiting for your
    * opponent"); once both seats sent R the next game starts (startNextGame: game number n+1, new DuelRandom(seed, n+1),
    * fresh net ids, match id and DuelWindow, outbound seq numbers keep counting, the window goes on from the seq after
    * the opponent's R). Closing the end screen sends X; X, or no R within STUCK_WAIT_MS after the local R (then this
    * board sends X), ends the match as a draw that moves no money (OnMultiplayerDraw, R13).
    *
    * Choice dialog callers (W3ChoiceDialog.showDialog*) in the decompiled vanilla 5.01 board, file:line in that output
    * (red/game/witcher3/menus/gwint, or red/game/witcher3/controls for W3ChoiceDialog), with the decision kind:
    * - CardInstance.as:1367 NUR: the medic's resurrect pick (CardInstance.duelDecideNurse; the random medic of
    *   Invader of the North stays a seeded draw, Task 10).
    * - CardLeaderInstance.as:590 local: ShowEnemyHand (View_3_Enemy), shows the opponent's cards; it changes no state,
    *   so it is shown on the leader owner's board only and nothing is sent or hashed (duelShowsEnemyHand).
    * - CardLeaderInstance.as:620 LRES: Resurect and Resurect_Enemy with more than one target (one target and the
    *   random pick need no decision).
    * - CardLeaderInstance.as:653 LWEA: Pick_Weather with more than one weather card in the deck.
    * - CardLeaderInstance.as:694 LBIN: Bin2_Pick1, each of the two cards to discard (two D LBIN).
    * - CardLeaderInstance.as:727 LPICK: Bin2_Pick1, the card to take from the deck.
    * - GwintGameFlowController.as:327 MUL: the mulligan (each redraw a D MUL, the close an M).
    * - HumanPlayerController.as:747 local: card zoom of a hand or row, whose pick only starts a transaction; the move
    *   is sent at the commit points like any other.
    * - HumanPlayerController.as:751 local: card zoom without a pick (display only).
    * - W3ChoiceDialog.as:86 local: showDialogCardInstances hands its list to showDialog (the dialog itself).
    * - W3ChoiceDialog.as:97 local: showDialogCardTemplates hands its list to showDialog (the dialog itself).
    * The other decision of the spec is not a dialog: COIN, the Scoia'tael choice of who starts
    * (GwintGameFlowController.state_begin_CoinToss raises COIN_TOSS_POPUP_NEEDED for the script's popup, whose answer
    * comes back through GwintGameMenu.setFirstTurn).
    */
   public class DuelSession
   {

      /**
       * The stuck-wait limit (spec 10, Normal mode): how long the board waits for an opponent message it needs before
       * it gives up (the Hello, the end of game confirmation, the opponent's replay).
       */
      public static const STUCK_WAIT_MS:int = 120000;

      /** How long the board waits for the opponent's Hello before the duel ends as no contest (hello_timeout). */
      public static const HELLO_TIMEOUT_MS:int = STUCK_WAIT_MS;

      /** Autoplay: how long the mulligan dialog or the end screen stays up before the bot answers it. */
      public static const AUTOPLAY_DELAY_MS:int = 1500;

      /** What the player sees when the duel went out of sync (spec 10). */
      public static const DESYNC_TEXT:String = "The match went out of sync and was cancelled";

      /** The desync message type: args = the detector's hash (hex8), the seq that failed. */
      public static const DESYNC:String = "Y";

      /** Target seat argument of P for a slot that belongs to no side (the weather slot). */
      public static const NO_SEAT:String = "N";

      /** The decision message type: args = kind, asker, choice. */
      public static const DECISION:String = "D";

      /** The mulligan done message type (no args). */
      public static const MULLIGAN_DONE:String = "M";

      /** The end of game message type: args = the winner as the sender sees it (A, B, or N for a draw). */
      public static const END:String = "E";

      /** The replay message type (no args): the sender pressed Replay on a drawn game. */
      public static const REPLAY:String = "R";

      /** The leave message type (no args): the sender closed the end screen of a drawn game. */
      public static const LEAVE:String = "X";

      /** gwint.game.debug.corruptAt value that corrupts the state right before this board's E (test). */
      public static const CORRUPT_END:int = -1;

      /** Decision kind of a mulligan redraw. */
      public static const MULLIGAN:String = "MUL";

      /** Decision kind of the Scoia'tael choice of who starts. */
      public static const COIN:String = "COIN";

      /** Asker of a decision the rules ask without a card (the mulligan). */
      public static const ASKER_PERK:String = "perk";

      /** Asker of the coin decision. */
      public static const ASKER_COIN:String = "coin";

      private static const MOVE_TYPES:Array = ["P","C","G","L","S"];

      private static const RECENT_LIMIT:int = 20;

      private static var _active:DuelSession;

      private var _seed:uint;

      private var _gameNumber:int;

      private var _isHost:Boolean;

      private var _isTimed:Boolean;

      private var _random:DuelRandom;

      private var _ids:DuelIds;

      private var _window:DuelWindow;

      private var _matchId:String;

      private var _outSeq:int;

      private var _helloSent:Boolean;

      private var _helloDone:Boolean;

      private var _ended:Boolean;

      private var _startMs:int;

      private var _mulligans:Array;

      private var _autoSeenMs:int = -1;

      private var _autoSeenWhat:String = "";

      private var _recent:Array;

      private var _sentHashes:Object;

      private var _lastAppliedHash:uint;

      /** The decision the local seat makes now, or null. */
      private var _localDecision:DuelDecision;

      /** The decision the opponent makes now, or null. */
      private var _remoteDecision:DuelDecision;

      private var _mulligan:DuelMulligan;

      /** Rule effects waiting for the board to settle (deferEffect, spec 7.4). */
      private var _deferred:DuelDeferred;

      /** The end of this game: confirmation, replay, leave. */
      private var _end:DuelEnd;

      /** function():void that opens the end screen once the result is confirmed (GwintGameFlowController). */
      private var _showResult:Function;

      /** The opponent's last window, ingested again into a replayed game's new DuelWindow. */
      private var _lastWindow:String;

      /** This game ended by the local player's surrender. */
      private var _quitLocally:Boolean;

      /** The opponent's QUITGAME after the local surrender was logged (R41). */
      private var _lateQuitLogged:Boolean;

      /**
       * Starts a duel game (use start(), which also makes it the active one).
       * @param seed The match seed from the script.
       * @param gameNumber The game of this match, 0 for the first.
       */
      public function DuelSession(seed:uint, gameNumber:int)
      {
         super();
         this._seed = seed;
         this._gameNumber = gameNumber;
         this._random = new DuelRandom(seed,gameNumber);
         this._ids = new DuelIds();
         this._matchId = DuelMessage.matchIdFor(seed,gameNumber);
         this._window = new DuelWindow(this._matchId);
         this._outSeq = 0;
         this._mulligans = [0,0];
         this._mulligan = new DuelMulligan();
         this._deferred = new DuelDeferred();
         this._end = new DuelEnd();
         this._recent = [];
         this._sentHashes = {};
         this._startMs = getTimer();
      }

      /**
       * The running duel, or null outside duels (single-player Gwent).
       */
      public static function get active() : DuelSession
      {
         return _active;
      }

      /**
       * Makes a new duel the active one.
       * @param seed The match seed (gwint.game.seed, not 0).
       * @return The new session.
       */
      public static function start(seed:uint) : DuelSession
      {
         _active = new DuelSession(seed,0);
         return _active;
      }

      /**
       * Back to single-player Gwent: no active duel.
       */
      public static function stop() : void
      {
         if(_active != null)
         {
            _active._deferred.clear();
         }
         _active = null;
      }

      /**
       * The local seat: seat A on the host, seat B on the guest.
       */
      public function get localSeat() : int
      {
         return this._isHost ? DuelIds.SEAT_A : DuelIds.SEAT_B;
      }

      /**
       * Whether this client sent the challenge (gwint.game.isHost).
       */
      public function set isHost(value:Boolean) : void
      {
         this._isHost = value;
      }

      /**
       * Timed mode (gwint.game.isTimed).
       */
      public function get isTimed() : Boolean
      {
         return this._isTimed;
      }

      public function set isTimed(value:Boolean) : void
      {
         this._isTimed = value;
      }

      /**
       * The seat of a local player index.
       * @param player CardManager.PLAYER_1 or PLAYER_2.
       * @return DuelIds.SEAT_A or SEAT_B, -1 for any other value.
       */
      public function seatOf(player:int) : int
      {
         if(player == CardManager.PLAYER_1)
         {
            return this.localSeat;
         }
         if(player == CardManager.PLAYER_2)
         {
            return DuelIds.SEAT_B - this.localSeat;
         }
         return -1;
      }

      /**
       * The local player index of a seat.
       * @param seat DuelIds.SEAT_A or SEAT_B.
       * @return CardManager.PLAYER_1 or PLAYER_2, PLAYER_INVALID for any other value.
       */
      public function playerOf(seat:int) : int
      {
         if(seat == this.localSeat)
         {
            return CardManager.PLAYER_1;
         }
         if(seat == DuelIds.SEAT_B - this.localSeat)
         {
            return CardManager.PLAYER_2;
         }
         return CardManager.PLAYER_INVALID;
      }

      /**
       * The seeded random streams of this game.
       */
      public function get random() : DuelRandom
      {
         return this._random;
      }

      /**
       * A random index for a rules draw (spec 7.3; the audit of every Math.random is in DuelRandom). In a duel it
       * draws from the stream of the owner's seat, so the result does not depend on which seat's code runs first on a
       * client. Outside duels it is the vanilla expression, so single-player Gwent is unchanged.
       * @param ownerPlayer The local player index (CardManager.PLAYER_1 or PLAYER_2) whose deck, graveyard, hand or
       * card the draw belongs to.
       * @param n The number of choices.
       * @param site A short name of the rules site for the duel log (DUEL DRAW <site> seat=<A|B> n=<n> r=<r>); empty
       * for the deck shuffle, which draws once per card and is not logged.
       * @return A value from 0 to n - 1 (n - 1, without a draw, when n is below 1, as vanilla would give).
       */
      public static function randomInt(ownerPlayer:int, n:int, site:String = "") : int
      {
         if(_active == null)
         {
            return Math.min(Math.floor(Math.random() * n),n - 1);
         }
         if(n < 1)
         {
            return n - 1;
         }
         var seat:int = _active.seatOf(ownerPlayer);
         if(seat != DuelIds.SEAT_A && seat != DuelIds.SEAT_B)
         {
            _active.abort("random_owner");
            return 0;
         }
         var drawn:int = _active.random.nextInt(seat == DuelIds.SEAT_A ? DuelRandom.STREAM_A : DuelRandom.STREAM_B,n);
         if(site != "")
         {
            _active.log("DUEL DRAW " + site + " seat=" + seatName(seat) + " n=" + n + " r=" + drawn);
         }
         return drawn;
      }

      /**
       * The net ids of this game's card instances.
       */
      public function get ids() : DuelIds
      {
         return this._ids;
      }

      /**
       * The match id of this game ("<seed hex>g<game number>").
       */
      public function get matchId() : String
      {
         return this._matchId;
      }

      /**
       * The game of this match, 0 for the first.
       */
      public function get gameNumber() : int
      {
         return this._gameNumber;
      }

      /**
       * True once both Hellos agreed; the game flow leaves Initializing only then.
       */
      public function get helloDone() : Boolean
      {
         return this._helloDone;
      }

      /**
       * True once this game ended (result or no contest); nothing is sent or applied after that.
       */
      public function get ended() : Boolean
      {
         return this._ended;
      }

      /**
       * A seat's mulligan redraws so far (part of the SCOPE_SEAT hash).
       * @param seat DuelIds.SEAT_A or SEAT_B.
       * @return The count.
       */
      public function mulligans(seat:int) : int
      {
         return seat == DuelIds.SEAT_A || seat == DuelIds.SEAT_B ? int(this._mulligans[seat]) : 0;
      }

      /**
       * The mulligan of this game for both seats (phase, the opponent's redraws and M, this seat's M).
       */
      public function get mulligan() : DuelMulligan
      {
         return this._mulligan;
      }

      /**
       * Counts one applied mulligan redraw of a seat (after the redraw, so D MUL hashes the count before it).
       * @param seat DuelIds.SEAT_A or SEAT_B.
       */
      public function countMulligan(seat:int) : void
      {
         if(seat == DuelIds.SEAT_A || seat == DuelIds.SEAT_B)
         {
            this._mulligans[seat] = int(this._mulligans[seat]) + 1;
         }
      }

      /**
       * Sends a local mulligan redraw (D MUL,perk,<netId>, SCOPE_SEAT) before it applies.
       * @param card The PLAYER_1 hand card the player gives back.
       * @return False if the duel has ended or the card has no net id (then nothing may be redrawn).
       */
      public function sendRedraw(card:CardInstance) : Boolean
      {
         var netId:int = card != null ? this._ids.toNet(card.instanceId) : -1;
         if(this._ended || netId < 0)
         {
            return false;
         }
         this.send(DECISION,[MULLIGAN,ASKER_PERK,DuelIds.format(netId)],DuelStateHash.SCOPE_SEAT);
         return true;
      }

      /**
       * Sends the local mulligan done (M, SCOPE_SEAT: after the last redraw).
       */
      public function sendMulliganDone() : void
      {
         this.send(MULLIGAN_DONE,[],DuelStateHash.SCOPE_SEAT);
      }

      /**
       * Who makes a choice the rules ask for (spec 9.6). The local seat: showLocal() shows the choice once the board
       * has settled (no card moves, no card FX), and the UI hands the player's pick to answer(kind, choice), which
       * sends D and then calls apply(choice). The opponent's seat: the board holds (decisionOpen) until the opponent's
       * D of this kind and asker arrives, then its hash is checked and apply(choice) runs with the same choice.
       * @param kind A decision kind (NUR, LRES, LWEA, LBIN, LPICK, COIN; MUL goes through sendRedraw).
       * @param seat The seat that decides.
       * @param askerNetId The net id of the card that asks, or -1 (then the asker is "coin" for COIN, else "perk").
       * @param showLocal function():void, shows the choice to the local player.
       * @param apply function(choice:String):Boolean, applies a choice; false if it is not one of the options (a
       * desync).
       * @param autoChoice function():String, the choice duel autoplay makes (null: autoplay never answers).
       *
       * Only one decision is open at a time (R34). A second decide while one is open ends the duel as a local desync
       * rather than queueing it: the vanilla rules ask one choice per step and the next choice only from the handler
       * of the previous one (two LBIN then LPICK, a medic bringing back a medic), and both boards clear the open
       * decision before that handler runs. Cards that land in one step (the Skellige round 3 perk of both seats, which
       * can bring back two birna_bran medics, muster, scorch) cannot open two at once either: their effects are deferred
       * (deferEffect) and run one at a time, the next one only once the open decision has been applied and the board
       * has settled. A future rule with two choices in one effect would end the match as a desync, never hang it.
       */
      public function decide(kind:String, seat:int, askerNetId:int, showLocal:Function, apply:Function, autoChoice:Function = null) : void
      {
         if(this._ended)
         {
            return;
         }
         var asker:String = askerNetId >= 0 ? DuelIds.format(askerNetId) : (kind == COIN ? ASKER_COIN : ASKER_PERK);
         if(this._localDecision != null || this._remoteDecision != null)
         {
            this.localDesync("decision " + kind + " while another is open");
            return;
         }
         var decision:DuelDecision = new DuelDecision(kind,asker,scopeOf(kind),showLocal,apply,autoChoice);
         if(seat == this.localSeat)
         {
            this.log("DUEL DECIDE " + kind + " asker=" + asker + " by=local");
            this._localDecision = decision;
         }
         else if(seat == DuelIds.SEAT_B - this.localSeat)
         {
            this.log("DUEL DECIDE " + kind + " asker=" + asker + " by=opponent");
            this._remoteDecision = decision;
         }
         else
         {
            this.localDesync("decision " + kind + " without a seat");
         }
      }

      /**
       * The local player's answer to the open local decision (called by the choice UI): sends D, then applies it.
       * Ignored unless a decision of this kind is open and already shown (a second click, a stale dialog).
       * @param kind The decision kind the UI was shown for.
       * @param choice The choice as it goes on the wire (net id, t<templateId>, 1/0).
       */
      public function answer(kind:String, choice:String) : void
      {
         var decision:DuelDecision = this._localDecision;
         if(this._ended || decision == null || decision.kind != kind || !decision.shown || choice == null)
         {
            return;
         }
         this._localDecision = null;
         this.send(DECISION,[kind,decision.asker,choice],decision.scope);
         var apply:Function = decision.applyFn;
         if(!apply(choice))
         {
            this.localDesync("choice " + kind + " " + choice);
         }
      }

      /**
       * True while a decision is open (local or the opponent's): the controllers and the game flow hold until it is
       * applied.
       */
      public function get decisionOpen() : Boolean
      {
         return this._localDecision != null || this._remoteDecision != null;
      }

      /**
       * Queues a card's rule effect (spec 7.4) instead of running it when its tween or FX happens to end: the landing
       * effects of a card that finished moving into a list, the graveyard move at the end of a scorch FX and the
       * effects of a morphed card at the end of its morph FX (CardInstance). update() runs the
       * queued effects one at a time in canonical order (seat of the card's owner, seat A first, then net id), each
       * once no card moves, no card FX plays and no decision is open, so every effect and everything it starts (FX,
       * scorch, summons, a medic's choice) has settled before the next one runs. Both boards therefore apply the same
       * effects in the same order whatever the animation timing; while any is queued the board holds (effectsPending),
       * so the hash of the next message includes them. Several effects of one card run in the order queued. After the
       * end of the game the effect runs at once, as in vanilla (nothing is hashed or sent any more).
       * @param card The card the effect belongs to.
       * @param run function():void, applies the effect.
       */
      public function deferEffect(card:CardInstance, run:Function) : void
      {
         if(run == null)
         {
            return;
         }
         if(this._ended)
         {
            run();
            return;
         }
         var seat:int = card != null ? this.seatOf(card.owningPlayer) : -1;
         var netId:int = card != null ? this._ids.toNet(card.instanceId) : -1;
         this._deferred.add(seat >= 0 ? seat : DuelDeferred.NO_SEAT,netId >= 0 ? netId : DuelDeferred.NO_NET_ID,card,run);
      }

      /**
       * True while a deferred rule effect waits: the controllers and the game flow hold until it ran.
       */
      public function get effectsPending() : Boolean
      {
         return this._deferred.pending;
      }

      /**
       * Runs the queued effects in canonical order, one per settled point: stops as soon as one starts a card move or
       * FX, opens a decision, or ends the game. Logs DUEL EFFECT <netId> t<templateId> queued=<n> for each effect that
       * ran while others were queued (both boards log the same lines).
       */
      private function runDeferred() : void
      {
         while(!this._ended && this._deferred.pending && !this.decisionOpen && this.settled())
         {
            var queued:int = this._deferred.count;
            var effect:DuelEffect = this._deferred.takeNext();
            if(queued > 1)
            {
               var card:CardInstance = effect.token as CardInstance;
               this.log("DUEL EFFECT " + (effect.netId != DuelDeferred.NO_NET_ID ? DuelIds.format(effect.netId) : "none") + " t" + (card != null ? card.templateId : -1) + " queued=" + queued);
            }
            effect.run();
         }
      }

      /**
       * The local card instance of a net id argument ("A17").
       * @param arg A net id as written on the wire.
       * @return The card, or null if the argument is malformed or the net id unknown here.
       */
      public function cardOfArg(arg:String) : CardInstance
      {
         var netId:int = arg != null ? DuelIds.parse(arg) : -1;
         var instanceId:int = netId >= 0 ? this._ids.toLocal(netId) : -1;
         return instanceId >= 0 ? CardManager.getInstance().getCardInstance(instanceId) : null;
      }

      /**
       * The net id of a local instance as written on the wire ("A17").
       * @param instanceId A local card instance id.
       * @return The net id text, or "none" when the instance has no net id (no option matches it).
       */
      public function netName(instanceId:int) : String
      {
         var netId:int = this._ids.toNet(instanceId);
         return netId >= 0 ? DuelIds.format(netId) : "none";
      }

      /** The hash scope of a decision kind (spec 8.4): the seat's own state for the mulligan and the coin. */
      private function scopeOf(kind:String) : int
      {
         return kind == COIN || kind == MULLIGAN ? DuelStateHash.SCOPE_SEAT : DuelStateHash.SCOPE_FULL;
      }

      /** No card moves and no card FX plays: both boards hash a decision point in this state. */
      private function settled() : Boolean
      {
         return !CardTweenManager.getInstance().isAnyCardMoving() && !CardFXManager.getInstance().isPlayingAnyCardFX();
      }

      /**
       * Sends one message to the opponent (script event OnMultiplayerMessage) and logs DUEL SEND.
       * @param type One of DuelCodec.TYPES.
       * @param args Arguments, each of [A-Za-z0-9]+ (null or empty for none).
       * @param scope DuelStateHash.SCOPE_FULL or SCOPE_SEAT (the local seat's own state).
       */
      public function send(type:String, args:Array, scope:int) : void
      {
         if(this._ended)
         {
            return;
         }
         this._outSeq++;
         var corruptAt:int = GwintGameMenu.mSingleton.duelDebugCorruptAt;
         if(corruptAt == this._outSeq || corruptAt == CORRUPT_END && type == END)
         {
            this.corrupt(this._outSeq);
         }
         var message:DuelMessage = new DuelMessage(DuelCodec.PROTOCOL_VERSION,this._matchId,this._outSeq,type,args,DuelStateHash.compute(scope,this.localSeat));
         var token:String = DuelCodec.encode(message);
         this._sentHashes[this._outSeq] = message.hash;
         this.remember("sent " + token);
         this.log("DUEL SEND " + token);
         GwintGameMenu.mSingleton.duelSendMessage(token);
      }

      /**
       * Sends a local move (spec 5: the three commit points of HumanPlayerController and autoplay) before it applies,
       * with the same branch order as BasePlayerController.state_begin_ApplyingCard: leader (L), play to a slot (P),
       * play onto a card (C), global effect (G).
       * @param transaction The decided move of PLAYER_1.
       * @return False if the duel or this game has ended (nothing may be played any more) or the move has no message
       * (a desync).
       */
      public function sendMove(transaction:CardTransaction) : Boolean
      {
         var source:CardInstance = transaction != null ? transaction.sourceCardInstanceRef : null;
         if(this._ended || this._end.over)
         {
            return false;
         }
         if(source == null)
         {
            this.localDesync("no move");
            return false;
         }
         if(source is CardLeaderInstance)
         {
            this.send("L",[],DuelStateHash.SCOPE_FULL);
            return true;
         }
         var netId:String = DuelIds.format(this._ids.toNet(source.instanceId));
         if(transaction.targetSlotID != CardManager.CARD_LIST_LOC_INVALID)
         {
            var seat:int = this.seatOf(transaction.targetPlayerID);
            this.send("P",[netId,String(transaction.targetSlotID),seat < 0 ? NO_SEAT : seatName(seat)],DuelStateHash.SCOPE_FULL);
            return true;
         }
         if(transaction.targetCardInstanceRef != null)
         {
            this.send("C",[netId,DuelIds.format(this._ids.toNet(transaction.targetCardInstanceRef.instanceId))],DuelStateHash.SCOPE_FULL);
            return true;
         }
         if(source.templateRef.isType(CardTemplate.CardType_Global_Effect))
         {
            this.send("G",[netId],DuelStateHash.SCOPE_FULL);
            return true;
         }
         this.localDesync("move without a message");
         return false;
      }

      /**
       * The local player index of a P target seat argument.
       * @param arg A, B or N.
       * @return PLAYER_1, PLAYER_2, PLAYER_INVALID for N, or -2 for anything else.
       */
      public function targetPlayerOf(arg:String) : int
      {
         if(arg == NO_SEAT)
         {
            return CardManager.PLAYER_INVALID;
         }
         if(arg == "A" || arg == "B")
         {
            return this.playerOf(arg == "A" ? DuelIds.SEAT_A : DuelIds.SEAT_B);
         }
         return -2;
      }

      /**
       * The opponent's latest window (gwint.game.remoteInput): queues its new messages of this game.
       * @param window Tokens joined by "~", or "none".
       */
      public function onRemoteInput(window:String) : void
      {
         if(window == null)
         {
            return;
         }
         if(this._ended)
         {
            if(this._quitLocally)
            {
               this.logLateQuit(window);
            }
            return;
         }
         this._lastWindow = window;
         if(!this._helloDone && this.hasHelloOfOtherVersion(window))
         {
            this.abort("version");
            return;
         }
         this._window.ingest(window);
      }

      /**
       * One step of the duel, every 20 ms: Hello, the Hello wait limit, the end of game waits, lost messages, the next
       * inbound message, autoplay.
       */
      public function update() : void
      {
         if(this._ended)
         {
            return;
         }
         if(!this._helloSent && this.boardReady())
         {
            this._helloSent = true;
            this.send("H",[DuelCodec.hex8(this.templateHash()),DuelCodec.hex8(this.deckHash(DuelIds.SEAT_A)),DuelCodec.hex8(this.deckHash(DuelIds.SEAT_B))],DuelStateHash.SCOPE_FULL);
         }
         if(!this._helloDone && getTimer() - this._startMs > HELLO_TIMEOUT_MS)
         {
            this.abort("hello_timeout");
            return;
         }
         if(!this._helloSent)
         {
            return;
         }
         if(this._end.confirmExpired(getTimer(),STUCK_WAIT_MS))
         {
            this.abort("end_timeout");
            return;
         }
         if(this._end.replayExpired(getTimer(),STUCK_WAIT_MS))
         {
            this.send(LEAVE,[],DuelStateHash.SCOPE_FULL);
            this.finishDraw("replay_timeout");
            return;
         }
         if(this._window.gap)
         {
            this.desync(this._window.nextSeq,DuelStateHash.compute(DuelStateHash.SCOPE_FULL,0),0,"gap");
            return;
         }
         this.runDeferred();
         var next:DuelMessage = this._window.peek();
         if(next != null)
         {
            this.dispatch(next);
         }
         if(!this._ended && this._localDecision != null && !this._localDecision.shown && this.settled())
         {
            this._localDecision.shown = true;
            var show:Function = this._localDecision.showFn;
            show();
         }
         if(!this._ended && GwintGameMenu.mSingleton.duelDebugAutoplay)
         {
            this.autoplay();
         }
      }

      /**
       * Logs DUEL APPLY for a message about to be applied, with this client's own hash at that point.
       * @param message The message.
       * @param scope The hash scope of that message type.
       * @return This client's hash (Task 11 compares it with message.hash).
       */
      public function logApply(message:DuelMessage, scope:int) : uint
      {
         return this.logApplyHash(message,DuelStateHash.compute(scope,this.seatOf(CardManager.PLAYER_2)));
      }

      /** Logs DUEL APPLY for a message with the hash this client compares it with (mine). */
      private function logApplyHash(message:DuelMessage, mine:uint) : uint
      {
         var token:String = DuelCodec.encode(message);
         this.remember("applied " + token);
         this.log("DUEL APPLY " + token + " mine=" + DuelCodec.hex8(mine));
         this._lastAppliedHash = mine;
         return mine;
      }

      /**
       * This client's hash at the last DUEL APPLY (the "mine" of a desync found while the message is applied).
       */
      public function get lastAppliedHash() : uint
      {
         return this._lastAppliedHash;
      }

      /**
       * The hash check before a message is applied (spec 8.4): logs DUEL APPLY and compares this client's hash with the
       * hash in the message. QUITGAME never comes here (dispatch hands it to applySurrender first: it carries the
       * sender's hash at the menu action, not at a logical point). A mismatch is a desync: Y is sent and the duel ends
       * as no contest.
       * @param message The opponent's message about to be applied.
       * @param scope The hash scope of that message type.
       * @return True if the message may be applied, false if the duel just ended.
       */
      public function checkApply(message:DuelMessage, scope:int) : Boolean
      {
         var mine:uint = this.logApply(message,scope);
         if(message.hash == mine)
         {
            return true;
         }
         this.desync(message.seq,mine,message.hash,"hash");
         return false;
      }

      /**
       * This client found that the boards differ (spec 10): sends Y with its hash and the failing seq, then ends as no
       * contest (endDesync).
       * @param seq The seq of the opponent's message that failed.
       * @param mine This client's hash at that point.
       * @param theirs The hash in the opponent's message.
       * @param detail What differed, one word or a net id (logged as DUEL MISMATCH).
       */
      public function desync(seq:int, mine:uint, theirs:uint, detail:String) : void
      {
         if(this._ended)
         {
            return;
         }
         this.log("DUEL MISMATCH seq=" + seq + " " + detail);
         this.send(DESYNC,[DuelCodec.hex8(mine),String(seq)],DuelStateHash.SCOPE_FULL);
         this.endDesync(seq,mine,theirs);
      }

      /**
       * A desync this client found in its own move (no opponent message failed): Y with seq 0 and this client's hash.
       */
      private function localDesync(detail:String) : void
      {
         var mine:uint = DuelStateHash.compute(DuelStateHash.SCOPE_FULL,0);
         this.desync(0,mine,0,detail);
      }

      /**
       * Logs DUEL ROUND when a round starts (after the perks, before the first turn).
       * @param roundNumber The round, from 1.
       */
      public function logRound(roundNumber:int) : void
      {
         var manager:CardManager = CardManager.getInstance();
         var scoreA:int = manager.currentPlayerScores[this.playerOf(DuelIds.SEAT_A)];
         var scoreB:int = manager.currentPlayerScores[this.playerOf(DuelIds.SEAT_B)];
         this.log("DUEL ROUND " + roundNumber + " scores=" + scoreA + "," + scoreB + " hash=" + DuelCodec.hex8(DuelStateHash.compute(DuelStateHash.SCOPE_FULL,0)));
      }

      /**
       * The player closed the end screen of a confirmed win or loss: logs DUEL END and hands the result to the script,
       * which settles the bet (the menu then closes). Ignored before the opponent's E confirmed the result (R43); a
       * draw goes to localLeave.
       * @param winner The local player index that won, PLAYER_INVALID for a draw.
       */
      public function finishGame(winner:int) : void
      {
         if(this._ended || this._end.phase != DuelEnd.CONFIRMED)
         {
            return;
         }
         if(winner == CardManager.PLAYER_INVALID)
         {
            this.localLeave();
            return;
         }
         this._ended = true;
         this._deferred.clear();
         var result:String = winner == CardManager.PLAYER_1 ? "win" : "loss";
         this.log("DUEL END result=" + result + " reason=match game=" + this._gameNumber);
         GwintGameMenu.mSingleton.duelFinish(result);
      }

      /**
       * The final winner of this game as the end screen shows it: gwint.game.debug.forceDraw (test) makes game 0 a
       * draw (logged as DUEL FORCEDRAW); otherwise the vanilla result.
       * @param winner The local player index the vanilla rules made the winner, PLAYER_INVALID for a draw.
       * @return The winner to show and to send in E.
       */
      public function finalWinner(winner:int) : int
      {
         if(this._gameNumber != 0 || !GwintGameMenu.mSingleton.duelDebugForceDraw)
         {
            return winner;
         }
         this.log("DUEL FORCEDRAW game=0 winner=" + (winner == CardManager.PLAYER_INVALID ? DuelEnd.DRAW : seatName(this.seatOf(winner))));
         return CardManager.PLAYER_INVALID;
      }

      /**
       * The game is over on this board (GwintGameFlowController.state_begin_ShowingFinalResult, once the board has
       * settled): sends E with the winner and the hash of the final state, then waits for the opponent's E (R43). The
       * end screen opens (showResult) only when it agrees.
       * @param winner The local player index that won, PLAYER_INVALID for a draw (after finalWinner).
       * @param showResult function():void, opens the end screen.
       */
      public function gameOver(winner:int, showResult:Function) : void
      {
         if(this._ended || this._end.over)
         {
            return;
         }
         var seat:String = winner == CardManager.PLAYER_INVALID ? DuelEnd.DRAW : seatName(this.seatOf(winner));
         this._showResult = showResult;
         this.send(END,[seat],DuelStateHash.SCOPE_FULL);
         this._end.reached(seat,this._outSeq,uint(this._sentHashes[this._outSeq]),getTimer());
      }

      /**
       * The local player pressed Replay on the end screen of a confirmed draw: sends R. Once the opponent's R is in
       * too, the next game starts.
       * @return True when this board now waits for the opponent's R (the caller shows "Waiting for your opponent").
       */
      public function localReplay() : Boolean
      {
         if(this._ended || this._end.phase != DuelEnd.CONFIRMED || !this._end.isDraw || this._end.replaySent)
         {
            return false;
         }
         this.send(REPLAY,[],DuelStateHash.SCOPE_FULL);
         this._end.replaySent = true;
         this._end.replayAtMs = getTimer();
         if(this._end.replayReceived)
         {
            this.startNextGame();
            return false;
         }
         return true;
      }

      /**
       * The local player closed the end screen of a confirmed draw: sends X and ends the match as a draw that moves no
       * money.
       */
      public function localLeave() : void
      {
         if(this._ended || this._end.phase != DuelEnd.CONFIRMED || !this._end.isDraw)
         {
            return;
         }
         this.send(LEAVE,[],DuelStateHash.SCOPE_FULL);
         this.finishDraw("leave");
      }

      /**
       * Ends the match as a draw without a replay: logs DUEL END result=draw and tells the script (OnMultiplayerDraw:
       * no money moves on either side); the menu then closes.
       * @param reason leave (the local player closed the end screen), opponent_leave (X arrived) or replay_timeout.
       */
      private function finishDraw(reason:String) : void
      {
         if(this._ended)
         {
            return;
         }
         this._ended = true;
         this._deferred.clear();
         this.log("DUEL END result=draw reason=" + reason + " game=" + this._gameNumber);
         GwintGameMenu.mSingleton.duelFinish("draw");
      }

      /**
       * Both seats sent R: logs DUEL END result=draw reason=replay for this game and starts the next one (spec 9.8):
       * game number n+1, its random streams, fresh net ids, its match id and a DuelWindow that goes on from the seq
       * after the opponent's R (the outbound seq keeps counting), the opponent's last window ingested again (its first
       * messages of the new game may already be in it), then GwintGameFlowController runs the vanilla Reset path.
       */
      private function startNextGame() : void
      {
         this.log("DUEL END result=draw reason=replay game=" + this._gameNumber);
         var firstSeq:int = this._window.nextSeq;
         this._gameNumber++;
         this._random = new DuelRandom(this._seed,this._gameNumber);
         this._ids.reset();
         this._matchId = DuelMessage.matchIdFor(this._seed,this._gameNumber);
         this._window = new DuelWindow(this._matchId,firstSeq);
         this._mulligans = [0,0];
         this._mulligan = new DuelMulligan();
         this._deferred.clear();
         this._localDecision = null;
         this._remoteDecision = null;
         this._end = new DuelEnd();
         this._showResult = null;
         this._autoSeenWhat = "";
         this.log("DUEL GAME " + this._gameNumber + " match=" + this._matchId + " first=" + firstSeq);
         if(this._lastWindow != null)
         {
            this._window.ingest(this._lastWindow);
         }
         GwintGameFlowController.getInstance().duelStartNextGame();
      }

      /**
       * Ends the duel as no contest: logs DUEL END, calls the script's OnMultiplayerAbort (no money moves), shows the
       * reason and closes the menu a moment later.
       * @param reason One word: version, templates, decks, hello_timeout, gap, unsupported, desync, ...
       * @param text What the player sees instead of the default "The Gwent duel was cancelled (<reason>)." (null).
       */
      public function abort(reason:String, text:String = null) : void
      {
         if(this._ended)
         {
            return;
         }
         this._ended = true;
         this._deferred.clear();
         this.log("DUEL END result=nocontest reason=" + reason + " game=" + this._gameNumber);
         GwintGameMenu.mSingleton.duelAbort(reason,text);
      }

      /**
       * The local player confirmed a surrender (GwintGameMenu.onQuitConfirmed; the script then closes the menu as a
       * forfeit). Sends QUITGAME with "1" when this side settles: its Hello is complete, so it pays the loss as today
       * and the opponent settles a win. Before that it sends "0" and the game ends as no contest on both sides
       * (OnMultiplayerAbort, nobody pays). Nothing is sent once the game ended (an aborted board pays nothing).
       */
      public function surrender() : void
      {
         if(this._ended)
         {
            return;
         }
         var settles:Boolean = this._helloDone;
         this.send(DuelCodec.SURRENDER,[settles ? "1" : "0"],DuelStateHash.SCOPE_FULL);
         this._ended = true;
         this._quitLocally = true;
         this._deferred.clear();
         this.logLateQuit(this._lastWindow);
         if(settles)
         {
            this.log("DUEL END result=loss reason=surrender game=" + this._gameNumber);
            return;
         }
         this.log("DUEL END result=nocontest reason=quit game=" + this._gameNumber);
         GwintGameMenu.mSingleton.duelNotifyAbort("quit");
      }

      /**
       * Hands one line to the script's duel log (OnDuelLog, then r_MultiplayerClient.duelLog).
       * @param line The line.
       */
      public function log(line:String) : void
      {
         GwintGameMenu.mSingleton.duelLog(line);
      }

      private function dispatch(next:DuelMessage) : void
      {
         if(next.type == DuelCodec.SURRENDER)
         {
            this._window.pop();
            this.applySurrender(next);
            return;
         }
         if(next.type == DESYNC)
         {
            this._window.pop();
            this.applyDesync(next);
            return;
         }
         if(!this._helloDone)
         {
            this._window.pop();
            if(next.type == "H")
            {
               this.applyHello(next);
            }
            else
            {
               this.desync(next.seq,this.logApply(next,DuelStateHash.SCOPE_FULL),next.hash,"before hello " + next.type);
            }
            return;
         }
         if(next.type == END || next.type == REPLAY || next.type == LEAVE || this._end.over)
         {
            this.dispatchEnd(next);
            return;
         }
         if(this._remoteDecision == null && (next.type == MULLIGAN_DONE || next.type == DECISION && next.args.length > 0 && next.args[0] == MULLIGAN))
         {
            this.dispatchMulligan(next);
            return;
         }
         if(next.type == DECISION || this._remoteDecision != null)
         {
            this.dispatchDecision(next);
            return;
         }
         if(MOVE_TYPES.indexOf(next.type) >= 0)
         {
            var opponent:NetOpponentController = GwintGameFlowController.getInstance().playerControllers[CardManager.PLAYER_2] as NetOpponentController;
            if(opponent != null && !opponent.hasQueuedMove)
            {
               opponent.queueMove(this._window.pop());
            }
            return;
         }
         this._window.pop();
         this.desync(next.seq,this.logApply(next,DuelStateHash.SCOPE_FULL),next.hash,"unsupported " + next.type);
      }

      /**
       * The opponent's mulligan (D MUL or M, spec 9.4): waits until this board has drawn its hands, then checks the
       * opponent seat's hash (SCOPE_SEAT) and applies the redraw to PLAYER_2, or marks its mulligan done. A redraw of a
       * card that is not in its hand, a third redraw, or anything after its M or after round 1 started is a desync.
       */
      private function dispatchMulligan(next:DuelMessage) : void
      {
         var route:String = this._mulligan.route(next);
         if(route == DuelMulligan.WAIT)
         {
            return;
         }
         this._window.pop();
         if(route != DuelMulligan.REDRAW && route != DuelMulligan.DONE)
         {
            this.desync(next.seq,this.logApply(next,DuelStateHash.SCOPE_SEAT),next.hash,route);
            return;
         }
         if(!this.checkApply(next,DuelStateHash.SCOPE_SEAT))
         {
            return;
         }
         if(route == DuelMulligan.DONE)
         {
            this._mulligan.remoteDone = true;
            return;
         }
         if(!GwintGameFlowController.getInstance().duelApplyRemoteRedraw(this.cardOfArg(next.args[2])))
         {
            this.desync(next.seq,this._lastAppliedHash,next.hash,"mulligan card " + next.args[2]);
            return;
         }
         this._mulligan.remoteRedraws++;
      }

      /**
       * The opponent's answer to the decision this board waits for (spec 9.6): taken once the board has settled (so
       * the hash is that of the decision point), checked, then applied. A D while this board waits for its own
       * player's answer, a D of another kind or asker, and a choice that is not one of the options are desyncs; a D
       * before this board reached the decision point waits in the window.
       */
      private function dispatchDecision(next:DuelMessage) : void
      {
         var pending:DuelDecision = this._remoteDecision;
         var route:String = DuelDecision.route(next,pending,this._localDecision,this.settled());
         if(route == DuelDecision.WAIT || route == DuelDecision.NOT_MINE)
         {
            return;
         }
         this._window.pop();
         if(route != DuelDecision.APPLY)
         {
            this.desync(next.seq,this.logApply(next,pending != null ? pending.scope : DuelStateHash.SCOPE_FULL),next.hash,route);
            return;
         }
         if(!this.checkApply(next,pending.scope))
         {
            return;
         }
         this._remoteDecision = null;
         var apply:Function = pending.applyFn;
         if(!apply(next.args[2]))
         {
            this.desync(next.seq,this._lastAppliedHash,next.hash,"choice " + next.args.join(","));
         }
      }

      /**
       * The opponent's E, R or X, and any message after the end of this game (DuelEnd.route). Each is compared with
       * the hash of this board's own E (the final state): E confirms the result and opens the end screen, R counts the
       * opponent's replay (and starts the next game when this board sent R too), X ends the match as a draw. A mismatch,
       * an E with another winner, and anything out of place are desyncs; an E before this board's own end waits.
       */
      private function dispatchEnd(next:DuelMessage) : void
      {
         var route:String = this._end.route(next);
         if(route == DuelEnd.WAIT)
         {
            return;
         }
         this._window.pop();
         if(route != DuelEnd.CONFIRM && route != DuelEnd.REPLAY && route != DuelEnd.LEAVE)
         {
            this.desync(next.seq,this.logApply(next,DuelStateHash.SCOPE_FULL),next.hash,route);
            return;
         }
         var mine:uint = this.logApplyHash(next,this._end.endHash);
         if(next.hash != mine)
         {
            this.desync(next.seq,mine,next.hash,"end hash");
            return;
         }
         if(route == DuelEnd.LEAVE)
         {
            this.finishDraw("opponent_leave");
            return;
         }
         if(route == DuelEnd.REPLAY)
         {
            this._end.replayReceived = true;
            if(this._end.replaySent)
            {
               this.startNextGame();
            }
            return;
         }
         this._end.confirm();
         this.log("DUEL CONFIRMED winner=" + this._end.winner + " game=" + this._gameNumber);
         var show:Function = this._showResult;
         this._showResult = null;
         if(show != null)
         {
            show();
         }
      }

      /**
       * R41: the opponent's QUITGAME that this board had not applied when its own player surrendered is ignored (each
       * quitter settles its own loss); it is logged once (DUEL IGNORED).
       * @param window The opponent's window, or null.
       */
      private function logLateQuit(window:String) : void
      {
         if(window == null || this._lateQuitLogged)
         {
            return;
         }
         var tokens:Array = window.split(DuelWindow.SEPARATOR);
         for(var i:int = 0; i < tokens.length; i++)
         {
            var m:DuelMessage = DuelCodec.decode(tokens[i]);
            if(m != null && m.type == DuelCodec.SURRENDER && m.matchId == this._matchId)
            {
               this._lateQuitLogged = true;
               this.log("DUEL IGNORED " + tokens[i] + " (after the local surrender)");
               return;
            }
         }
      }

      /**
       * The opponent found a desync (Y: its hash, the seq of our message that failed): this side ends too, with the
       * hash it sent in that message as "mine".
       */
      private function applyDesync(y:DuelMessage) : void
      {
         this.logApply(y,DuelStateHash.SCOPE_FULL);
         var seq:int = y.args.length == 2 ? int(y.args[1]) : 0;
         var mine:uint = this._sentHashes[seq] != undefined ? uint(this._sentHashes[seq]) : DuelStateHash.compute(DuelStateHash.SCOPE_FULL,0);
         var theirs:uint = y.args.length == 2 ? parseHex(y.args[0]) : 0;
         this.endDesync(seq,mine,theirs);
      }

      /**
       * Logs DUEL DESYNC and the last messages, then ends as no contest (reason desync) with the desync text.
       */
      private function endDesync(seq:int, mine:uint, theirs:uint) : void
      {
         this.log("DUEL DESYNC seq=" + seq + " mine=" + DuelCodec.hex8(mine) + " theirs=" + DuelCodec.hex8(theirs));
         for(var i:int = 0; i < this._recent.length; i++)
         {
            this.log("DUEL RECENT " + (i + 1) + " " + this._recent[i]);
         }
         this.abort("desync",DESYNC_TEXT);
      }

      /** Keeps the last RECENT_LIMIT messages (sent and applied) for the desync log. */
      private function remember(entry:String) : void
      {
         this._recent.push(entry);
         if(this._recent.length > RECENT_LIMIT)
         {
            this._recent.shift();
         }
      }

      /**
       * gwint.game.debug.corruptAt (test): adds 1 to the power of one card of the local player (the hand card with the
       * lowest net id, else the first card on its rows, its graveyard or its leader slot: at the end of a game the rows
       * are empty), so this client's hash no longer matches the opponent's board. The card's template is changed, so
       * every card of that template on this client counts 1 more.
       */
      private function corrupt(seq:int) : void
      {
         var manager:CardManager = CardManager.getInstance();
         var target:CardInstance = null;
         var hand:Vector.<CardInstance> = manager.getCardInstanceList(CardManager.CARD_LIST_LOC_HAND,CardManager.PLAYER_1);
         var i:int;
         for(i = 0; i < hand.length; i++)
         {
            if(target == null || this._ids.toNet(hand[i].instanceId) < this._ids.toNet(target.instanceId))
            {
               target = hand[i];
            }
         }
         var rows:Array = [CardManager.CARD_LIST_LOC_SEIGE,CardManager.CARD_LIST_LOC_RANGED,CardManager.CARD_LIST_LOC_MELEE,CardManager.CARD_LIST_LOC_GRAVEYARD,CardManager.CARD_LIST_LOC_LEADER];
         for(i = 0; i < rows.length && target == null; i++)
         {
            var row:Vector.<CardInstance> = manager.getCardInstanceList(rows[i],CardManager.PLAYER_1);
            if(row != null && row.length > 0)
            {
               target = row[0];
            }
         }
         if(target == null)
         {
            this.log("DUEL CORRUPT seq=" + seq + " card=none");
            return;
         }
         var template:CardTemplate = manager.getCardTemplate(target.templateId);
         template.power += 1;
         this.log("DUEL CORRUPT seq=" + seq + " card=" + DuelIds.format(this._ids.toNet(target.instanceId)) + " template=" + target.templateId + " power=" + template.power);
      }

      private static function seatName(seat:int) : String
      {
         return seat == DuelIds.SEAT_A ? "A" : "B";
      }

      /**
       * The opponent surrendered (QUITGAME): with argument 1 (its Hello was complete, it settles a loss) this side wins
       * and settles the win; with 0 (it quit during the Hello wait) the game is no contest and nobody pays.
       */
      private function applySurrender(quit:DuelMessage) : void
      {
         this.logApply(quit,DuelStateHash.SCOPE_FULL);
         if(quit.args[0] == "1")
         {
            this._ended = true;
            this._deferred.clear();
            this.log("DUEL END result=win reason=surrender game=" + this._gameNumber);
            GwintGameMenu.mSingleton.duelFinish("win");
         }
         else
         {
            this.abort("quit");
         }
      }

      private function applyHello(hello:DuelMessage) : void
      {
         var mine:uint = this.logApply(hello,DuelStateHash.SCOPE_FULL);
         if(hello.args.length != 3)
         {
            this.desync(hello.seq,mine,hello.hash,"hello args");
            return;
         }
         if(parseHex(hello.args[0]) != this.templateHash())
         {
            this.abort("templates");
            return;
         }
         if(parseHex(hello.args[1]) != this.deckHash(DuelIds.SEAT_A) || parseHex(hello.args[2]) != this.deckHash(DuelIds.SEAT_B))
         {
            this.abort("decks");
            return;
         }
         if(hello.hash != mine)
         {
            this.desync(hello.seq,mine,hello.hash,"hello");
            return;
         }
         this._helloDone = true;
         this.log("DUEL HELLO ok seat=" + seatName(this.localSeat));
      }

      /**
       * Whether the window holds a token of another protocol version: its first field is a version number other than
       * ours, whatever the rest of the token looks like (a future envelope may differ).
       */
      private function hasHelloOfOtherVersion(window:String) : Boolean
      {
         var tokens:Array = window.split(DuelWindow.SEPARATOR);
         for(var i:int = 0; i < tokens.length; i++)
         {
            var version:String = String(tokens[i]).split(".")[0];
            if(isDigits(version) && version != String(DuelCodec.PROTOCOL_VERSION))
            {
               return true;
            }
         }
         return false;
      }

      private static function isDigits(text:String) : Boolean
      {
         if(text == null || text.length == 0)
         {
            return false;
         }
         for(var i:int = 0; i < text.length; i++)
         {
            var code:Number = text.charCodeAt(i);
            if(code < 48 || code > 57)
            {
               return false;
            }
         }
         return true;
      }

      private function boardReady() : Boolean
      {
         var manager:CardManager = CardManager.getInstance();
         return manager != null && manager.cardTemplatesReceived && manager.playerDeckDefinitions[CardManager.PLAYER_1].cardIndices != null && manager.playerDeckDefinitions[CardManager.PLAYER_2].cardIndices != null;
      }

      /**
       * Hash of the gameplay fields of the card table (index, power, faction, types, effect flags, summon flags; no
       * localized text, no art), in index order. gwint.game.debug.breakTemplates adds 1 (a test of the mismatch path).
       */
      private function templateHash() : uint
      {
         var manager:CardManager = CardManager.getInstance();
         var indices:Array = [];
         for(var key:* in manager._cardTemplates)
         {
            indices.push(int(key));
         }
         indices.sort(Array.NUMERIC);
         var h:DuelHash = new DuelHash();
         h.addInt(indices.length);
         for(var i:int = 0; i < indices.length; i++)
         {
            var template:CardTemplate = manager.getCardTemplate(indices[i]);
            h.addInt(template.index);
            h.addInt(template.power);
            h.addInt(template.factionIdx);
            h.addInt(int(template.typeArray));
            addIntArray(h,template.effectFlags);
            addIntArray(h,template.summonFlags);
         }
         var value:uint = h.value();
         return GwintGameMenu.mSingleton.duelDebugBreakTemplates ? uint(value + 1) : value;
      }

      /**
       * Hash of one seat's deck as this client received it: leader, special card, card list in order.
       */
      private function deckHash(seat:int) : uint
      {
         var deck:GwintDeck = CardManager.getInstance().playerDeckDefinitions[this.playerOf(seat)];
         var h:DuelHash = new DuelHash();
         h.addInt(deck.selectedKingIndex);
         h.addInt(deck.specialCard);
         addIntArray(h,deck.cardIndices);
         return h.value();
      }

      private function autoplay() : void
      {
         var flow:GwintGameFlowController = GwintGameFlowController.getInstance();
         var menu:GwintGameMenu = GwintGameMenu.mSingleton;
         var what:String = "";
         if(this._localDecision != null)
         {
            what = this._localDecision.shown && this._localDecision.autoFn != null ? "decide" : "";
         }
         else if(flow.stateMachine.currentState == "Mulligan" && !flow.duelMulliganDecided && menu.mcChoiceDialog.isShown())
         {
            what = "mulligan";
         }
         else if(this._end.phase == DuelEnd.CONFIRMED && !this._end.replaySent && menu.mcEndGameDialog != null && menu.mcEndGameDialog.visible)
         {
            what = "end";
         }
         else if(menu.mcChoiceDialog.isShown() && flow.stateMachine.currentState != "Mulligan")
         {
            what = "dialog";
         }
         if(what != this._autoSeenWhat)
         {
            this._autoSeenWhat = what;
            this._autoSeenMs = getTimer();
            return;
         }
         if(what == "" || getTimer() - this._autoSeenMs < AUTOPLAY_DELAY_MS)
         {
            return;
         }
         this._autoSeenMs = getTimer();
         if(what == "decide")
         {
            var auto:Function = this._localDecision.autoFn;
            var kind:String = this._localDecision.kind;
            var choice:String = auto();
            this.log("DUEL AUTOPLAY decide " + kind + " " + choice);
            this.answer(kind,choice);
         }
         else if(what == "mulligan")
         {
            this.log("DUEL AUTOPLAY mulligan " + (flow.duelAutoMulligan(menu.duelDebugMulligan) ? "redraw" : "decline"));
         }
         else if(what == "dialog")
         {
            this.log("DUEL AUTOPLAY close dialog");
            menu.mcChoiceDialog.hideDialog();
         }
         else if(this._end.isDraw && menu.duelDebugReplay)
         {
            // as the end screen's Replay button does: the result callback, then the dialog hides
            this.log("DUEL AUTOPLAY replay");
            flow.EndGame(GwintEndGameDialog.EndGameDialogResult_Restart);
            menu.mcEndGameDialog.hide();
         }
         else
         {
            this.log("DUEL AUTOPLAY close end screen");
            menu.mcEndGameDialog.closeButtonPressedOrTapped(null);
         }
      }

      private static function addIntArray(h:DuelHash, values:Array) : void
      {
         if(values == null)
         {
            h.addInt(-1);
            return;
         }
         h.addInt(values.length);
         for(var i:int = 0; i < values.length; i++)
         {
            h.addInt(int(values[i]));
         }
      }

      private static function parseHex(text:String) : uint
      {
         return uint(parseInt(text,16));
      }
   }
}
