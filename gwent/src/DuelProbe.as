package red.game.witcher3.menus.gwint
{
   import red.core.events.GameEvent;
   
   public class DuelProbe
   {
      
      public static function ping(menu:GwintGameMenu) : void
      {
         menu.dispatchEvent(new GameEvent(GameEvent.CALL,"OnDuelProbe",["probe-1"]));
      }
   }
}
