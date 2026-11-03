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
    */
   public class DuelSession
   {

      /**
       * TEMPORARY (Tasks 9 and 10, removed in Task 11): in a duel both seats pass at the start of every turn, so whole
       * matches run before moves are synced. HumanPlayerController passes (and sends S) and NetOpponentController
       * applies the opponent's S. Task 11 deletes this constant and its uses.
       */
      public static const ALWAYS_PASS:Boolean = true;

      /** How long the board waits for the opponent's Hello before the duel ends as no contest (hello_timeout). */
      public static const HELLO_TIMEOUT_MS:int = 120000;

      /** Autoplay: how long the mulligan dialog or the end screen stays up before the bot answers it. */
      public static const AUTOPLAY_DELAY_MS:int = 1500;

      private static const MOVE_TYPES:Array = ["P","C","G","L","S"];

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
         var message:DuelMessage = new DuelMessage(DuelCodec.PROTOCOL_VERSION,this._matchId,this._outSeq,type,args,DuelStateHash.compute(scope,this.localSeat));
         var token:String = DuelCodec.encode(message);
         this.log("DUEL SEND " + token);
         GwintGameMenu.mSingleton.duelSendMessage(token);
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
         this.log("DUEL APPLY " + DuelCodec.encode(message) + " mine=" + DuelCodec.hex8(mine));
         return mine;
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
       * @param reason One word: version, templates, decks, hello_timeout, gap, unsupported, ...
       */
      public function abort(reason:String) : void
      {
         if(this._ended)
         {
            return;
         }
         this._ended = true;
         this.log("DUEL END result=nocontest reason=" + reason + " game=" + this._gameNumber);
         GwintGameMenu.mSingleton.duelAbort(reason);
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
         this._helloDone = true;
         this.log("DUEL HELLO ok seat=" + (this.localSeat == DuelIds.SEAT_A ? "A" : "B"));
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
