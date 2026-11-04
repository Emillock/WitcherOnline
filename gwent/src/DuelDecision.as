package red.game.witcher3.menus.gwint
{
   /**
    * One open decision of a duel (spec 9.6, DuelSession.decide): its kind, the asker as written on the wire, the hash
    * scope of its D, and the callbacks of the rules code that asked. route() is the board-independent part of taking
    * the opponent's messages while decisions are open, so DuelSelfTest can run it on synthetic messages.
    */
   public class DuelDecision
   {

      /** route(): the message is not a decision and no opponent decision is open; normal dispatch goes on. */
      public static const NOT_MINE:String = "not_mine";

      /** route(): the D stays in the window (this board has not reached or settled at the decision point). */
      public static const WAIT:String = "wait";

      /** route(): the D answers the open opponent decision; check its hash, then apply its choice. */
      public static const APPLY:String = "apply";

      /** The decision kind (NUR, LRES, LWEA, LBIN, LPICK, COIN). */
      public var kind:String;

      /** The asker as written on the wire: a net id, "perk" or "coin". */
      public var asker:String;

      /** DuelStateHash.SCOPE_FULL or SCOPE_SEAT for the D of this decision. */
      public var scope:int;

      /** function():void, shows the choice to the local player (local decisions only). */
      public var showFn:Function;

      /** function(choice:String):Boolean, applies a choice; false if it is not one of the options. */
      public var applyFn:Function;

      /** function():String, the choice duel autoplay makes, or null. */
      public var autoFn:Function;

      /**
       * function():String, the first option, or null: the default answer (R48: the Scoia'tael popup closed unanswered
       * answers "1" this way through the script; R53: Timed mode answers it when the time runs out).
       */
      public var firstFn:Function;

      /** True once showFn ran (only then does an answer count). */
      public var shown:Boolean = false;

      /**
       * An open decision.
       * @param kind The decision kind.
       * @param asker The asker as written on the wire.
       * @param scope The hash scope of its D.
       * @param showFn Shows the choice locally.
       * @param applyFn Applies a choice.
       * @param autoFn The autoplay choice, or null.
       * @param firstFn The first option, or null.
       */
      public function DuelDecision(kind:String, asker:String, scope:int, showFn:Function, applyFn:Function, autoFn:Function, firstFn:Function = null)
      {
         super();
         this.kind = kind;
         this.asker = asker;
         this.scope = scope;
         this.showFn = showFn;
         this.applyFn = applyFn;
         this.autoFn = autoFn;
         this.firstFn = firstFn;
      }

      /**
       * R48, R52: whether this local decision's board dialog went away unanswered. The vanilla decision dialogs have no
       * decline callback, so this only happens when a card zoom replaced the dialog and closed it: the board then shows
       * it again (the player only previewed a card). The Scoia'tael popup is the script's and answers a close itself
       * (gwentDuel.ws), so COIN never counts.
       * @param dialogShown Whether the board's choice dialog is shown now.
       * @return True once the dialog was shown for this decision and is no longer up.
       */
      public function closedUnanswered(dialogShown:Boolean) : Boolean
      {
         return this.shown && this.kind != DuelSession.COIN && !dialogShown;
      }

      /**
       * R53: the answer of a local decision whose time ran out (Timed mode): its first option, as R48 defines it.
       * @return The first option as the wire writes it, or null when the decision has none.
       */
      public function firstChoice() : String
      {
         var first:Function = this.firstFn;
         return first != null ? first() : null;
      }

      /**
       * What to do with the opponent's next message (not QUITGAME, Y, H, D MUL or M, which are routed before) while
       * decisions may be open.
       * @param message The next message in the window.
       * @param remote The open opponent decision, or null.
       * @param local The open local decision, or null.
       * @param settled Whether this board has settled (no card tween, no card FX).
       * @return NOT_MINE, WAIT, APPLY, or the detail of a desync: any other message while an opponent decision is
       * open; a D while the local player decides; a D of another kind or asker, or with a wrong argument count.
       */
      public static function route(message:DuelMessage, remote:DuelDecision, local:DuelDecision, settled:Boolean) : String
      {
         if(message.type != DuelSession.DECISION)
         {
            return remote != null ? "expected decision " + remote.kind : NOT_MINE;
         }
         if(local != null)
         {
            return "decision while local " + local.kind;
         }
         if(remote == null || !settled)
         {
            return WAIT;
         }
         if(message.args.length != 3 || message.args[0] != remote.kind || message.args[1] != remote.asker)
         {
            return "decision " + message.args.join(",") + " for " + remote.kind + "," + remote.asker;
         }
         return APPLY;
      }
   }
}
