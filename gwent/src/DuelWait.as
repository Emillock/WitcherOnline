package red.game.witcher3.menus.gwint
{
   /**
    * The stuck-wait rule of a duel (spec 10, R47) and the opponent leaving (spec 10, 11): board-independent, so
    * DuelSelfTest can run it on synthetic board states and times; DuelSession gathers the state, sends and ends.
    *
    * One rule for every wait on an opponent message: the Hello, a move, a decision (the coin toss included), the
    * mulligan, the end of game confirmation (E) and the replay (R). kindOf() names what the board waits for now, or
    * NONE (it waits for nothing, for its own player, or the next opponent message is already in the window and only
    * waits for this board). tick() runs once per update: the wait starts over whenever its kind changes or an
    * opponent message was applied (the window's next seq moved on), so any message arriving resets it, and it expires
    * once the same wait lasted longer than the limit: 120 s in Normal mode, the turn time (60 s) plus 30 s in Timed
    * mode. Then the board sends Y with a reason mark (MARK_STUCK, or MARK_HELLO for the Hello wait) and ends as no
    * contest (stuck_wait, hello_timeout); the opponent that receives that Y ends the same way (reasonOfY), so a paused
    * or slow peer never settles alone.
    *
    * The opponent leaving (gwint.game.opponentLeft, from Witcher Online's script) ends the game as no contest
    * (opponent_left) without a message, once no opponent message is ready in the window (it may still hold the last
    * moves, an E or a surrender, which apply first) or LEFT_DRAIN_MS after the signal. A confirmed win or loss stands:
    * its end screen settles it as usual (R43).
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

      /** kindOf(): the opponent's Hello (and this board's own, the whole Hello exchange). */
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

      /** Third argument of a Y sent when a wait expired. */
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
       * @param helloDone Both Hellos agreed.
       * @param messageReady The opponent's next message is in the window (then the board only waits for itself).
       * @param endPhase DuelEnd.phase.
       * @param replayWaiting This board sent R on a confirmed draw and has not got the opponent's.
       * @param decisionWaiting An opponent decision is open.
       * @param mulliganWaiting This seat's mulligan is done and the opponent's is not.
       * @param moveWaiting It is the opponent's turn and no move of it is queued.
       * @return HELLO (whatever the window holds, until the Hello exchange is done), NONE when a message is ready,
       * else END, REPLAY, DECISION, MULLIGAN, MOVE or NONE.
       */
      public static function kindOf(helloDone:Boolean, messageReady:Boolean, endPhase:int, replayWaiting:Boolean, decisionWaiting:Boolean, mulliganWaiting:Boolean, moveWaiting:Boolean) : String
      {
         if(!helloDone)
         {
            return HELLO;
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

      /**
       * Whether the opponent leaving ends the game now.
       * @param leftAtMs When the board saw the signal (getTimer ms).
       * @param nowMs getTimer().
       * @param messageReady The opponent's next message is in the window and has not been applied.
       * @param resultStands The result is confirmed as a win or loss (its end screen settles it).
       * @return False while the result stands; else true once no message is ready, or LEFT_DRAIN_MS after the signal.
       */
      public static function leftEnds(leftAtMs:int, nowMs:int, messageReady:Boolean, resultStands:Boolean) : Boolean
      {
         return !resultStands && (!messageReady || nowMs - leftAtMs > LEFT_DRAIN_MS);
      }
   }
}
