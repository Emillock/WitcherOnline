package red.game.witcher3.menus.gwint
{
   /**
    * Wire format of duel messages, six fields joined by ".": version.matchId.seq.type.args.hash
    * (gwent/tools/duelref.py encode and decode, bit for bit).
    *   version  decimal, 1 to 9 digits, no leading zero
    *   matchId  [0-9a-f]+ "g" [0-9]+
    *   seq      decimal, 1 to 9 digits, no leading zero
    *   type     one of TYPES
    *   args     "_" when empty, else arguments of [A-Za-z0-9]+ joined by ","
    *            (QUITGAME: exactly one, "1" if the quitter settles the bet, "0" if not;
    *            E, the end of a game: the winner as the sender sees it, A, B or N for a draw, checked by DuelEnd)
    *   hash     exactly 8 lowercase hex digits
    * Tokens never contain spaces or "~" (the window separator). Parsing is done by hand, character by
    * character, so it does not depend on RegExp support in the player.
    */
   public class DuelCodec
   {

      /** Protocol version this build sends and accepts. */
      public static const PROTOCOL_VERSION:int = 1;

      /** Every message type (spec 8.2). */
      public static const TYPES:Array = ["H","P","C","G","L","S","D","M","QUITGAME","Y","R","X","E"];

      /** The surrender type; its one argument is "1" when the quitter settles the bet (its Hello was complete). */
      public static const SURRENDER:String = "QUITGAME";

      private static const FIELD_SEPARATOR:String = ".";

      private static const ARG_SEPARATOR:String = ",";

      private static const NO_ARGS:String = "_";

      private static const FIELD_COUNT:int = 6;

      private static const MAX_NUMBER_DIGITS:int = 9;

      private static const HASH_DIGITS:int = 8;

      private static const HEX_DIGITS:String = "0123456789abcdef";

      /**
       * Writes a message as one token.
       * @param m The message.
       * @return The token.
       * @throws ArgumentError If the message would not decode back (bad match id, type, argument or number).
       */
      public static function encode(m:DuelMessage) : String
      {
         var args:String = m.args != null && m.args.length > 0 ? m.args.join(ARG_SEPARATOR) : NO_ARGS;
         var token:String = [String(m.version),m.matchId,String(m.seq),m.type,args,hex8(m.hash)].join(FIELD_SEPARATOR);
         if(decode(token) == null)
         {
            throw new ArgumentError("DuelCodec.encode: message does not encode to a valid token: " + token);
         }
         return token;
      }

      /**
       * Reads one token.
       * @param token A wire token.
       * @return The message, or null if the token is outside the grammar.
       */
      public static function decode(token:String) : DuelMessage
      {
         if(token == null)
         {
            return null;
         }
         var fields:Array = token.split(FIELD_SEPARATOR);
         if(fields.length != FIELD_COUNT)
         {
            return null;
         }
         var version:int = parseNumber(fields[0]);
         var seq:int = parseNumber(fields[2]);
         var type:String = fields[3];
         if(version < 0 || seq < 0 || !isMatchId(fields[1]) || TYPES.indexOf(type) < 0 || !isHash(fields[5]))
         {
            return null;
         }
         var args:Array = [];
         if(fields[4] != NO_ARGS)
         {
            args = String(fields[4]).split(ARG_SEPARATOR);
            for(var i:int = 0; i < args.length; i++)
            {
               if(!isArg(args[i]))
               {
                  return null;
               }
            }
         }
         if(type == SURRENDER && (args.length != 1 || args[0] != "0" && args[0] != "1"))
         {
            return null;
         }
         return new DuelMessage(version,fields[1],seq,type,args,uint(parseInt(fields[5],16)));
      }

      /**
       * Writes a uint as exactly 8 lowercase hex digits.
       * @param value The value.
       * @return For example "0badf00d".
       */
      public static function hex8(value:uint) : String
      {
         var text:String = value.toString(16);
         while(text.length < HASH_DIGITS)
         {
            text = "0" + text;
         }
         return text;
      }

      private static function isDigit(code:Number) : Boolean
      {
         return code >= 48 && code <= 57;
      }

      private static function isHexDigit(c:String) : Boolean
      {
         return c.length == 1 && HEX_DIGITS.indexOf(c) >= 0;
      }

      /** A positive decimal of 1 to 9 digits without a leading zero as an int, or -1. */
      private static function parseNumber(text:String) : int
      {
         if(text.length < 1 || text.length > MAX_NUMBER_DIGITS || text.charAt(0) == "0")
         {
            return -1;
         }
         var value:int = 0;
         for(var i:int = 0; i < text.length; i++)
         {
            var code:Number = text.charCodeAt(i);
            if(!isDigit(code))
            {
               return -1;
            }
            value = value * 10 + (code - 48);
         }
         return value;
      }

      /** [0-9a-f]+ "g" [0-9]+ */
      private static function isMatchId(text:String) : Boolean
      {
         var g:int = text.indexOf("g");
         if(g < 1 || g == text.length - 1)
         {
            return false;
         }
         for(var i:int = 0; i < g; i++)
         {
            if(!isHexDigit(text.charAt(i)))
            {
               return false;
            }
         }
         for(var j:int = g + 1; j < text.length; j++)
         {
            if(!isDigit(text.charCodeAt(j)))
            {
               return false;
            }
         }
         return true;
      }

      /** Exactly 8 lowercase hex digits. */
      private static function isHash(text:String) : Boolean
      {
         if(text.length != HASH_DIGITS)
         {
            return false;
         }
         for(var i:int = 0; i < text.length; i++)
         {
            if(!isHexDigit(text.charAt(i)))
            {
               return false;
            }
         }
         return true;
      }

      /** [A-Za-z0-9]+ */
      private static function isArg(text:String) : Boolean
      {
         if(text.length < 1)
         {
            return false;
         }
         for(var i:int = 0; i < text.length; i++)
         {
            var code:Number = text.charCodeAt(i);
            if(!isDigit(code) && !(code >= 65 && code <= 90) && !(code >= 97 && code <= 122))
            {
               return false;
            }
         }
         return true;
      }
   }
}
