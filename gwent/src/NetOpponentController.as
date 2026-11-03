package red.game.witcher3.menus.gwint
{
   import flash.utils.getTimer;

   /**
    * PLAYER_2's controller in a duel (spec 9.5): plays the opponent's moves as they arrive instead of an AI.
    * DuelSession hands it the opponent's next move message (seq order, one at a time); on the opponent's turn the
    * controller applies it, so a move is only applied when this board is idle and it is that seat's turn.
    *
    * States: Idle (turn over), WaitingForMove (the opponent's turn: the next move is taken once no card moves, no card
    * FX plays, no message shows and no dialog or card zoom is open), ShowingMove (the card goes to the middle of the
    * board, as the AI shows its card), ApplyingCard (the vanilla BasePlayerController path, as for any controller),
    * ChoosingMove (BasePlayerController.state_update_ApplyingCard switches here instead of Idle when the local player
    * has passed; the turn is over as well, and the game flow starts the next turn of this seat).
    *
    * Before a move is applied DuelSession compares the hashes (checkApply). The move names its cards by net id; a net id
    * that is not known here, a card that is not in this seat's hand, or a leader that cannot be used is a desync. Its
    * DUEL DESYNC line then shows two equal hashes (the hash check had passed); DUEL MISMATCH names the cause.
    * S (pass) marks the seat done. A choice inside the opponent's move (medic, leader dialogs) is a decision
    * (DuelSession.decide): ApplyingCard holds until the opponent's D has been applied. This controller never sets
    * BasePlayerController.isAI, so ApplyLeaderAbility takes the same (human) branches on both boards and every leader
    * choice goes through decide (CardLeaderInstance.duelDecide).
    */
   public class NetOpponentController extends BasePlayerController
   {

      /** How long the opponent's card stays in the middle of the board before it is applied (the AI waits 1.2 s). */
      public static const SHOW_MOVE_MS:int = 800;

      private var _moves:Array;

      private var _showStartMs:int;

      /**
       * A controller without moves, in Idle.
       */
      public function NetOpponentController()
      {
         super();
         this._moves = [];
         _stateMachine.AddState("Idle",this.state_begin_TurnDone,null,null);
         _stateMachine.AddState("WaitingForMove",null,this.state_update_WaitingForMove,null);
         _stateMachine.AddState("ShowingMove",this.state_begin_ShowingMove,this.state_update_ShowingMove,null);
         _stateMachine.AddState("ApplyingCard",state_begin_ApplyingCard,state_update_ApplyingCard,null);
         _stateMachine.AddState("ChoosingMove",this.state_begin_TurnDone,null,null);
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
       * The opponent's turn starts: wait for its next move. Defensive (R28: the vanilla flow never starts the turn of a
       * seat with nothing left to play): if it did, the opponent's board sends S (HumanPlayerController), so this side
       * waits for that S too.
       */
      override public function startTurn() : void
      {
         super.startTurn();
         _turnOver = false;
         _stateMachine.ChangeState("WaitingForMove");
      }

      /**
       * Also waits while a dialog or the local player's card zoom is open (the human controller does the same), and
       * while a decision is open (DuelSession.decisionOpen: the opponent's choice inside its move has not arrived) or a
       * deferred rule effect waits (DuelSession.effectsPending: the move is applied only once all of them ran).
       */
      override protected function cardEffectApplying() : Boolean
      {
         return Boolean(super.cardEffectApplying()) || gameFlowControllerRef.mcChoiceDialog.isShown() || DuelSession.active != null && (DuelSession.active.decisionOpen || DuelSession.active.effectsPending);
      }

      /**
       * The move is applied (or this seat passed): the game flow goes on.
       */
      protected function state_begin_TurnDone() : void
      {
         _turnOver = true;
      }

      /**
       * Takes the queued move once the board is idle: hash check, then a pass or a card transaction.
       */
      protected function state_update_WaitingForMove() : void
      {
         var session:DuelSession = DuelSession.active;
         if(session == null || session.ended || this._moves.length == 0 || this.cardEffectApplying())
         {
            return;
         }
         var move:DuelMessage = this._moves.shift() as DuelMessage;
         if(!session.checkApply(move,DuelStateHash.SCOPE_FULL))
         {
            return;
         }
         if(move.type == "S")
         {
            currentRoundStatus = BasePlayerController.ROUND_PLAYER_STATUS_DONE;
            _turnOver = true;
            _stateMachine.ChangeState("Idle");
            return;
         }
         var transaction:CardTransaction = this.transactionFor(move,session);
         if(transaction == null)
         {
            return;
         }
         _decidedCardTransaction = transaction;
         _stateMachine.ChangeState("ShowingMove");
      }

      /**
       * The card goes to the middle of the board (the vanilla transaction start, as the AI does).
       */
      protected function state_begin_ShowingMove() : void
      {
         startCardTransaction(_decidedCardTransaction.sourceCardInstanceRef.instanceId);
         this._showStartMs = getTimer();
      }

      /**
       * Applies the move once the card has arrived, SHOW_MOVE_MS have passed and no card zoom or dialog is open.
       */
      protected function state_update_ShowingMove() : void
      {
         if(!this.cardEffectApplying() && getTimer() - this._showStartMs >= SHOW_MOVE_MS)
         {
            _stateMachine.ChangeState("ApplyingCard");
         }
      }

      /**
       * The transaction a move message names, with the same fields HumanPlayerController builds at its commit points;
       * null after a desync (unknown net id, card not in this seat's hand, bad arguments, leader not usable).
       */
      private function transactionFor(move:DuelMessage, session:DuelSession) : CardTransaction
      {
         var manager:CardManager = CardManager.getInstance();
         var transaction:CardTransaction = new CardTransaction();
         transaction.targetPlayerID = playerID;
         if(move.type == "L")
         {
            var leader:CardLeaderInstance = manager.getCardLeader(playerID);
            if(move.args.length != 0 || leader == null || !leader.canBeUsed)
            {
               session.desync(move.seq,session.lastAppliedHash,move.hash,"leader");
               return null;
            }
            transaction.sourceCardInstanceRef = leader;
            return transaction;
         }
         var source:CardInstance = move.args.length > 0 ? this.cardOf(move.args[0],session) : null;
         if(source == null || source.inList != CardManager.CARD_LIST_LOC_HAND || source.listsPlayer != playerID)
         {
            session.desync(move.seq,session.lastAppliedHash,move.hash,"card " + (move.args.length > 0 ? move.args[0] : "none"));
            return null;
         }
         transaction.sourceCardInstanceRef = source;
         if(move.type == "P" && move.args.length == 3)
         {
            var slot:int = int(move.args[1]);
            var target:int = session.targetPlayerOf(move.args[2]);
            if(String(slot) == move.args[1] && slot >= CardManager.CARD_LIST_LOC_SEIGE && slot <= CardManager.CARD_LIST_LOC_WEATHERSLOT && target != -2)
            {
               transaction.targetSlotID = slot;
               transaction.targetPlayerID = target;
               return transaction;
            }
         }
         else if(move.type == "C" && move.args.length == 2)
         {
            var targetCard:CardInstance = this.cardOf(move.args[1],session);
            if(targetCard != null)
            {
               transaction.targetSlotID = CardManager.CARD_LIST_LOC_INVALID;
               transaction.targetCardInstanceRef = targetCard;
               return transaction;
            }
         }
         else if(move.type == "G" && move.args.length == 1 && source.templateRef.isType(CardTemplate.CardType_Global_Effect))
         {
            return transaction;
         }
         session.desync(move.seq,session.lastAppliedHash,move.hash,"move " + move.type);
         return null;
      }

      /** The local card instance of a net id argument ("A17"), or null if it is malformed or unknown here. */
      private function cardOf(arg:String, session:DuelSession) : CardInstance
      {
         var netId:int = DuelIds.parse(arg);
         var instanceId:int = netId >= 0 ? session.ids.toLocal(netId) : -1;
         return instanceId >= 0 ? CardManager.getInstance().getCardInstance(instanceId) : null;
      }
   }
}
