package red.game.witcher3.menus.gwint
{
   /**
    * One duel message (spec 8.1): what DuelCodec writes to and reads from a wire token.
    */
   public class DuelMessage
   {

      /** Protocol version of the sender. */
      public var version:int;

      /** Match id: the seed as lowercase hex, "g", the game number (for example "1a2b3c4dg2"). */
      public var matchId:String;

      /** Sender's sequence number, from 1. */
      public var seq:int;

      /** Message type, one of DuelCodec.TYPES. */
      public var type:String;

      /** Arguments as strings, each of [A-Za-z0-9]+. */
      public var args:Array;

      /** DuelStateHash of the sender's state when it created the message. */
      public var hash:uint;

      /**
       * Builds a message.
       * @param version Protocol version.
       * @param matchId Match id.
       * @param seq Sequence number.
       * @param type Message type.
       * @param args Arguments (null means none).
       * @param hash Sender's state hash.
       */
      public function DuelMessage(version:int = 0, matchId:String = "", seq:int = 0, type:String = "", args:Array = null, hash:uint = 0)
      {
         super();
         this.version = version;
         this.matchId = matchId;
         this.seq = seq;
         this.type = type;
         this.args = args != null ? args : [];
         this.hash = hash;
      }

      /**
       * Builds the match id for a seed and game number.
       * @param seed The match seed.
       * @param gameNumber The game of this match.
       * @return For example "1a2b3c4dg2".
       */
      public static function matchIdFor(seed:uint, gameNumber:int) : String
      {
         return seed.toString(16) + "g" + gameNumber;
      }
   }
}
