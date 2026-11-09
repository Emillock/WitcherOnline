package red.game.witcher3.menus.gwint
{
   /**
    * The queue of deferred rule effects of a duel game (spec 7.4, DuelSession.deferEffect), in canonical order: seat A
    * before seat B, then by net id, then in the order queued. Board-independent, so DuelSelfTest can feed it effects in
    * any order. Several effects of one card run in the order they were queued.
    */
   public class DuelDeferred
   {

      /** Seat key of an effect whose card has no seat: after seat B. */
      public static const NO_SEAT:int = 2;

      /** Net id key of an effect whose card has no net id: after every net id. */
      public static const NO_NET_ID:int = 2147483647;

      private var _effects:Array;

      private var _queued:int;

      /**
       * An empty queue.
       */
      public function DuelDeferred()
      {
         super();
         this._effects = [];
         this._queued = 0;
      }

      /**
       * Queues an effect.
       * @param seat The seat of the card's owner, or NO_SEAT.
       * @param netId The card's net id, or NO_NET_ID.
       * @param token The card the effect belongs to (for the log), or null.
       * @param run function():void, applies the effect.
       */
      public function add(seat:int, netId:int, token:Object, run:Function) : void
      {
         this._effects.push(new DuelEffect(seat,netId,this._queued++,token,run));
      }

      /**
       * True while an effect is queued.
       */
      public function get pending() : Boolean
      {
         return this._effects.length > 0;
      }

      /**
       * How many effects are queued.
       */
      public function get count() : int
      {
         return this._effects.length;
      }

      /**
       * Takes the effect that runs next (canonical order) off the queue.
       * @return The effect, or null when nothing is queued.
       */
      public function takeNext() : DuelEffect
      {
         if(this._effects.length == 0)
         {
            return null;
         }
         var best:int = 0;
         for(var i:int = 1; i < this._effects.length; i++)
         {
            if((this._effects[i] as DuelEffect).before(this._effects[best] as DuelEffect))
            {
               best = i;
            }
         }
         return this._effects.splice(best,1)[0] as DuelEffect;
      }

      /**
       * Whether a deferred FX-end effect (scorch, morph) still applies to its card: the card still exists and is on a
       * unit row. Two scorchers that land together (both seats' pirates from the Skellige round 3 perk) target the same
       * cards twice; the second graveyard move must skip a card the first one already took. This differs from vanilla
       * on purpose: vanilla sends such a card to the graveyard twice (reordering the graveyard, a scorched cow spawning
       * two Chorts) and throws on a second banish, which would stall both boards inside the queue.
       * @param listId The card's current list (CardManager.CARD_LIST_LOC_*).
       * @param exists Whether CardManager still knows the card instance.
       * @return True if the effect runs.
       */
      public static function stillOnBoard(listId:int, exists:Boolean) : Boolean
      {
         return exists && (listId == CardManager.CARD_LIST_LOC_SEIGE || listId == CardManager.CARD_LIST_LOC_RANGED || listId == CardManager.CARD_LIST_LOC_MELEE);
      }

      /**
       * Drops every queued effect (the game ended: nothing may carry over into the next one).
       */
      public function clear() : void
      {
         this._effects.length = 0;
      }
   }
}
