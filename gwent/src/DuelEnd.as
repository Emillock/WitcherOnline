package red.game.witcher3.menus.gwint
{
   /**
    * The end of one duel game (spec 9.8, rulings R43 and R13): the confirmation of the final state, then on a draw the
    * replay or the leave. Board-independent, so DuelSelfTest can run synthetic E, R and X messages through route() in
    * any order; DuelSession sends, checks hashes and applies what route() accepts, and DuelWait limits its waits.
    *
    * When a game ends (GwintGameFlowController.state_begin_ShowingFinalResult, the board settled) each board sends E
    * with the winner as it sees it (seat A, B, or N for a draw) and the hash of its final state, then waits. Neither
    * seat settles until the opponent's E arrives with the same winner and the same hash as its own E: then the result is
    * confirmed and the end screen opens. A Y in that wait, a mismatch, or no E within the stuck-wait limit (DuelWait)
    * end the game as no contest, so a desync on the last message of a match pays neither side. Both seats compare the
    * same two hashes (their own E and the opponent's E), so they always reach the same verdict.
    * A confirmed draw is replayed when both seats sent R (DuelSession then starts the next game); X (a player closed
    * the end screen) ends it as a draw that moves no money, no R within the stuck-wait limit as no contest.
    */
   public class DuelEnd
   {

      /** The game is on: the opponent's E waits in the window, R and X are desyncs. */
      public static const PLAYING:int = 0;

      /** This board sent its E and waits for the opponent's. */
      public static const CONFIRMING:int = 1;

      /** Both E agreed: the end screen is up. */
      public static const CONFIRMED:int = 2;

      /** route(): the message stays in the window. */
      public static const WAIT:String = "wait";

      /** route(): the opponent's E; DuelSession checks its hash against this board's own E. */
      public static const CONFIRM:String = "confirm";

      /** route(): the opponent wants to replay the drawn game (R). */
      public static const REPLAY:String = "replay";

      /** route(): the opponent closed the end screen of the drawn game (X). */
      public static const LEAVE:String = "leave";

      /** The winner argument of E for a draw. */
      public static const DRAW:String = "N";

      /** Where this game is (PLAYING, CONFIRMING, CONFIRMED). */
      public var phase:int = PLAYING;

      /** The winner as this board sees it: "A", "B" or DRAW (set with the local E). */
      public var winner:String = "";

      /** The seq of this board's E. */
      public var endSeq:int = 0;

      /** The hash this board's E carried (its final state). */
      public var endHash:uint = 0;

      /** This board sent R. */
      public var replaySent:Boolean = false;

      /** The opponent's R was applied. */
      public var replayReceived:Boolean = false;

      /**
       * A game that is on.
       */
      public function DuelEnd()
      {
         super();
      }

      /**
       * This board reached the end of the game and sent its E.
       * @param winnerSeat "A", "B" or DRAW.
       * @param seq The seq of the E.
       * @param hash The hash the E carried.
       */
      public function reached(winnerSeat:String, seq:int, hash:uint) : void
      {
         this.phase = CONFIRMING;
         this.winner = winnerSeat;
         this.endSeq = seq;
         this.endHash = hash;
      }

      /**
       * The opponent's E agreed with this board's.
       */
      public function confirm() : void
      {
         this.phase = CONFIRMED;
      }

      /** True once this board sent its E (the game no longer takes moves). */
      public function get over() : Boolean
      {
         return this.phase != PLAYING;
      }

      /** True when the confirmed result is a draw. */
      public function get isDraw() : Boolean
      {
         return this.winner == DRAW;
      }

      /**
       * What to do with the opponent's next message once this game ended or when it is an E, R or X (QUITGAME and Y
       * are handled before).
       * @param message The opponent's next message.
       * @return WAIT, CONFIRM, REPLAY, LEAVE, or the detail of a desync: an E with another winner or a second E, R or X
       * before the result was confirmed or after a confirmed win, a second R, arguments on R or X, any other message
       * after the end.
       */
      public function route(message:DuelMessage) : String
      {
         var detail:String = "after end " + message.type + " " + message.args.join(",");
         if(this.phase == PLAYING)
         {
            return message.type == DuelSession.END ? WAIT : detail;
         }
         if(message.type == DuelSession.END)
         {
            if(this.phase != CONFIRMING)
            {
               return detail;
            }
            return message.args.length == 1 && message.args[0] == this.winner ? CONFIRM : "end winner " + message.args.join(",") + " mine " + this.winner;
         }
         if(this.phase != CONFIRMED || !this.isDraw || message.args.length != 0)
         {
            return detail;
         }
         if(message.type == DuelSession.REPLAY)
         {
            return this.replayReceived ? detail : REPLAY;
         }
         return message.type == DuelSession.LEAVE ? LEAVE : detail;
      }

      /**
       * The opponent's late X, or its QUITGAME, of the game before a replay: after its R it left or surrendered while
       * this board had both R and started the next game, so its window still carries that game's message with the seq
       * the new game's window expects first.
       * @param window The opponent's window.
       * @param prevMatchId The match id of the game before.
       * @param seq The seq the new game's window expects first.
       * @return That message, or null.
       */
      public static function lateLeave(window:String, prevMatchId:String, seq:int) : DuelMessage
      {
         var tokens:Array = window != null ? window.split(DuelWindow.SEPARATOR) : [];
         for(var i:int = 0; i < tokens.length; i++)
         {
            var m:DuelMessage = DuelCodec.decode(tokens[i]);
            if(m != null && m.version == DuelCodec.PROTOCOL_VERSION && m.matchId == prevMatchId && m.seq == seq && (m.type == DuelSession.LEAVE && m.args.length == 0 || m.type == DuelCodec.SURRENDER))
            {
               return m;
            }
         }
         return null;
      }
   }
}
