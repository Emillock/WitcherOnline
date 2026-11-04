package red.game.witcher3.menus.gwint
{
   import flash.display.DisplayObject;
   import flash.display.DisplayObjectContainer;
   import flash.display.Sprite;
   import flash.geom.Rectangle;
   import flash.text.TextField;
   import red.game.witcher3.utils.CommonUtils;

   /**
    * The countdown of Timed mode (spec 15: drawn in code, no copied art): a dark disc with a ring that empties as the
    * time runs out and the seconds left in its middle, placed next to the renderer of the player whose time runs (the
    * local GwintPlayerRenderer for the local clock, the opponent's for its turn). Display only: DuelSession decides
    * when it shows and what (R54); it has no clock or timer of its own and redraws only when the second changes.
    */
   public class DuelTimerView extends Sprite
   {

      /** Diameter of the disc in pixels. */
      public static const SIZE:int = 64;

      /** Space between the player's renderer and the disc. */
      public static const GAP:int = 12;

      /** Under this many milliseconds left the ring and the seconds turn red. */
      public static const LOW_MS:int = 10000;

      private static const RING_WIDTH:int = 5;

      private static const RING_SEGMENTS:int = 60;

      private static const COLOR_BACK:uint = 0x000000;

      private static const COLOR_TRACK:uint = 0x3C3C3C;

      private static const COLOR_TIME:uint = 0xE6D2A0;

      private static const COLOR_LOW:uint = 0xD23C28;

      private var _ring:Sprite;

      private var _seconds:TextField;

      private var _shownSeconds:int = -1;

      /**
       * A hidden view; show() places and fills it.
       */
      public function DuelTimerView()
      {
         super();
         this.mouseEnabled = false;
         this.mouseChildren = false;
         this.graphics.beginFill(COLOR_BACK,0.7);
         this.graphics.drawCircle(SIZE / 2,SIZE / 2,SIZE / 2);
         this.graphics.endFill();
         this._ring = new Sprite();
         addChild(this._ring);
         this._seconds = CommonUtils.spawnTextField(26,COLOR_TIME);
         this._seconds.selectable = false;
         this._seconds.width = SIZE;
         this._seconds.height = 34;
         this._seconds.y = (SIZE - this._seconds.height) / 2;
         addChild(this._seconds);
         this.visible = false;
      }

      /**
       * Shows the time left next to a player's renderer.
       * @param layer The container the view lives in (the Gwent menu).
       * @param anchor The GwintPlayerRenderer of the player whose time runs.
       * @param remainingMs Milliseconds left (DuelClock.remainingMs).
       */
      public function show(layer:DisplayObjectContainer, anchor:DisplayObject, remainingMs:int) : void
      {
         if(layer == null || anchor == null)
         {
            return;
         }
         if(this.parent != layer)
         {
            layer.addChild(this);
         }
         this.place(layer,anchor);
         var seconds:int = int(Math.ceil(remainingMs / 1000));
         if(seconds != this._shownSeconds)
         {
            this._shownSeconds = seconds;
            this.draw(remainingMs);
         }
         this.visible = true;
      }

      /**
       * Hides the view (no stretch runs, or the duel ended).
       */
      public function hide() : void
      {
         this.visible = false;
         this._shownSeconds = -1;
      }

      /** To the right of the renderer, centred on its height (on every show, so it follows the renderer). */
      private function place(layer:DisplayObjectContainer, anchor:DisplayObject) : void
      {
         var bounds:Rectangle = anchor.getBounds(layer);
         this.x = Math.round(bounds.right + GAP);
         this.y = Math.round(bounds.top + (bounds.height - SIZE) / 2);
      }

      /** The ring (a full grey track, the time left over it from twelve o'clock clockwise) and the seconds. */
      private function draw(remainingMs:int) : void
      {
         var color:uint = remainingMs < LOW_MS ? COLOR_LOW : COLOR_TIME;
         var radius:Number = SIZE / 2 - RING_WIDTH;
         var centre:Number = SIZE / 2;
         var part:Number = Math.max(0,Math.min(1,remainingMs / DuelWait.TURN_MS));
         var steps:int = int(Math.ceil(RING_SEGMENTS * part));
         this._ring.graphics.clear();
         this._ring.graphics.lineStyle(RING_WIDTH,COLOR_TRACK);
         this._ring.graphics.drawCircle(centre,centre,radius);
         if(steps > 0)
         {
            this._ring.graphics.lineStyle(RING_WIDTH,color);
            this._ring.graphics.moveTo(centre,centre - radius);
            for(var i:int = 1; i <= steps; i++)
            {
               var angle:Number = -Math.PI / 2 + 2 * Math.PI * part * i / steps;
               this._ring.graphics.lineTo(centre + radius * Math.cos(angle),centre + radius * Math.sin(angle));
            }
         }
         this._seconds.text = String(Math.max(0,this._shownSeconds));
         this._seconds.textColor = color;
      }
   }
}
