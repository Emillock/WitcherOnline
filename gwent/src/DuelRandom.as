package red.game.witcher3.menus.gwint
{
   /**
    * Seeded random numbers for duels (spec 7.3): three independent xorshift32 streams (seat A, seat B, shared)
    * derived from the match seed and the game number. Matches gwent/tools/duelref.py DuelRandom bit for bit.
    * All arithmetic is exact 32-bit: every shift is wrapped in uint(...) and the seed multiplications go
    * through mul32, because AS3 has no Math.imul and a plain uint * uint loses bits above 2^53.
    *
    * Rules code draws through DuelSession.randomInt(ownerPlayer, n): the stream of the owner's seat in a duel, the
    * vanilla Math.random expression outside duels. Only the coin toss takes STREAM_SHARED directly.
    *
    * Math.random audit (spec 7.3): every call in the decompiled vanilla 5.01 board (FFDec 26.4.0, 37 calls on 33
    * lines in 8 files), file:line in that output (in red/game/witcher3/menus/gwint, or in
    * red/game/witcher3/<folder> where a folder is given).
    *
    * Stream (changes which card goes where or who acts):
    * - GwintDeck.as:169 shuffleDeck: owner of the deck (CardManager.shuffleAndDrawCards passes PLAYER_1 / PLAYER_2).
    * - GwintDeck.as:206 readdCard with random: owner of the deck (shuffleGraveyards passes the graveyard's player;
    *   the leader ability CardEffect_GraveyardShuffle).
    * - CardManager.as:555 chooseCreatureToExclude (Monsters perk, from clearBoard): owner of the creatures.
    * - CardManager.as:874 stealCards: the seat stolen from (no caller in the 5.01 board).
    * - CardManager.as:1374 ressurectFromGraveyard (Skellige perk in round 3): owner of the graveyard.
    * - CardInstance.as:1357 random medic (randomResEnabled, a leader with CardEffect_RandomRessurect): owner of the
    *   medic.
    * - CardLeaderInstance.as:611 resurrectGraveyard, random pick (randomResEnabled): owner of the leader.
    * - GwintGameFlowController.as:298 coin toss without Scoia'tael: STREAM_SHARED in a duel (the duel branch comes
    *   before the tutorials check; the vanilla line stays for single-player; the Scoia'tael choice is a Decision,
    *   Task 12).
    * - Medic placement (CardInstance.onNurseEffectEnded) used recalculatePowerPotential, whose agile tie is
    *   CardInstance.as:334 / 340. In a duel CardInstance.duelPlaceResurrected places the card instead: the same row
    *   rule, seat-relative, with a tie drawn from the medic owner's stream. Lines 334 / 340 stay local (below).
    * - Not a draw, but it decides the draw count: the Monsters perk message check in
    *   GwintGameFlowController.state_begin_ClearingBoard called chooseCreatureToExclude (a draw) for PLAYER_1 and
    *   then maybe for PLAYER_2, so the count depended on local player order. In a duel it calls
    *   CardManager.hasCreatureToExclude (no draw); the only Monsters draws are clearBoard's, one per Monsters seat.
    *
    * Local only:
    * - managers/InputManager.as:103: an id for a trace line, because it never reaches the board state.
    * - AIPlayerController.as:383, 397, 428, 439 (2), 447, 449, 469, 482, 484, 493, 497, 501, 505, 663: AI move
    *   choice, because no seat is an AIPlayerController in a duel; the test bots' autoplay helper only picks the
    *   local move, which is then sent, so the other board applies the move, never the draw.
    * - CardInstance.as:334, 340, 591, 789 (2), 818 (2), 868 (2) in recalculatePowerPotential: AI evaluation
    *   (powerPotential and the AI's preferred row), because those fields are excluded from the hash and the function
    *   runs a different number of times on each client; its one rules use is replaced in duels (above).
    * - CardLeaderInstance.as:170, 186 in recalculatePowerPotential: leader strategic value, because it is AI only.
    * - CardLeaderInstance.as:583 ShowEnemyHand: which enemy hand cards the dialog shows, because it only displays
    *   them (no state change), and hand order differs between clients, so a stream would not agree either.
    * - utils/Math2.as:171 randomInt: no caller in the board.
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
