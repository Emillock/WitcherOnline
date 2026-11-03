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
    * next message, before or after Hello.
    *
    * Moves (spec 5, 9.5): HumanPlayerController sends P, C, G or L (sendMove) at its commit points and S when it passes,
    * before the move applies; NetOpponentController applies the opponent's moves. Move arguments:
    *   P  netId, slot (a CardManager.CARD_LIST_LOC_* number), target seat (A, B, or N for no side: the weather slot)
    *   C  netId, target netId          G  netId          L  none (the sender's leader)          S  none
    * Hash check (spec 8.4): before a message is applied its hash is compared with this client's own hash
    * (checkApply), except QUITGAME (it carries the sender's hash at the menu action, not at a logical point) and Y.
    * Desync (spec 10): a mismatch or a move naming an unknown card sends Y (args: this client's hash, the seq that
    * failed), logs DUEL DESYNC seq=<n> mine=<h> theirs=<h> and the last 20 messages (DUEL RECENT), shows "The match
    * went out of sync and was cancelled" and ends as no contest (reason desync); the receiver of Y does the same,
    * without sending anything. gwint.game.debug.corruptAt=<seq> (test) adds 1 to one card's power right before this
    * client sends that seq, so the opponent's check fails.
    */
   public class DuelSession
   {

      /** How long the board waits for the opponent's Hello before the duel ends as no contest (hello_timeout). */
      public static const HELLO_TIMEOUT_MS:int = 120000;

      /** Autoplay: how long the mulligan dialog or the end screen stays up before the bot answers it. */
      public static const AUTOPLAY_DELAY_MS:int = 1500;

      /** What the player sees when the duel went out of sync (spec 10). */
      public static const DESYNC_TEXT:String = "The match went out of sync and was cancelled";

      /** The desync message type: args = the detector's hash (hex8), the seq that failed. */
      public static const DESYNC:String = "Y";

      /** Target seat argument of P for a slot that belongs to no side (the weather slot). */
      public static const NO_SEAT:String = "N";

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
       * A seat's mulligan redraws so far (part of the SCOPE_SEAT hash; counted from Task 12, 0 until then).
       * @param seat DuelIds.SEAT_A or SEAT_B.
       * @return The count.
       */
      public function mulligans(seat:int) : int
      {
         return seat == DuelIds.SEAT_A || seat == DuelIds.SEAT_B ? int(this._mulligans[seat]) : 0;
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
         if(GwintGameMenu.mSingleton.duelDebugCorruptAt == this._outSeq)
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
       * @return False if the move has no message (the duel then ends as no contest, reason unsupported).
       */
      public function sendMove(transaction:CardTransaction) : Boolean
      {
         var source:CardInstance = transaction != null ? transaction.sourceCardInstanceRef : null;
         if(source == null)
         {
            this.abort("unsupported");
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
         this.abort("unsupported");
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
         if(window == null || this._ended)
         {
            return;
         }
         if(!this._helloDone && this.hasHelloOfOtherVersion(window))
         {
            this.abort("version");
            return;
         }
         this._window.ingest(window);
      }

      /**
       * One step of the duel, every 20 ms: Hello, the Hello wait limit, lost messages, the next inbound message,
       * autoplay.
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
         if(this._window.gap)
         {
            this.abort("gap");
            return;
         }
         var next:DuelMessage = this._window.peek();
         if(next != null)
         {
            this.dispatch(next);
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
         var mine:uint = DuelStateHash.compute(scope,this.seatOf(CardManager.PLAYER_2));
         var token:String = DuelCodec.encode(message);
         this.remember("applied " + token);
         this.log("DUEL APPLY " + token + " mine=" + DuelCodec.hex8(mine));
         return mine;
      }

      /**
       * The hash check before a message is applied (spec 8.4): logs DUEL APPLY and compares this client's hash with the
       * hash in the message. QUITGAME is never compared (it carries the sender's hash at the menu action, not at a
       * logical point). A mismatch is a desync: Y is sent and the duel ends as no contest.
       * @param message The opponent's message about to be applied.
       * @param scope The hash scope of that message type.
       * @return True if the message may be applied, false if the duel just ended.
       */
      public function checkApply(message:DuelMessage, scope:int) : Boolean
      {
         var mine:uint = this.logApply(message,scope);
         if(message.type == DuelCodec.SURRENDER || message.hash == mine)
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
       * The game ended with a result: logs DUEL END and hands the result to the script (the menu then closes).
       * @param winner The local player index that won, PLAYER_INVALID for a draw.
       */
      public function finishGame(winner:int) : void
      {
         if(this._ended)
         {
            return;
         }
         this._ended = true;
         var result:String = winner == CardManager.PLAYER_1 ? "win" : (winner == CardManager.PLAYER_2 ? "loss" : "draw");
         this.log("DUEL END result=" + result + " reason=match game=" + this._gameNumber);
         GwintGameMenu.mSingleton.duelFinish(result);
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
         this.log("DUEL END result=nocontest reason=" + reason + " game=" + this._gameNumber);
         GwintGameMenu.mSingleton.duelAbort(reason,text);
      }

      /**
       * The local player confirmed a surrender (GwintGameMenu.onQuitConfirmed; the script then closes the menu as a
       * forfeit). Sends QUITGAME with "1" when this side settles: its Hello is complete, so it pays the loss as today
       * and the opponent settles a win. Before that it sends "0" and the game ends as no contest on both sides
       * (OnMultiplayerAbort, nobody pays).
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
               this.logApply(next,DuelStateHash.SCOPE_FULL);
               this.abort("desync");
            }
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
         this.logApply(next,DuelStateHash.SCOPE_FULL);
         this.abort("unsupported");
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
       * lowest net id, else the first card on its rows), so this client's hash no longer matches the opponent's board.
       * The card's template is changed, so every card of that template on this client counts 1 more.
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
         var rows:Array = [CardManager.CARD_LIST_LOC_SEIGE,CardManager.CARD_LIST_LOC_RANGED,CardManager.CARD_LIST_LOC_MELEE];
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
         this.logApply(hello,DuelStateHash.SCOPE_FULL);
         if(hello.args.length != 3)
         {
            this.abort("desync");
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
         var mine:uint = DuelStateHash.compute(DuelStateHash.SCOPE_FULL,0);
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
         if(flow.stateMachine.currentState == "Mulligan" && !flow.duelMulliganDecided && menu.mcChoiceDialog.isShown())
         {
            what = "mulligan";
         }
         else if(menu.mcEndGameDialog != null && menu.mcEndGameDialog.visible)
         {
            what = "end";
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
         if(what == "mulligan")
         {
            this.log("DUEL AUTOPLAY mulligan " + (menu.duelDebugMulligan ? "redraw" : "decline"));
            flow.duelAutoMulligan(menu.duelDebugMulligan);
         }
         else
         {
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
