package red.game.witcher3.menus.gwint
{
   /**
    * FNV-1a accumulator over 32-bit words (each fed as 4 little-endian bytes of its uint form), the core of the
    * duel state hash. Matches gwent/tools/duelref.py hash_words bit for bit. The FNV prime 16777619 is
    * 2^24 + 403, so h * prime is computed exactly as uint(h << 24) + h * 403 (h * 403 stays below 2^41).
    */
   public class DuelHash
   {

      private static const FNV_OFFSET:uint = 0x811C9DC5;

      private var _h:uint;

      /**
       * Starts an empty hash (the FNV offset basis).
       */
      public function DuelHash()
      {
         super();
         this._h = FNV_OFFSET;
      }

      /**
       * Feeds one word.
       * @param v The word; a negative value is hashed as its uint (two's complement) form.
       */
      public function addInt(v:int) : void
      {
         var w:uint = uint(v);
         var h:uint = this._h;
         for(var shift:int = 0; shift < 32; shift += 8)
         {
            h = uint(h ^ ((w >>> shift) & 0xFF));
            h = uint(uint(h << 24) + h * 403);
         }
         this._h = h;
      }

      /**
       * The hash of every word fed so far.
       * @return The current hash value.
       */
      public function value() : uint
      {
         return this._h;
      }
   }
}
