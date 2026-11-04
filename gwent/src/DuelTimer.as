package red.game.witcher3.menus.gwint
{
   import flash.display.DisplayObjectContainer;

   /**
    * Timed mode's clocks and their view on the board (spec 15, R53, R54, R56): reads the local and the opponent's
    * controllers, runs the local DuelClock and the opponent's display-only DuelClock, logs DUEL TIMER start <stretch>
    * and DUEL TIMER expired <stretch> after=<ms>, and shows DuelTimerView next to the renderer of the player whose time
    * runs. What happens when the local time runs out is DuelSession's (timeUp). In Normal mode both clocks stay NONE
    * and no view is ever created.
    */
   public class DuelTimer
   {

      private var _clock:DuelClock;

      private var _opponentClock:DuelClock;

      private var _view:DuelTimerView;

      /**
       * Both clocks without a stretch, no view yet.
       */
      public function DuelTimer()
      {
         super();
         this._clock = new DuelClock();
         this._opponentClock = new DuelClock();
      }

      /**
       * One update, every 20 ms from DuelSession.update.
       * @param isTimed Timed mode.
       * @param human The local player's controller (PLAYER_1), or null.
       * @param opponent The opponent's controller (PLAYER_2), or null.
       * @param mulliganOpen The mulligan is open and this seat has not sent its M.
       * @param localDecision A local decision is open.
       * @param heldByZoom R56: the local card zoom holds an opponent message that arrived.
       * @param localDecisions Local decisions opened so far (the id of a DECISION stretch).
       * @param gameNumber The game of the match (the id of a MULLIGAN stretch).
       * @param progress The opponent's messages taken so far; while held, the progress once the held one is taken.
       * @param nowMs getTimer().
       * @param layer The container of the view (the Gwent menu).
       * @param log function(line:String):void, the duel log.
       * @return The local stretch while its time is up (DuelSession then acts on it), else DuelClock.NONE.
       */
      public function update(isTimed:Boolean, human:HumanPlayerController, opponent:NetOpponentController, mulliganOpen:Boolean, localDecision:Boolean, heldByZoom:Boolean, localDecisions:int, gameNumber:int, progress:int, nowMs:int, layer:DisplayObjectContainer, log:Function) : String
      {
         var kind:String = DuelClock.stretchOf(isTimed,human != null && human.duelTurnActive,mulliganOpen,localDecision,heldByZoom);
         var id:int = kind == DuelClock.TURN ? human.duelTurnNumber : (kind == DuelClock.DECISION ? localDecisions : (kind == DuelClock.HELD ? 0 : gameNumber));
         var event:String = this._clock.tick(kind,id,nowMs,progress);
         if(event == DuelClock.STARTED)
         {
            log("DUEL TIMER start " + kind);
         }
         else if(event == DuelClock.EXPIRED)
         {
            log("DUEL TIMER expired " + kind + " after=" + this._clock.elapsedMs(nowMs));
         }
         var opponentKind:String = DuelClock.stretchOf(isTimed,opponent != null && opponent.duelTurnActive,false,false);
         this._opponentClock.tick(opponentKind,opponent != null ? opponent.duelTurnNumber : 0,nowMs);
         if(kind != DuelClock.NONE)
         {
            this.show(layer,human.playerRenderer,this._clock.remainingMs(nowMs));
         }
         else if(opponentKind != DuelClock.NONE)
         {
            this.show(layer,opponent.playerRenderer,this._opponentClock.remainingMs(nowMs));
         }
         else
         {
            this.hide();
         }
         return this._clock.expired ? kind : DuelClock.NONE;
      }

      /**
       * Hides the countdown (no stretch runs, or the duel tick stops).
       */
      public function hide() : void
      {
         if(this._view != null)
         {
            this._view.hide();
         }
      }

      /** Shows the countdown next to a player's renderer; the view is created the first time. */
      private function show(layer:DisplayObjectContainer, renderer:GwintPlayerRenderer, remainingMs:int) : void
      {
         if(this._view == null)
         {
            this._view = new DuelTimerView();
         }
         this._view.show(layer,renderer,remainingMs);
      }
   }
}
