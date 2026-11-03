package red.game.witcher3.menus.gwint
{
   import flash.utils.Dictionary;

   /**
    * Receiving side of the message window (spec 8.3): the opponent's messages, applied strictly in sequence
    * order, each exactly once (gwent/tools/duelref.py Window, plus the cap below).
    * A window is tokens joined by "~", or "none". ingest ignores malformed tokens, other versions, other match
    * ids, seqs already applied or queued, and seqs more than MAX_AHEAD above the next expected one. The cap
    * keeps a hostile or broken window from growing the queue without bound; an honest window holds 20
    * messages, so it never comes near it.
    */
   public class DuelWindow
   {

      /** Separator of the tokens in a window. */
      public static const SEPARATOR:String = "~";

      /** A window without messages. */
      public static const EMPTY:String = "none";

      /** Largest distance above the next expected seq that is still queued. */
      public static const MAX_AHEAD:int = 64;

      private var _matchId:String;

      private var _nextSeq:int;

      private var _queue:Dictionary;

      private var _queued:int;

      /**
       * Starts an empty window that expects seq firstSeq.
       * @param matchId The match id this window accepts.
       * @param firstSeq The first seq it applies: 1 for the first game of a duel; a replayed game goes on from the
       * seq after the last message of the game before (sequence numbers keep counting across replays, spec 9.8).
       */
      public function DuelWindow(matchId:String, firstSeq:int = 1)
      {
         super();
         this._matchId = matchId;
         this._nextSeq = firstSeq;
         this._queue = new Dictionary();
         this._queued = 0;
      }

      /**
       * Queues every new message of this match and protocol version from a window.
       * @param window Tokens joined by "~", or "none".
       */
      public function ingest(window:String) : void
      {
         if(window == null)
         {
            return;
         }
         var tokens:Array = window.split(SEPARATOR);
         for(var i:int = 0; i < tokens.length; i++)
         {
            if(tokens[i] == EMPTY)
            {
               continue;
            }
            var m:DuelMessage = DuelCodec.decode(tokens[i]);
            if(m == null || m.version != DuelCodec.PROTOCOL_VERSION || m.matchId != this._matchId)
            {
               continue;
            }
            if(m.seq < this._nextSeq || m.seq - this._nextSeq > MAX_AHEAD || m.seq in this._queue)
            {
               continue;
            }
            this._queue[m.seq] = m;
            this._queued++;
         }
      }

      /**
       * The message with the next expected seq, left in the queue.
       * @return The message, or null if it has not arrived.
       */
      public function peek() : DuelMessage
      {
         return this._nextSeq in this._queue ? this._queue[this._nextSeq] as DuelMessage : null;
      }

      /**
       * Takes the message with the next expected seq and advances the expected seq.
       * @return The message, or null if it has not arrived (nothing changes then).
       */
      public function pop() : DuelMessage
      {
         var m:DuelMessage = this.peek();
         if(m != null)
         {
            delete this._queue[this._nextSeq];
            this._queued--;
            this._nextSeq++;
         }
         return m;
      }

      /**
       * True when the next expected message is missing while a later one is queued (a lost message).
       * Every queued seq is at least the next expected one, so this is "queue not empty, next one absent".
       */
      public function get gap() : Boolean
      {
         return this._queued > 0 && !(this._nextSeq in this._queue);
      }

      /**
       * The seq the window applies next.
       */
      public function get nextSeq() : int
      {
         return this._nextSeq;
      }
   }
}
