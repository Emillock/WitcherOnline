package red.game.witcher3.menus.gwint
{
   /**
    * The turn timer of Timed mode (spec 15, R53, R54): board-independent, so DuelSelfTest can run it on synthetic
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
       * @return NONE in Normal mode; else TURN, MULLIGAN, DECISION or NONE, in that order (a decision on the local
       * turn is part of the turn).
       */
      public static function stretchOf(isTimed:Boolean, localTurn:Boolean, mulliganOpen:Boolean, localDecision:Boolean) : String
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
         return localDecision ? DECISION : NONE;
      }

      /**
       * One update: the stretch goes on, starts over or runs out.
       * @param kind The stretch now (stretchOf).
       * @param id Which one of its kind: the turn number for TURN, the count of local decisions for DECISION, the
       * game number for MULLIGAN.
       * @param nowMs getTimer().
       * @return STARTED when the kind or id changed to a stretch, EXPIRED on the update it lasted DuelWait.TURN_MS,
       * else RUNNING.
       */
      public function tick(kind:String, id:int, nowMs:int) : String
      {
         if(kind != this._kind || id != this._id)
         {
            this._kind = kind;
            this._id = id;
            this._startMs = nowMs;
            this._expired = false;
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
       * @return Milliseconds since it started, 0 without a stretch.
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
