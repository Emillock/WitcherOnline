package red.game.witcher3.menus.gwint
{
   /**
    * Seeded random numbers for duels (spec 7.3): three independent xorshift32 streams (seat A, seat B, shared)
    * derived from the match seed and the game number. Matches gwent/tools/duelref.py DuelRandom bit for bit.
    * All arithmetic is exact 32-bit: every shift is wrapped in uint(...) and the seed multiplications go
    * through mul32, because AS3 has no Math.imul and a plain uint * uint loses bits above 2^53.
    */
   public class DuelRandom
   {

      /** Stream of seat A (the host). */
      public static const STREAM_A:int = 0;

      /** Stream of seat B (the guest). */
      public static const STREAM_B:int = 1;

      /** Stream for draws that belong to neither seat (coin toss). */
      public static const STREAM_SHARED:int = 2;

      private static const STREAM_COUNT:int = 3;

      private static const STREAM_GOLDEN:uint = 0x9E3779B9;

      private static const GAME_MIX:uint = 0x85EBCA6B;

      private static const ZERO_STATE_REPLACEMENT:uint = 0x6D2B79F5;

      private static const WARM_UP_STEPS:int = 8;

      private static const TWO_POW_32:Number = 4294967296;

      private var _states:Array;

      /**
       * Derives the three stream states from the seed and the game number (both clients get the same streams).
       * @param seed The match seed.
       * @param gameNumber The game of this match (a Replay after a draw starts the next game).
       */
      public function DuelRandom(seed:uint, gameNumber:int)
      {
         super();
         this._states = [];
         for(var stream:int = 0; stream < STREAM_COUNT; stream++)
         {
            this._states.push(seedStream(seed,gameNumber,stream));
         }
      }

      /**
       * One xorshift32 step (13, 17, 5).
       * @param x The current state.
       * @return The next state.
       */
      public static function xorshift32(x:uint) : uint
      {
         x = uint(x ^ uint(x << 13));
         x = uint(x ^ (x >>> 17));
         return uint(x ^ uint(x << 5));
      }

      /**
       * Exact 32-bit multiplication (the low 32 bits of a * b), split into 16-bit halves.
       * @param a First factor.
       * @param b Second factor.
       * @return (a * b) mod 2^32.
       */
      public static function mul32(a:uint, b:uint) : uint
      {
         var aLo:uint = a & 0xFFFF;
         var aHi:uint = a >>> 16;
         var bLo:uint = b & 0xFFFF;
         var bHi:uint = b >>> 16;
         var cross:uint = uint(aHi * bLo + aLo * bHi);
         return uint(aLo * bLo + uint(cross << 16));
      }

      private static function seedStream(seed:uint, gameNumber:int, stream:int) : uint
      {
         var s:uint = uint(seed ^ mul32(uint(stream + 1),STREAM_GOLDEN) ^ mul32(uint(gameNumber),GAME_MIX));
         if(s == 0)
         {
            s = ZERO_STATE_REPLACEMENT;
         }
         for(var i:int = 0; i < WARM_UP_STEPS; i++)
         {
            s = xorshift32(s);
         }
         return s;
      }

      /**
       * Advances a stream and returns its new state.
       * @param stream STREAM_A, STREAM_B or STREAM_SHARED.
       * @return A uniformly distributed 32-bit value.
       */
      public function nextUint(stream:int) : uint
      {
         var next:uint = xorshift32(uint(this._states[stream]));
         this._states[stream] = next;
         return next;
      }

      /**
       * Draws a value in 0..n-1 by rejection sampling, so there is no modulo bias.
       * @param stream STREAM_A, STREAM_B or STREAM_SHARED.
       * @param n The number of possible results, at least 1.
       * @return A value from 0 to n - 1.
       */
      public function nextInt(stream:int, n:int) : int
      {
         if(n < 1)
         {
            throw new ArgumentError("DuelRandom.nextInt: n must be at least 1, got " + n);
         }
         var limit:Number = Math.floor(TWO_POW_32 / n) * n;
         var v:uint = this.nextUint(stream);
         while(v >= limit)
         {
            v = this.nextUint(stream);
         }
         return int(v % n);
      }
   }
}
