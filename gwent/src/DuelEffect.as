package red.game.witcher3.menus.gwint
{
   /**
    * One deferred rule effect of a duel (spec 7.4, DuelSession.deferEffect): the order key of its card (seat, then net
    * id, then the order it was queued in), the card it belongs to and the function that applies it.
    */
   public class DuelEffect
   {

      /** The seat of the card's owner (DuelIds.SEAT_A or SEAT_B), DuelDeferred.NO_SEAT without one. */
      public var seat:int;

      /** The card's net id, DuelDeferred.NO_NET_ID without one. */
      public var netId:int;

      /** Queue order among effects with the same seat and net id (the first queued runs first). */
      public var order:int;

      /** The card (or other object) the effect belongs to, for the log; null without one. */
      public var token:Object;

      /** function():void, applies the effect. */
      public var run:Function;

      /**
       * A queued effect.
       * @param seat The owner's seat, or DuelDeferred.NO_SEAT.
       * @param netId The card's net id, or DuelDeferred.NO_NET_ID.
       * @param order The queue order.
       * @param token The card it belongs to, or null.
       * @param run Applies the effect.
       */
      public function DuelEffect(seat:int, netId:int, order:int, token:Object, run:Function)
      {
         super();
         this.seat = seat;
         this.netId = netId;
         this.order = order;
         this.token = token;
         this.run = run;
      }

      /**
       * Whether this effect runs before another one: lower seat first (seat A before seat B), then lower net id, then
       * the one queued first.
       * @param other Another queued effect.
       * @return True if this one comes first.
       */
      public function before(other:DuelEffect) : Boolean
      {
         if(this.seat != other.seat)
         {
            return this.seat < other.seat;
         }
         if(this.netId != other.netId)
         {
            return this.netId < other.netId;
         }
         return this.order < other.order;
      }
   }
}
