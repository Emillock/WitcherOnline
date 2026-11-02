package red.game.witcher3.menus.gwint
{
   import red.core.events.GameEvent;
   
   /**
    * Build pipeline probe: proves that a class we add and a patched CDPR class compile and run together.
    */
   public class DuelProbe
   {
      
      /**
       * Tells the game script that the board loaded, by dispatching a CALL event "OnDuelProbe".
       * @param menu The Gwent menu that dispatches the event.
       */
      public static function ping(menu:GwintGameMenu) : void
      {
         menu.dispatchEvent(new GameEvent(GameEvent.CALL,"OnDuelProbe",["probe-1"]));
      }
   }
}
