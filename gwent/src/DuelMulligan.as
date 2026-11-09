package red.game.witcher3.menus.gwint
{
   /**
    * The mulligan of one duel game for both seats at once (spec 9.4): the phase of this board, the local seat's M and
    * the opponent's redraws and M. Board-independent, so DuelSelfTest can run synthetic D MUL and M messages through
    * route() in any order. GwintGameFlowController applies what route() accepts (the redraw needs the board) and asks
    * roundMayStart() before round 1.
    */
   public class DuelMulligan
   {

      /** The hands are not drawn yet: the opponent's D MUL and M wait in the window. */
      public static const NOT_YET:int = 0;

      /** Both seats mulligan: the opponent's D MUL and M are applied as they arrive. */
      public static const OPEN:int = 1;

      /** Round 1 has started: a D MUL or M now is a desync. */
      public static const OVER:int = 2;

      /** route(): the message stays in the window. */
      public static const WAIT:String = "wait";

      /** route(): apply the opponent's redraw (D MUL). */
      public static const REDRAW:String = "redraw";

      /** route(): the opponent's mulligan is done (M). */
      public static const DONE:String = "done";

      /** Most redraws a seat may make. */
      public static const MAX_REDRAWS:int = 2;

      /** Where this board's mulligan is (NOT_YET, OPEN, OVER). */
      public var phase:int = NOT_YET;

      /** Redraws of the opponent applied so far. */
      public var remoteRedraws:int = 0;

      /** The opponent's M arrived. */
      public var remoteDone:Boolean = false;

      /** This seat sent its M. */
      public var localSent:Boolean = false;

      /** The waiting message was shown (once per game). */
      public var waitShown:Boolean = false;

      /**
       * A mulligan before the hands are drawn.
       */
      public function DuelMulligan()
      {
         super();
      }

      /**
       * The hands are drawn: both seats mulligan from now on.
       */
      public function open() : void
      {
         this.phase = OPEN;
         this.remoteRedraws = 0;
         this.remoteDone = false;
         this.localSent = false;
         this.waitShown = false;
      }

      /**
       * Round 1 starts.
       */
      public function close() : void
      {
         this.phase = OVER;
      }

      /**
       * What to do with the opponent's D MUL or M.
       * @param message A D whose kind is MUL, or an M.
       * @return WAIT, REDRAW, DONE, or the detail of a desync: after round 1 started, after the opponent's M, a third
       * redraw, wrong arguments.
       */
      public function route(message:DuelMessage) : String
      {
         if(this.phase == NOT_YET)
         {
            return WAIT;
         }
         var detail:String = "mulligan " + message.type + " " + message.args.join(",");
         if(this.phase != OPEN || this.remoteDone)
         {
            return detail;
         }
         if(message.type == DuelSession.MULLIGAN_DONE)
         {
            return message.args.length == 0 ? DONE : detail;
         }
         if(message.args.length != 3 || message.args[0] != DuelSession.MULLIGAN || message.args[1] != DuelSession.ASKER_PERK || this.remoteRedraws >= MAX_REDRAWS)
         {
            return detail;
         }
         return REDRAW;
      }

      /**
       * Whether round 1 may start: this seat is done and the opponent's M arrived (in either order).
       * @param localDone Whether the local player finished the mulligan.
       * @return True when both seats are done.
       */
      public function roundMayStart(localDone:Boolean) : Boolean
      {
         return localDone && this.remoteDone;
      }
   }
}
