package red.game.witcher3.menus.gwint
{
   /**
    * PLAYER_2's controller in a duel (spec 9.5): plays the opponent's moves as they arrive instead of an AI.
    * DuelSession hands it the opponent's next move message (seq order, one at a time); on the opponent's turn the
    * controller applies it, so a move is only applied when this board is idle and it is that seat's turn.
    *
    * Skeleton (Task 9): a move queue, startTurn waits for the next move, and the pass (S) is applied. Playing cards
    * and the leader (P, C, G, L through the vanilla ApplyingCard path) is Task 11; until then any other move ends the
    * duel as no contest.
    */
   public class NetOpponentController extends BasePlayerController
   {

      private var _moves:Array;

      /**
       * A controller without moves, in Idle.
       */
      public function NetOpponentController()
      {
         super();
         this._moves = [];
         _stateMachine.AddState("Idle",null,null,null);
         _stateMachine.AddState("WaitingForMove",null,this.state_update_WaitingForMove,null);
         _stateMachine.AddState("ApplyingCard",state_begin_ApplyingCard,state_update_ApplyingCard,null);
         _stateMachine.AddState("ChoosingMove",null,this.state_update_WaitingForMove,null);
      }

      /**
       * True while a move waits to be applied (DuelSession then keeps the next one in its window).
       */
      public function get hasQueuedMove() : Boolean
      {
         return this._moves.length > 0;
      }

      /**
       * Queues the opponent's next move (DuelSession, in seq order).
       * @param move A message of type P, C, G, L or S.
       */
      public function queueMove(move:DuelMessage) : void
      {
         this._moves.push(move);
      }

      /**
       * The opponent's turn starts: wait for its next move. When the opponent has nothing left to play (empty hand,
       * leader not usable) its board still sends S (HumanPlayerController), so this side waits for that S too.
       */
      override public function startTurn() : void
      {
         super.startTurn();
         _turnOver = false;
         _stateMachine.ChangeState("WaitingForMove");
      }

      /**
       * Applies the queued move once the board is idle (no tween, card FX, message or choice dialog).
       */
      protected function state_update_WaitingForMove() : void
      {
         var session:DuelSession = DuelSession.active;
         if(session == null || session.ended || this._moves.length == 0 || cardEffectApplying() || gameFlowControllerRef.mcChoiceDialog.isShown())
         {
            return;
         }
         var move:DuelMessage = this._moves.shift() as DuelMessage;
         session.logApply(move,DuelStateHash.SCOPE_FULL);
         if(move.type == "S")
         {
            currentRoundStatus = BasePlayerController.ROUND_PLAYER_STATUS_DONE;
            _turnOver = true;
            _stateMachine.ChangeState("Idle");
            return;
         }
         session.abort("unsupported");
      }
   }
}
