package red.game.witcher3.menus.gwint
{
   /**
    * The turn timer of Timed mode (spec 15, R53, R54, R56): board-independent, so DuelSelfTest can run it on synthetic
    * stretches and times; DuelSession gathers the board state, acts on an expiry and draws DuelTimerView.
    *
    * R53: one clock of DuelWait.TURN_MS (60 s) covers each stretch in which the board waits on local input and has not
    * yet sent the message that ends it. stretchOf() names the stretch: a local turn (TURN, from the turn's start
    * through the card pick, the move and any decision the move raises, until the turn is over; so a decision inside a
    * turn gets no time of its own), the mulligan (MULLIGAN, until this seat's M) and a local decision raised outside
    * the local turn (DECISION, until its D). Normal mode has no stretch at all. A stretch starts over when its kind or
    * its id changes (the next turn, the next decision, the mulligan of the next game). Once it ran out it stays expired
    * until it ends, so the board retries its timeout every update until it can act (a picked card's state switch, a
    * decision dialog that waits for the board to settle) and answers every further decision of an expired turn at
    * once (a player loses unspent time inside chained decisions).
    *
    * R56 (amends spec 9.10 for Timed mode): while the local player's card zoom holds an opponent message that has
    * arrived (HELD), the clock already runs. The next local stretch that starts before any further opponent message
    * is taken (the one the held message handed over: the turn, a decision, the mulligan) goes on from the start of the
    * hold instead of starting over, also across the moments in between without a stretch (the zoom closed, the message
    * applying). A further opponent message taken first drops the carried start. When the hold itself runs out, the
    * board closes the zoom, the held message applies, and the stretch it hands over is expired at once.
    *
    * R54: the opponent's turns run on a second DuelClock (TURN on the opponent's turn), display only: it never acts.
    */
   public class DuelClock
   {

      /** stretchOf(): the board waits on no local input (or Normal mode). */
      public static const NONE:String = "";

      /** stretchOf(): a local turn, its move and the decisions the move raises. */
      public static const TURN:String = "turn";

      /** stretchOf(): the local mulligan, until this seat's M. */
      public static const MULLIGAN:String = "mulligan";

      /** stretchOf(): a local decision raised outside the local turn (the coin toss, a perk's medic). */
      public static const DECISION:String = "decision";

      /** stretchOf(): R56, a card zoom holds an opponent message that arrived (Timed mode only). */
      public static const HELD:String = "held";

      /** tick(): the stretch goes on (or there is none). */
      public static const RUNNING:String = "";

      /** tick(): a new stretch started on this update. */
      public static const STARTED:String = "started";

      /** tick(): the stretch ran out on this update (once per stretch). */
      public static const EXPIRED:String = "expired";

      private var _kind:String = NONE;

      private var _id:int = -1;

      private var _startMs:int = 0;

      private var _expired:Boolean = false;

      /** R56: when the current hold began (the start the next stretch carries on from), -1 without one. */
      private var _heldSinceMs:int = -1;

      /** R56: the progress at which the held message has been taken; a larger progress drops the carry. */
      private var _heldUntil:int = 0;

      /**
       * No stretch yet.
       */
      public function DuelClock()
      {
         super();
      }

      /**
       * The stretch the board is in.
       * @param isTimed Timed mode (gwint.game.isTimed); Normal mode has no timer.
       * @param localTurn The local turn is on (HumanPlayerController.duelTurnActive).
       * @param mulliganOpen The mulligan is open and this seat has not sent its M.
       * @param localDecision A local decision is open.
       * @param heldByZoom R56: the local player's card zoom is open and an opponent message waits behind it.
       * @return NONE in Normal mode; else TURN, MULLIGAN, DECISION, HELD or NONE, in that order (a decision on the local
       * turn is part of the turn; a zoom on the local turn is part of the turn too).
       */
      public static function stretchOf(isTimed:Boolean, localTurn:Boolean, mulliganOpen:Boolean, localDecision:Boolean, heldByZoom:Boolean = false) : String
      {
         if(!isTimed)
         {
            return NONE;
         }
         if(localTurn)
         {
            return TURN;
         }
         if(mulliganOpen)
         {
            return MULLIGAN;
         }
         if(localDecision)
         {
            return DECISION;
         }
         return heldByZoom ? HELD : NONE;
      }

      /**
       * R58: whether the local card zoom holds the handover to this seat (stretchOf's heldByZoom). The board is between
       * an opponent message arriving and the local stretch it hands over starting: the message is queued in the
       * opponent's controller, at the window's head, being shown or applied by the opponent's controller, or the game
       * flow's switch to the next state waits (it waits on the zoom's dialog). Nobody waits on this seat when the
       * opponent waits for its own next move or the local seat already passed this round, so the zoom then holds
       * nothing.
       * @param zoomOpen The local player's card zoom is open.
       * @param localPassed The local seat is done for the round.
       * @param opponentWaiting The opponent's controller waits for its next move (NetOpponentController.waitingForMove).
       * @param queued An opponent move is queued in its controller.
       * @param atHead An opponent message is at the window's head.
       * @param opponentBusy The opponent's controller shows or applies a move (duelMoveInProgress).
       * @param switchPending A state switch of the game flow is pending while the opponent is its current player
       * (the switch to this seat's turn waits on the zoom's dialog).
       * @return True when the zoom holds the handover.
       */
      public static function zoomHolds(zoomOpen:Boolean, localPassed:Boolean, opponentWaiting:Boolean, queued:Boolean, atHead:Boolean, opponentBusy:Boolean, switchPending:Boolean) : Boolean
      {
         if(!zoomOpen || localPassed)
         {
            return false;
         }
         if(opponentWaiting && !queued && !atHead)
         {
            return false;
         }
         return queued || atHead || opponentBusy || switchPending;
      }

      /**
       * R56: the progress tick() takes: the window's next seq, one more while the held message is still at the window's
       * head (it counts as taken once it moves on).
       * @param nextSeq The window's next seq.
       * @param held zoomHolds().
       * @param atHead An opponent message is at the window's head.
       * @return The progress for tick().
       */
      public static function heldProgress(nextSeq:int, held:Boolean, atHead:Boolean) : int
      {
         return held && atHead ? nextSeq + 1 : nextSeq;
      }

      /**
       * One update: the stretch goes on, starts over (or, R56, carries on from a hold) or runs out.
       * @param kind The stretch now (stretchOf).
       * @param id Which one of its kind: the turn number for TURN, the count of local decisions for DECISION, the
       * game number for MULLIGAN, 0 for HELD.
       * @param nowMs getTimer().
       * @param progress The opponent's messages taken so far (the window's next seq); for HELD the progress once the
       * held message is taken.
       * @return STARTED when the kind or id changed to a stretch, EXPIRED on the update it lasted DuelWait.TURN_MS
       * (counted from the hold it carries on from), else RUNNING.
       */
      public function tick(kind:String, id:int, nowMs:int, progress:int = 0) : String
      {
         if(this._heldSinceMs >= 0 && kind != HELD && progress > this._heldUntil)
         {
            this._heldSinceMs = -1;
         }
         if(kind == HELD)
         {
            if(this._heldSinceMs < 0)
            {
               this._heldSinceMs = nowMs;
            }
            this._heldUntil = progress;
         }
         if(kind != this._kind || id != this._id)
         {
            this._kind = kind;
            this._id = id;
            this._startMs = nowMs;
            this._expired = false;
            if(kind != NONE && this._heldSinceMs >= 0)
            {
               this._startMs = this._heldSinceMs;
               if(kind != HELD)
               {
                  this._heldSinceMs = -1;
               }
            }
            return kind != NONE ? STARTED : RUNNING;
         }
         if(kind == NONE || this._expired || nowMs - this._startMs < DuelWait.TURN_MS)
         {
            return RUNNING;
         }
         this._expired = true;
         return EXPIRED;
      }

      /** The stretch since the last change (NONE before the first tick). */
      public function get kind() : String
      {
         return this._kind;
      }

      /** True from the update the stretch ran out until it ends. */
      public function get expired() : Boolean
      {
         return this._expired && this._kind != NONE;
      }

      /**
       * How long the stretch has lasted.
       * @param nowMs getTimer().
       * @return Milliseconds since it started (or since the hold it carries on from), 0 without a stretch.
       */
      public function elapsedMs(nowMs:int) : int
      {
         return this._kind != NONE ? nowMs - this._startMs : 0;
      }

      /**
       * What the timer shows.
       * @param nowMs getTimer().
       * @return Milliseconds left, from DuelWait.TURN_MS down to 0, or -1 without a stretch.
       */
      public function remainingMs(nowMs:int) : int
      {
         if(this._kind == NONE)
         {
            return -1;
         }
         return int(Math.max(0,DuelWait.TURN_MS - (nowMs - this._startMs)));
      }
   }
}
