package red.game.witcher3.menus.gwint
{
   /**
    * The logical game state as one DuelHash value (spec 8.4), the same on both clients when their boards agree.
    * Everything is fed in seat order (seat A, then seat B), never in local player order, and cards are named by
    * net id, so the hash does not depend on which seat is local. Excluded: animation and UI state, AI evaluation
    * fields (powerPotential and the like), instance ids, hand order (only PLAYER_1's hand is sorted, spec 5).
    *
    * Field order, SCOPE_FULL (each item is one or more DuelHash.addInt words):
    *  1. SCOPE_FULL (0)
    *  2. rounds played (count of round results with a result)
    *  3. for each of the three round results: played (1/0), score of seat A, score of seat B, winner seat (-1 none)
    *  4. for seat A, then seat B:
    *     a. current score
    *     b. passed (1 when the seat's controller is ROUND_PLAYER_STATUS_DONE, else 0; 0 before the leaders exist)
    *     c. leader: present (1/0), then if present: net id, template id, ability already used (1/0)
    *     d. deck: card count, then each template id in deck order (decks hold template ids, not instances)
    *     e. hand as a set: card count, then the cards sorted by net id
    *     f. graveyard, siege row, ranged row, melee row, siege modifiers, ranged modifiers, melee modifiers, each in
    *        list order: card count, then the cards
    *  5. weather slot in list order: card count, then the cards
    *  6. -1 (end marker)
    * Each card: net id, template id, list id, seat of the list it is in (-1 none), owning seat, current power
    * (getTotalPower on the three rows, the template's power anywhere else).
    *
    * SCOPE_SEAT (mulligan and coin toss messages, spec 8.4), for the given seat only:
    *  1. SCOPE_SEAT (1), 2. the seat, 3. deck (as 4d), 4. hand as a set (as 4e), 5. the seat's mulligan count
    *  (DuelSession.mulligans), 6. -1.
    */
   public class DuelStateHash
   {

      /** The whole state: moves and decisions inside moves. */
      public static const SCOPE_FULL:int = 0;

      /** One seat's own state: mulligan and coin-toss messages. */
      public static const SCOPE_SEAT:int = 1;

      private static const END_MARKER:int = -1;

      private static const ORDERED_LISTS:Array = [CardManager.CARD_LIST_LOC_GRAVEYARD,CardManager.CARD_LIST_LOC_SEIGE,CardManager.CARD_LIST_LOC_RANGED,CardManager.CARD_LIST_LOC_MELEE,CardManager.CARD_LIST_LOC_SEIGEMODIFIERS,CardManager.CARD_LIST_LOC_RANGEDMODIFIERS,CardManager.CARD_LIST_LOC_MELEEMODIFIERS];

      /**
       * Hashes the current board of the active duel.
       * @param scope SCOPE_FULL or SCOPE_SEAT.
       * @param seat The seat for SCOPE_SEAT (ignored for SCOPE_FULL).
       * @return The hash, 0 outside a duel.
       */
      public static function compute(scope:int, seat:int) : uint
      {
         var session:DuelSession = DuelSession.active;
         var manager:CardManager = CardManager.getInstance();
         if(session == null || manager == null)
         {
            return 0;
         }
         var h:DuelHash = new DuelHash();
         h.addInt(scope);
         if(scope == SCOPE_SEAT)
         {
            h.addInt(seat);
            addDeck(h,manager,session.playerOf(seat));
            addHand(h,manager,session,session.playerOf(seat));
            h.addInt(session.mulligans(seat));
            h.addInt(END_MARKER);
            return h.value();
         }
         addRounds(h,manager,session);
         for(var s:int = DuelIds.SEAT_A; s <= DuelIds.SEAT_B; s++)
         {
            var player:int = session.playerOf(s);
            h.addInt(manager.currentPlayerScores[player]);
            h.addInt(passed(manager,player) ? 1 : 0);
            addLeader(h,manager,session,player);
            addDeck(h,manager,player);
            addHand(h,manager,session,player);
            for(var l:int = 0; l < ORDERED_LISTS.length; l++)
            {
               addList(h,manager.getCardInstanceList(ORDERED_LISTS[l],player),session);
            }
         }
         addList(h,manager.getCardInstanceList(CardManager.CARD_LIST_LOC_WEATHERSLOT,CardManager.PLAYER_INVALID),session);
         h.addInt(END_MARKER);
         return h.value();
      }

      private static function addRounds(h:DuelHash, manager:CardManager, session:DuelSession) : void
      {
         var played:int = 0;
         var i:int;
         for(i = 0; i < manager.roundResults.length; i++)
         {
            if(manager.roundResults[i].played)
            {
               played++;
            }
         }
         h.addInt(played);
         for(i = 0; i < manager.roundResults.length; i++)
         {
            var result:GwintRoundResult = manager.roundResults[i];
            h.addInt(result.played ? 1 : 0);
            h.addInt(result.getPlayerScore(session.playerOf(DuelIds.SEAT_A)));
            h.addInt(result.getPlayerScore(session.playerOf(DuelIds.SEAT_B)));
            h.addInt(session.seatOf(result.played ? result.winningPlayer : CardManager.PLAYER_INVALID));
         }
      }

      private static function passed(manager:CardManager, player:int) : Boolean
      {
         var flow:GwintGameFlowController = GwintGameFlowController.getInstance();
         if(flow == null || manager.getCardLeader(player) == null)
         {
            return false;
         }
         var controller:BasePlayerController = flow.playerControllers[player];
         return controller != null && controller.currentRoundStatus == BasePlayerController.ROUND_PLAYER_STATUS_DONE;
      }

      private static function addLeader(h:DuelHash, manager:CardManager, session:DuelSession, player:int) : void
      {
         var leader:CardLeaderInstance = manager.getCardLeader(player);
         if(leader == null)
         {
            h.addInt(0);
            return;
         }
         h.addInt(1);
         h.addInt(session.ids.toNet(leader.instanceId));
         h.addInt(leader.templateId);
         h.addInt(leader.hasBeenUsed ? 1 : 0);
      }

      private static function addDeck(h:DuelHash, manager:CardManager, player:int) : void
      {
         var deck:GwintDeck = manager.playerDeckDefinitions[player];
         var cards:Vector.<int> = deck != null ? deck.cardIndicesInDeck : null;
         if(cards == null)
         {
            h.addInt(0);
            return;
         }
         h.addInt(cards.length);
         for(var i:int = 0; i < cards.length; i++)
         {
            h.addInt(cards[i]);
         }
      }

      private static function addHand(h:DuelHash, manager:CardManager, session:DuelSession, player:int) : void
      {
         var hand:Vector.<CardInstance> = manager.getCardInstanceList(CardManager.CARD_LIST_LOC_HAND,player);
         var sorted:Array = [];
         var byNet:Object = {};
         var i:int;
         for(i = 0; i < hand.length; i++)
         {
            var netId:int = session.ids.toNet(hand[i].instanceId);
            sorted.push(netId);
            byNet[netId] = hand[i];
         }
         sorted.sort(Array.NUMERIC);
         h.addInt(sorted.length);
         for(i = 0; i < sorted.length; i++)
         {
            addCard(h,byNet[sorted[i]] as CardInstance,session);
         }
      }

      private static function addList(h:DuelHash, list:Vector.<CardInstance>, session:DuelSession) : void
      {
         if(list == null)
         {
            h.addInt(0);
            return;
         }
         h.addInt(list.length);
         for(var i:int = 0; i < list.length; i++)
         {
            addCard(h,list[i],session);
         }
      }

      private static function addCard(h:DuelHash, card:CardInstance, session:DuelSession) : void
      {
         h.addInt(session.ids.toNet(card.instanceId));
         h.addInt(card.templateId);
         h.addInt(card.inList);
         h.addInt(session.seatOf(card.listsPlayer));
         h.addInt(session.seatOf(card.owningPlayer));
         h.addInt(power(card));
      }

      private static function power(card:CardInstance) : int
      {
         if(card.inList == CardManager.CARD_LIST_LOC_SEIGE || card.inList == CardManager.CARD_LIST_LOC_RANGED || card.inList == CardManager.CARD_LIST_LOC_MELEE)
         {
            return card.getTotalPower();
         }
         return card.templateRef != null ? card.templateRef.power : 0;
      }
   }
}
