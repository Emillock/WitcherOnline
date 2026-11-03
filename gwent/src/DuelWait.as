package red.game.witcher3.menus.gwint
{
   /**
    * The stuck-wait rule of a duel (spec 10, R47, R51) and the opponent leaving (spec 10, 11, R50): board-independent,
    * so DuelSelfTest can run it on synthetic board states and times; DuelSession gathers the state and, from the one
    * verdict of verdict(), only sends and ends.
    *
    * One rule for every wait on an opponent message: the Hello (once this board sent its own), a move, a decision (the
    * coin toss included), the mulligan, the end of game confirmation (E) and the replay (R). kindOf() names what the
    * board waits for now, or NONE (it waits for nothing, for its own player, or the next opponent message is already in
    * the window and only waits for this board). Each update the wait starts over whenever its kind changes or an
    * opponent message was applied (the window's next seq moved on), so any message arriving resets it, and it expires
    * once the same wait lasted longer than the limit: 120 s in Normal mode, the turn time (60 s) plus 30 s in Timed
    * mode. Then (STUCK, HELLO) the board sends Y with a reason mark (MARK_STUCK, MARK_HELLO) and ends as no contest
    * (stuck_wait, hello_timeout); the opponent that receives that Y ends the same way (reasonOfY), so a paused or slow
    * peer never settles alone. R51: the R wait is the exception (REPLAY_TIMEOUT): both seats confirmed a draw, so the
    * board sends X and ends it as a draw without money, and an opponent that receives the X ends the same way.
    *
    * The opponent leaving (gwint.game.opponentLeft, from Witcher Online's script) waits until no opponent message is
    * ready in the window (it may still hold the last moves, an E or a surrender, which apply first), at most
    * LEFT_DRAIN_MS. Then: a confirmed win or loss stands (its end screen settles it, R43); a confirmed draw ends as a
    * draw (LEFT_DRAW, opponent_leave, R51); while this board waits for the opponent's E it ends through the stuck path
    * (STUCK, the Y carries its E hash, R50); otherwise LEFT: the board still sends the stuck Y (R50: a present opponent
    * the script took for gone then ends as no contest too, and a send to a gone one costs nothing) and ends as no
    * contest (opponent_left).
    */
   public class DuelWait
   {

      /** The stuck-wait limit in Normal mode (spec 10). */
      public static const NORMAL_MS:int = 120000;

      /** The turn time of Timed mode (Task 16 runs the turn timer itself). */
      public static const TURN_MS:int = 60000;

      /** What the stuck-wait limit of Timed mode adds to the turn time (spec 10). */
      public static const TIMED_EXTRA_MS:int = 30000;

      /** How long the opponent leaving waits for opponent messages already in the window that cannot apply yet. */
      public static const LEFT_DRAIN_MS:int = 5000;

      /** kindOf(): the board waits for no opponent message. */
      public static const NONE:String = "";

      /** kindOf(): the opponent's Hello, once this board sent its own. */
      public static const HELLO:String = "hello";

      /** kindOf(): the opponent's move on its turn. */
      public static const MOVE:String = "move";

      /** kindOf(): the opponent's answer to a decision (D), the coin toss included. */
      public static const DECISION:String = "decision";

      /** kindOf(): the opponent's mulligan (its redraws and M), once this seat is done. */
      public static const MULLIGAN:String = "mulligan";

      /** kindOf(): the opponent's end of game message (E). */
      public static const END:String = "end";

      /** kindOf(): the opponent's replay (R) after this board's R. */
      public static const REPLAY:String = "replay";

      /** verdict(): the game goes on. */
      public static const GO_ON:String = "";

      /** verdict(): a wait expired: send the stuck Y, end as no contest (stuck_wait). */
      public static const STUCK:String = "stuck";

      /** verdict(): the Hello wait expired: send the Hello Y, end as no contest (hello_timeout). */
      public static const HELLO_TIMEOUT:String = "hello_timeout";

      /** verdict(): the R wait expired: send X, end as a draw (replay_timeout). */
      public static const REPLAY_TIMEOUT:String = "replay_timeout";

      /** verdict(): the opponent left: send the stuck Y, end as no contest (opponent_left). */
      public static const LEFT:String = "left";

      /** verdict(): the opponent left a confirmed draw: end as a draw (opponent_leave). */
      public static const LEFT_DRAW:String = "left_draw";

      /** Third argument of a Y sent when a wait expired (or the opponent left). */
      public static const MARK_STUCK:String = "stuck";

      /** Third argument of a Y sent when the Hello wait expired. */
      public static const MARK_HELLO:String = "hello";

      /** The end reason of an expired wait. */
      public static const STUCK_REASON:String = "stuck_wait";

      /** The end reason of an expired Hello wait. */
      public static const HELLO_REASON:String = "hello_timeout";

      private var _kind:String = NONE;

      private var _progress:int = -1;

      private var _sinceMs:int = 0;

      /**
       * No wait yet.
       */
      public function DuelWait()
      {
         super();
      }

      /**
       * The stuck-wait limit of a mode.
       * @param isTimed Timed mode (gwint.game.isTimed).
       * @return NORMAL_MS, or TURN_MS + TIMED_EXTRA_MS in Timed mode.
       */
      public static function limitFor(isTimed:Boolean) : int
      {
         return isTimed ? TURN_MS + TIMED_EXTRA_MS : NORMAL_MS;
      }

      /**
       * What the board waits for now.
       * @param helloSent This board sent its Hello (before that it only waits for itself).
       * @param helloDone Both Hellos agreed.
       * @param messageReady The opponent's next message is in the window (then the board only waits for itself).
       * @param endPhase DuelEnd.phase.
       * @param replayWaiting This board sent R on a confirmed draw and has not got the opponent's.
       * @param decisionWaiting An opponent decision is open.
       * @param mulliganWaiting This seat's mulligan is done and the opponent's is not.
       * @param moveWaiting It is the opponent's turn and no move of it is queued.
       * @return Before the Hello exchange is done: HELLO once this board sent its Hello (whatever the window holds),
       * else NONE; after it NONE when a message is ready, else END, REPLAY, DECISION, MULLIGAN, MOVE or NONE.
       */
      public static function kindOf(helloSent:Boolean, helloDone:Boolean, messageReady:Boolean, endPhase:int, replayWaiting:Boolean, decisionWaiting:Boolean, mulliganWaiting:Boolean, moveWaiting:Boolean) : String
      {
         if(!helloDone)
         {
            return helloSent ? HELLO : NONE;
         }
         if(messageReady)
         {
            return NONE;
         }
         if(endPhase == DuelEnd.CONFIRMING)
         {
            return END;
         }
         if(replayWaiting)
         {
            return REPLAY;
         }
         if(decisionWaiting)
         {
            return DECISION;
         }
         if(mulliganWaiting)
         {
            return MULLIGAN;
         }
         return moveWaiting ? MOVE : NONE;
      }

      /**
       * One update: the wait goes on, starts over, or expires.
       * @param kind What the board waits for now (kindOf).
       * @param progress The window's next seq: a change means an opponent message was applied.
       * @param nowMs getTimer().
       * @param limitMs The stuck-wait limit (limitFor).
       * @return True once the same wait, without an opponent message applied, lasted longer than limitMs.
       */
      public function tick(kind:String, progress:int, nowMs:int, limitMs:int) : Boolean
      {
         if(kind != this._kind || progress != this._progress)
         {
            this._kind = kind;
            this._progress = progress;
            this._sinceMs = nowMs;
         }
         return kind != NONE && nowMs - this._sinceMs > limitMs;
      }

      /**
       * One update's verdict: the opponent leaving first, then the wait (tick).
       * @param kind What the board waits for now (kindOf).
       * @param progress The window's next seq.
       * @param nowMs getTimer().
       * @param limitMs The stuck-wait limit (limitFor).
       * @param leftAtMs When the board saw gwint.game.opponentLeft, -1 if it has not.
       * @param messageReady The opponent's next message is in the window and has not been applied.
       * @param endPhase DuelEnd.phase.
       * @param isDraw The result this board sent in E is a draw.
       * @return GO_ON, LEFT, LEFT_DRAW, STUCK, HELLO_TIMEOUT or REPLAY_TIMEOUT.
       */
      public function verdict(kind:String, progress:int, nowMs:int, limitMs:int, leftAtMs:int, messageReady:Boolean, endPhase:int, isDraw:Boolean) : String
      {
         var expired:Boolean = this.tick(kind,progress,nowMs,limitMs);
         var resultStands:Boolean = endPhase == DuelEnd.CONFIRMED && !isDraw;
         if(leftAtMs >= 0 && !resultStands && (!messageReady || nowMs - leftAtMs > LEFT_DRAIN_MS))
         {
            if(endPhase == DuelEnd.CONFIRMED)
            {
               return LEFT_DRAW;
            }
            return endPhase == DuelEnd.CONFIRMING ? STUCK : LEFT;
         }
         if(!expired)
         {
            return GO_ON;
         }
         if(kind == HELLO)
         {
            return HELLO_TIMEOUT;
         }
         return kind == REPLAY ? REPLAY_TIMEOUT : STUCK;
      }

      /** What the board waits for since the last change (NONE before the first tick). */
      public function get kind() : String
      {
         return this._kind;
      }

      /**
       * How an opponent's Y ends this board.
       * @param args The arguments of the Y (hash, seq, and the mark of an expired wait).
       * @return STUCK_REASON or HELLO_REASON for a Y of an expired wait, "" for a desync.
       */
      public static function reasonOfY(args:Array) : String
      {
         var mark:String = args != null && args.length >= 3 ? String(args[2]) : "";
         if(mark == MARK_STUCK)
         {
            return STUCK_REASON;
         }
         return mark == MARK_HELLO ? HELLO_REASON : "";
      }
   }
}
