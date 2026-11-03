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
       */
      public function DuelDecision(kind:String, asker:String, scope:int, showFn:Function, applyFn:Function, autoFn:Function)
      {
         super();
         this.kind = kind;
         this.asker = asker;
         this.scope = scope;
         this.showFn = showFn;
         this.applyFn = applyFn;
         this.autoFn = autoFn;
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
