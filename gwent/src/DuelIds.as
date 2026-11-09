package red.game.witcher3.menus.gwint
{
   import flash.utils.Dictionary;

   /**
    * Net ids of card instances (spec 7.2): the seat a card was spawned for plus a per-seat counter starting at 1,
    * netId = seat * 65536 + ordinal, written "A17" or "B3" on the wire. Keeps both maps, net id to local
    * instance id and back. Each seat's spawns happen in the same order on both clients, so the ids agree.
    */
   public class DuelIds
   {

      /** Seat of the host. */
      public static const SEAT_A:int = 0;

      /** Seat of the guest. */
      public static const SEAT_B:int = 1;

      /** Ordinals per seat; netId = seat * SEAT_STRIDE + ordinal. */
      public static const SEAT_STRIDE:int = 65536;

      private static const MAX_ORDINAL:int = 65535;

      private static const SEAT_LETTERS:String = "AB";

      private var _counters:Array;

      private var _toLocal:Dictionary;

      private var _toNet:Dictionary;

      /**
       * Starts with no ids and both counters at 0.
       */
      public function DuelIds()
      {
         super();
         this.reset();
      }

      /**
       * Gives a newly spawned instance the next net id of its seat. An instance that already had one loses it.
       * @param seat SEAT_A or SEAT_B, the seat the card was spawned for.
       * @param instanceId The local card instance id.
       * @return The net id (seat * 65536 + ordinal, ordinals from 1).
       */
      public function assign(seat:int, instanceId:int) : int
      {
         if(seat != SEAT_A && seat != SEAT_B)
         {
            throw new ArgumentError("DuelIds.assign: bad seat " + seat);
         }
         if(this._counters[seat] >= MAX_ORDINAL)
         {
            throw new RangeError("DuelIds.assign: seat " + seat + " ran out of net ids");
         }
         this.forget(instanceId);
         this._counters[seat] = this._counters[seat] + 1;
         var netId:int = seat * SEAT_STRIDE + int(this._counters[seat]);
         this._toLocal[netId] = instanceId;
         this._toNet[instanceId] = netId;
         return netId;
      }

      /**
       * Looks up the local instance of a net id.
       * @param netId A net id.
       * @return The local instance id, or -1 if the net id is unknown.
       */
      public function toLocal(netId:int) : int
      {
         return netId in this._toLocal ? int(this._toLocal[netId]) : -1;
      }

      /**
       * Looks up the net id of a local instance.
       * @param instanceId A local card instance id.
       * @return The net id, or -1 if the instance has none.
       */
      public function toNet(instanceId:int) : int
      {
         return instanceId in this._toNet ? int(this._toNet[instanceId]) : -1;
      }

      /**
       * Drops the ids of a deleted instance (its net id is never reused).
       * @param instanceId A local card instance id.
       */
      public function forget(instanceId:int) : void
      {
         if(instanceId in this._toNet)
         {
            delete this._toLocal[this._toNet[instanceId]];
            delete this._toNet[instanceId];
         }
      }

      /**
       * Drops every id and restarts both counters (a new match or game).
       */
      public function reset() : void
      {
         this._counters = [0,0];
         this._toLocal = new Dictionary();
         this._toNet = new Dictionary();
      }

      /**
       * Writes a net id the way messages carry it.
       * @param netId A net id (seat A or B, ordinal 1 to 65535); anything else throws an ArgumentError.
       * @return "A17" for seat A ordinal 17, "B3" for seat B ordinal 3.
       */
      public static function format(netId:int) : String
      {
         var seat:int = netId >> 16;
         var ordinal:int = netId & 0xFFFF;
         if(netId < 0 || seat > SEAT_B || ordinal == 0)
         {
            throw new ArgumentError("DuelIds.format: bad net id " + netId);
         }
         return SEAT_LETTERS.charAt(seat) + String(ordinal);
      }

      /**
       * Reads a net id written by format.
       * @param s Text such as "A17": seat letter A or B, then the ordinal 1 to 65535 without leading zeros.
       * @return The net id, or -1 if s is malformed.
       */
      public static function parse(s:String) : int
      {
         if(s == null || s.length < 2 || s.length > 6)
         {
            return -1;
         }
         var seat:int = SEAT_LETTERS.indexOf(s.charAt(0));
         if(seat < 0 || s.charAt(1) == "0")
         {
            return -1;
         }
         var ordinal:int = 0;
         for(var i:int = 1; i < s.length; i++)
         {
            var code:Number = s.charCodeAt(i);
            if(code < 48 || code > 57)
            {
               return -1;
            }
            ordinal = ordinal * 10 + (code - 48);
         }
         return ordinal > MAX_ORDINAL ? -1 : seat * SEAT_STRIDE + ordinal;
      }
   }
}
