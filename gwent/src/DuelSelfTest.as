package red.game.witcher3.menus.gwint
{
   import flash.events.TimerEvent;
   import flash.utils.Timer;

   /**
    * In-game self-test of the board-independent duel classes: replays every vector of DuelVectors (generated
    * from the Python reference) through DuelRandom, DuelHash, DuelCodec and DuelWindow, plus hand-written checks
    * of DuelIds, the window cap, the error paths, and the routing of synthetic D and M messages (DuelDecision.route,
    * DuelMulligan.route), the order of deferred effects and the double scorch guard (DuelDeferred), and the end of a
    * game (DuelEnd.route: confirmation, replay, leave and the stuck-wait timers). Runs only when
    * the script sets gwint.game.debug.selfTest (the w3test bot does, a normal player never), and reports
    * "DUEL SELFTEST pass=n fail=m" and one "DUEL SELFTEST FAIL ..." line per failure (at most MAX_REPORTED_FAILURES).
    */
   public class DuelSelfTest
   {

      /** Most failure lines report sends (the count in the summary line is always complete). */
      public static const MAX_REPORTED_FAILURES:int = 20;

      /** Prefix of every line the self-test logs. */
      public static const PREFIX:String = "DUEL SELFTEST";

      private static var _checks:int = 0;

      private static var _timer:Timer;

      private var _count:int = 0;

      private var _failures:Array;

      /**
       * Creates an empty test run; use the static run().
       */
      public function DuelSelfTest()
      {
         super();
         this._failures = [];
      }

      /**
       * Runs every check.
       * @return The failure messages, empty when everything passed.
       */
      public static function run() : Array
      {
         var test:DuelSelfTest = new DuelSelfTest();
         test.guard("random",test.checkRandom);
         test.guard("hash",test.checkHash);
         test.guard("codec",test.checkCodec);
         test.guard("window",test.checkWindow);
         test.guard("ids",test.checkIds);
         test.guard("edges",test.checkEdges);
         test.guard("decisions",test.checkDecisions);
         test.guard("deferred",test.checkDeferred);
         test.guard("end",test.checkEnd);
         _checks = test._count;
         return test._failures;
      }

      /**
       * Number of checks the last run() made (passed and failed).
       */
      public static function get checks() : int
      {
         return _checks;
      }

      /**
       * The lines that report one run: the summary, then the first MAX_REPORTED_FAILURES failures.
       * @param failures What run() returned.
       * @param checks How many checks run() made.
       * @return The log lines.
       */
      public static function reportLines(failures:Array, checks:int) : Array
      {
         var lines:Array = [PREFIX + " pass=" + (checks - failures.length) + " fail=" + failures.length];
         for(var i:int = 0; i < failures.length && i < MAX_REPORTED_FAILURES; i++)
         {
            lines.push(PREFIX + " FAIL " + failures[i]);
         }
         if(failures.length > MAX_REPORTED_FAILURES)
         {
            lines.push(PREFIX + " FAIL (" + (failures.length - MAX_REPORTED_FAILURES) + " more not listed)");
         }
         return lines;
      }

      /**
       * Runs the self-test on the next timer tick (outside the script call that turned it on) and passes each
       * report line to log.
       * @param log function(line:String):void, for example a call of the script event OnDuelLog.
       */
      public static function start(log:Function) : void
      {
         if(_timer != null)
         {
            return;
         }
         _timer = new Timer(1,1);
         _timer.addEventListener(TimerEvent.TIMER_COMPLETE,function(event:TimerEvent):void
         {
            var lines:Array = reportLines(run(),_checks);
            for(var i:int = 0; i < lines.length; i++)
            {
               log(lines[i]);
            }
            _timer = null;
         });
         _timer.start();
      }

      /** Runs one group of checks; an exception becomes a failure instead of ending the run. */
      private function guard(group:String, body:Function) : void
      {
         try
         {
            body();
         }
         catch(error:Error)
         {
            this.expect(false,group + " threw " + error.name + ": " + error.message);
         }
      }

      /** Counts one check and records message when it failed. */
      private function expect(ok:Boolean, message:String) : void
      {
         this._count++;
         if(!ok)
         {
            this._failures.push(message);
         }
      }

      private function checkRandom() : void
      {
         var rows:Array = DuelVectors.RANDOM;
         for(var r:int = 0; r < rows.length; r++)
         {
            var row:Array = rows[r];
            var rng:DuelRandom = new DuelRandom(uint(row[0]),int(row[1]));
            var stream:int = int(row[2]);
            var n:int = int(row[3]);
            var mismatch:String = null;
            for(var k:int = 0; k < 8 && mismatch == null; k++)
            {
               var got:Number = n == 0 ? Number(rng.nextUint(stream)) : Number(rng.nextInt(stream,n));
               if(got != Number(row[4 + k]))
               {
                  mismatch = "draw " + (k + 1) + " got " + got + " want " + row[4 + k];
               }
            }
            this.expect(mismatch == null,"random row " + r + " (seed " + row[0] + " game " + row[1] + " stream " + stream + " n " + n + "): " + mismatch);
         }
      }

      private function checkHash() : void
      {
         var rows:Array = DuelVectors.HASH;
         for(var r:int = 0; r < rows.length; r++)
         {
            var row:Array = rows[r];
            var h:DuelHash = new DuelHash();
            for(var i:int = 1; i < row.length; i++)
            {
               h.addInt(int(row[i]));
            }
            this.expect(h.value() == uint(row[0]),"hash row " + r + " (" + (row.length - 1) + " words): got " + h.value() + " want " + row[0]);
         }
      }

      private function checkCodec() : void
      {
         var rows:Array = DuelVectors.CODEC;
         for(var r:int = 0; r < rows.length; r++)
         {
            var row:Array = rows[r];
            var token:String = row[0];
            var m:DuelMessage = DuelCodec.decode(token);
            var ok:Boolean = m != null && m.version == int(row[1]) && m.matchId == row[2] && m.seq == int(row[3]) && m.type == row[4] && m.args.join(",") == row[5] && m.hash == uint(row[6]);
            this.expect(ok,"codec decode " + r + " " + token + ": got " + describe(m));
            var args:Array = row[5] == "" ? [] : String(row[5]).split(",");
            var encoded:String = DuelCodec.encode(new DuelMessage(int(row[1]),row[2],int(row[3]),row[4],args,uint(row[6])));
            this.expect(encoded == token,"codec encode " + r + ": got " + encoded + " want " + token);
         }
         var malformed:Array = DuelVectors.CODEC_MALFORMED;
         for(var i:int = 0; i < malformed.length; i++)
         {
            var bad:DuelMessage = DuelCodec.decode(malformed[i]);
            this.expect(bad == null,"codec malformed " + i + " \"" + malformed[i] + "\" decoded to " + describe(bad));
         }
      }

      private function checkWindow() : void
      {
         var rows:Array = DuelVectors.WINDOW;
         var window:DuelWindow = null;
         var scenario:int = -1;
         var step:int = 0;
         for(var r:int = 0; r < rows.length; r++)
         {
            var row:Array = rows[r];
            if(int(row[0]) != scenario)
            {
               scenario = int(row[0]);
               window = new DuelWindow(row[2],int(row[6]));
               step = 0;
            }
            window.ingest(row[3]);
            var pops:Array = [];
            while(window.peek() != null)
            {
               pops.push(window.pop().seq);
            }
            var gap:int = window.gap ? 1 : 0;
            this.expect(pops.join(",") == row[4] && gap == int(row[5]),"window " + row[1] + " step " + step + ": popped [" + pops.join(",") + "] gap " + gap + ", want [" + row[4] + "] gap " + row[5]);
            step++;
         }
      }

      private function checkIds() : void
      {
         var ids:DuelIds = new DuelIds();
         this.expect(ids.assign(DuelIds.SEAT_A,100) == 1,"ids first A is 1");
         this.expect(ids.assign(DuelIds.SEAT_B,200) == 65537,"ids first B is 65537");
         this.expect(ids.assign(DuelIds.SEAT_A,101) == 2,"ids second A is 2");
         this.expect(ids.toLocal(65537) == 200 && ids.toNet(101) == 2,"ids maps both ways");
         this.expect(ids.toLocal(3) == -1 && ids.toNet(999) == -1,"ids unknown is -1");
         ids.forget(100);
         this.expect(ids.toNet(100) == -1 && ids.toLocal(1) == -1 && ids.toLocal(2) == 101,"ids forget drops one instance");
         this.expect(ids.assign(DuelIds.SEAT_A,100) == 3,"ids are not reused after forget");
         this.expect(ids.assign(DuelIds.SEAT_A,101) == 4 && ids.toLocal(2) == -1,"ids reassign drops the old id");
         ids.reset();
         this.expect(ids.toLocal(4) == -1 && ids.toNet(101) == -1,"ids reset clears the maps");
         this.expect(ids.assign(DuelIds.SEAT_A,7) == 1 && ids.assign(DuelIds.SEAT_B,8) == 65537,"ids reset restarts the counters");
         this.expect(DuelIds.format(17) == "A17" && DuelIds.format(65537) == "B1" && DuelIds.format(131071) == "B65535","ids format");
         this.expect(DuelIds.parse("A17") == 17 && DuelIds.parse("B1") == 65537 && DuelIds.parse("B65535") == 131071,"ids parse");
         var malformed:Array = ["","A","B","C1","a1","A0","A01","A-1","A1x","A 1","A65536","B999999","1","AA1"];
         for(var i:int = 0; i < malformed.length; i++)
         {
            this.expect(DuelIds.parse(malformed[i]) == -1,"ids parse rejects \"" + malformed[i] + "\"");
         }
         this.expect(DuelIds.parse(null) == -1,"ids parse rejects null");
         this.expect(raises(function():void
         {
            DuelIds.format(0);
         }),"ids format rejects ordinal 0");
      }

      private function checkEdges() : void
      {
         this.expect(DuelRandom.mul32(0xFFFFFFFF,0xFFFFFFFF) == 1,"mul32 max * max");
         this.expect(DuelRandom.mul32(0x9E3779B9,3) == 0xDAA66D2B,"mul32 golden * 3");
         this.expect(DuelRandom.mul32(0x12345678,0x9ABCDEF0) == 0x242D2080,"mul32 mixed");
         this.expect(raises(function():void
         {
            new DuelRandom(1,0).nextInt(DuelRandom.STREAM_A,0);
         }),"nextInt rejects n 0");
         this.expect(DuelMessage.matchIdFor(0x1A2B3C4D,2) == "1a2b3c4dg2" && DuelMessage.matchIdFor(0xFFFFFFFF,9) == "ffffffffg9","matchIdFor");
         this.expect(DuelCodec.hex8(0) == "00000000" && DuelCodec.hex8(0xFFFFFFFF) == "ffffffff","hex8");
         this.expect(raises(function():void
         {
            DuelCodec.encode(new DuelMessage(1,"ABCg1",1,"S",[],0));
         }),"encode rejects a bad match id");
         this.expect(DuelCodec.encode(new DuelMessage(1,"0g0",1,"S",null,0)) == "1.0g0.1.S._.00000000","encode without args");
         this.expect(windowTake("0g0",1 + DuelWindow.MAX_AHEAD),"window queues a seq MAX_AHEAD above the next");
         this.expect(!windowTake("0g0",2 + DuelWindow.MAX_AHEAD),"window ignores a seq further ahead");
      }

      /**
       * The routing of the opponent's D and M (spec 9.4, 9.6) on synthetic messages: an early D is held until its
       * decision point and until the board settles, a D of another kind or asker is a desync, a D while the local
       * player decides and any other message while a D is awaited are desyncs, and the mulligan accepts both orders of
       * the two seats' M (round 1 only once both are done), at most two redraws, nothing after M or after round 1.
       */
      private function checkDecisions() : void
      {
         var nur:DuelMessage = decision(["NUR","A13","A6"]);
         var remote:DuelDecision = new DuelDecision("NUR","A13",DuelStateHash.SCOPE_FULL,null,null,null);
         var local:DuelDecision = new DuelDecision("LRES","B1",DuelStateHash.SCOPE_FULL,null,null,null);
         this.expect(DuelDecision.route(nur,null,null,true) == DuelDecision.WAIT,"decision: an early D waits for its decision point");
         this.expect(DuelDecision.route(nur,remote,null,false) == DuelDecision.WAIT,"decision: a D waits until the board settles");
         this.expect(DuelDecision.route(nur,remote,null,true) == DuelDecision.APPLY,"decision: the D of the open decision applies");
         this.expect(isDesync(DuelDecision.route(decision(["LRES","A13","A6"]),remote,null,true)),"decision: a D of another kind is a desync");
         this.expect(isDesync(DuelDecision.route(decision(["NUR","A12","A6"]),remote,null,true)),"decision: a D of another asker is a desync");
         this.expect(isDesync(DuelDecision.route(decision(["NUR","A13"]),remote,null,true)),"decision: a D without a choice is a desync");
         this.expect(isDesync(DuelDecision.route(nur,null,local,true)),"decision: a D while the local player decides is a desync");
         this.expect(isDesync(DuelDecision.route(new DuelMessage(1,"0g0",9,"P",["B3","4","B"],0),remote,null,true)),"decision: a move while a D is awaited is a desync");
         this.expect(DuelDecision.route(new DuelMessage(1,"0g0",9,"P",["B3","4","B"],0),null,null,true) == DuelDecision.NOT_MINE,"decision: a move without an open decision goes on to the moves");
         var mul:DuelMessage = decision([DuelSession.MULLIGAN,DuelSession.ASKER_PERK,"B3"]);
         var done:DuelMessage = new DuelMessage(1,"0g0",9,DuelSession.MULLIGAN_DONE,[],0);
         var first:DuelMulligan = new DuelMulligan();
         this.expect(first.route(mul) == DuelMulligan.WAIT && first.route(done) == DuelMulligan.WAIT,"mulligan: D MUL and M wait until the hands are drawn");
         first.open();
         this.expect(first.route(mul) == DuelMulligan.REDRAW,"mulligan: first redraw");
         first.remoteRedraws++;
         this.expect(first.route(mul) == DuelMulligan.REDRAW,"mulligan: second redraw");
         first.remoteRedraws++;
         this.expect(isDesync(first.route(mul)),"mulligan: a third redraw is a desync");
         this.expect(isDesync(first.route(decision([DuelSession.MULLIGAN,"coin","B3"]))),"mulligan: a redraw with another asker is a desync");
         this.expect(isDesync(first.route(new DuelMessage(1,"0g0",9,DuelSession.MULLIGAN_DONE,["1"],0))),"mulligan: an M with arguments is a desync");
         this.expect(!first.roundMayStart(true),"mulligan: local done first, round 1 waits for the opponent's M");
         this.expect(first.route(done) == DuelMulligan.DONE,"mulligan: the opponent's M");
         first.remoteDone = true;
         this.expect(first.roundMayStart(true),"mulligan: local done first, then the opponent's M: round 1 starts");
         this.expect(isDesync(first.route(done)) && isDesync(first.route(mul)),"mulligan: nothing after the opponent's M");
         var second:DuelMulligan = new DuelMulligan();
         second.open();
         this.expect(second.route(done) == DuelMulligan.DONE,"mulligan: the opponent's M before any local answer");
         second.remoteDone = true;
         this.expect(!second.roundMayStart(false),"mulligan: opponent done first, round 1 waits for the local player");
         this.expect(second.roundMayStart(true),"mulligan: opponent done first, then the local player: round 1 starts");
         second.close();
         this.expect(isDesync(second.route(done)),"mulligan: an M after round 1 started is a desync");
         var late:DuelMulligan = new DuelMulligan();
         late.open();
         late.close();
         this.expect(isDesync(late.route(mul)),"mulligan: a redraw after round 1 started is a desync");
      }

      /**
       * The end of a game (spec 9.8, R43, DuelEnd) on synthetic E, R and X: the opponent's E waits until this board sent
       * its own, then confirms only with the same winner; nothing is settled before that (a Y in the wait goes to the
       * desync path, a move after the end is a desync, and no E within the limit expires); R and X count only after a
       * confirmed draw, one R each; the replay wait expires without the opponent's R.
       */
      private function checkEnd() : void
      {
         var endA:DuelMessage = new DuelMessage(1,"0g0",30,DuelSession.END,["A"],7);
         var replay:DuelMessage = new DuelMessage(1,"0g0",31,DuelSession.REPLAY,[],7);
         var leave:DuelMessage = new DuelMessage(1,"0g0",31,DuelSession.LEAVE,[],7);
         var move:DuelMessage = new DuelMessage(1,"0g0",31,"S",[],7);
         var won:DuelEnd = new DuelEnd();
         this.expect(won.route(endA) == DuelEnd.WAIT && !won.over,"end: the opponent's E waits until this board ends the game");
         this.expect(isDesync(won.route(replay)) && isDesync(won.route(leave)),"end: R and X during the game are desyncs");
         won.reached("A",29,7,1000);
         this.expect(won.over && won.phase == DuelEnd.CONFIRMING,"end: after its own E this board waits for the opponent's");
         this.expect(isDesync(won.route(move)),"end: a move after the end is a desync");
         this.expect(isDesync(won.route(new DuelMessage(1,"0g0",30,DuelSession.END,["B"],7))),"end: an E with another winner is a desync");
         this.expect(isDesync(won.route(new DuelMessage(1,"0g0",30,DuelSession.END,[],7))),"end: an E without a winner is a desync");
         this.expect(isDesync(won.route(replay)),"end: R before the result is confirmed is a desync");
         this.expect(!won.confirmExpired(1000 + DuelSession.STUCK_WAIT_MS,DuelSession.STUCK_WAIT_MS),"end: the wait for E lasts the stuck-wait limit");
         this.expect(won.confirmExpired(1001 + DuelSession.STUCK_WAIT_MS,DuelSession.STUCK_WAIT_MS),"end: no E within the stuck-wait limit expires");
         this.expect(won.route(endA) == DuelEnd.CONFIRM,"end: the opponent's E with the same winner confirms");
         won.confirm();
         this.expect(!won.confirmExpired(1001 + DuelSession.STUCK_WAIT_MS,DuelSession.STUCK_WAIT_MS),"end: a confirmed result no longer expires");
         this.expect(isDesync(won.route(endA)),"end: a second E is a desync");
         this.expect(isDesync(won.route(replay)) && isDesync(won.route(leave)),"end: R and X after a confirmed win are desyncs");
         var draw:DuelEnd = new DuelEnd();
         draw.reached(DuelEnd.DRAW,29,7,1000);
         this.expect(draw.route(new DuelMessage(1,"0g0",30,DuelSession.END,[DuelEnd.DRAW],7)) == DuelEnd.CONFIRM,"end: a draw confirms with the opponent's draw");
         draw.confirm();
         this.expect(draw.isDraw && draw.route(replay) == DuelEnd.REPLAY && draw.route(leave) == DuelEnd.LEAVE,"end: after a confirmed draw R replays and X leaves");
         this.expect(isDesync(draw.route(new DuelMessage(1,"0g0",31,DuelSession.REPLAY,["1"],7))),"end: R with arguments is a desync");
         draw.replayReceived = true;
         this.expect(isDesync(draw.route(replay)),"end: a second R is a desync");
         var waiting:DuelEnd = new DuelEnd();
         waiting.reached(DuelEnd.DRAW,29,7,1000);
         waiting.confirm();
         waiting.replaySent = true;
         waiting.replayAtMs = 5000;
         this.expect(!waiting.replayExpired(5000 + DuelSession.STUCK_WAIT_MS,DuelSession.STUCK_WAIT_MS) && waiting.replayExpired(5001 + DuelSession.STUCK_WAIT_MS,DuelSession.STUCK_WAIT_MS),"end: no R within the stuck-wait limit after this board's R expires");
         waiting.replayReceived = true;
         this.expect(!waiting.replayExpired(5001 + DuelSession.STUCK_WAIT_MS,DuelSession.STUCK_WAIT_MS),"end: the replay wait ends with the opponent's R");
      }

      /**
       * The deferral queue of simultaneous effects (spec 7.4, DuelDeferred) on effects queued in a scrambled order: they
       * run seat A first, then by net id, then in queue order, whatever order they were queued in (two effects of one
       * card run in the order queued); an effect queued while another runs takes its place in the order; effects
       * without a seat or net id run last; clear() empties the queue.
       */
      private function checkDeferred() : void
      {
         var ran:Array = [];
         var queue:DuelDeferred = new DuelDeferred();
         var cardA7:Object = new Object();
         var effect:DuelEffect = null;
         queue.add(DuelIds.SEAT_B,65536 + 3,new Object(),recorder(ran,"B3"));
         queue.add(DuelIds.SEAT_A,7,cardA7,recorder(ran,"A7"));
         queue.add(DuelDeferred.NO_SEAT,DuelDeferred.NO_NET_ID,null,recorder(ran,"none1"));
         queue.add(DuelIds.SEAT_B,65536 + 1,new Object(),recorder(ran,"B1"));
         queue.add(DuelIds.SEAT_A,12,new Object(),recorder(ran,"A12"));
         queue.add(DuelIds.SEAT_A,2,new Object(),function():void
         {
            ran.push("A2");
            queue.add(DuelIds.SEAT_A,1,new Object(),recorder(ran,"A1"));
         });
         queue.add(DuelDeferred.NO_SEAT,DuelDeferred.NO_NET_ID,null,recorder(ran,"none2"));
         queue.add(DuelIds.SEAT_A,7,cardA7,recorder(ran,"A7again"));
         this.expect(queue.count == 8 && queue.pending,"deferred: eight effects queued (" + queue.count + ")");
         while(queue.pending)
         {
            effect = queue.takeNext();
            effect.run();
         }
         this.expect(ran.join(" ") == "A2 A1 A7 A7again A12 B1 B3 none1 none2","deferred: seat A first, then net id, then queue order (" + ran.join(" ") + ")");
         this.expect(queue.takeNext() == null && !queue.pending && queue.count == 0,"deferred: an empty queue gives nothing");
         ran.length = 0;
         queue.add(DuelIds.SEAT_B,65536 + 1,new Object(),recorder(ran,"B1"));
         queue.add(DuelIds.SEAT_A,65536 + 9,new Object(),recorder(ran,"A-owned"));
         queue.takeNext().run();
         this.expect(ran.join(" ") == "A-owned","deferred: the owner's seat decides before the net id (" + ran.join(" ") + ")");
         queue.add(DuelIds.SEAT_A,4,new Object(),recorder(ran,"A4"));
         queue.clear();
         this.expect(!queue.pending && queue.takeNext() == null,"deferred: clear drops every queued effect");
         this.checkDoubleScorch();
      }

      /**
       * The double scorch guard (DuelDeferred.stillOnBoard): two scorches that land together queue a graveyard move
       * for the same three cards twice (one of them is banished instead, as a summoned card is). Every move runs
       * without error and each card leaves its row exactly once; a second move of a card would throw here, as the
       * second banish does in vanilla.
       */
      private function checkDoubleScorch() : void
      {
         var queue:DuelDeferred = new DuelDeferred();
         var targets:Array = [{"list":CardManager.CARD_LIST_LOC_MELEE,"exists":true,"banish":false,"moves":0},{"list":CardManager.CARD_LIST_LOC_RANGED,"exists":true,"banish":true,"moves":0},{"list":CardManager.CARD_LIST_LOC_SEIGE,"exists":true,"banish":false,"moves":0}];
         var scorch:int;
         var i:int;
         var threw:Boolean = false;
         for(scorch = 0; scorch < 2; scorch++)
         {
            for(i = 0; i < targets.length; i++)
            {
               queue.add(DuelIds.SEAT_A,i + 1,targets[i],scorchMove(targets[i]));
            }
         }
         try
         {
            while(queue.pending)
            {
               queue.takeNext().run();
            }
         }
         catch(error:Error)
         {
            threw = true;
         }
         var once:Boolean = true;
         for(i = 0; i < targets.length; i++)
         {
            once = once && targets[i].moves == 1;
         }
         this.expect(!threw && once,"deferred: a double scorch moves each card once without error");
         this.expect(DuelDeferred.stillOnBoard(CardManager.CARD_LIST_LOC_MELEE,true) && DuelDeferred.stillOnBoard(CardManager.CARD_LIST_LOC_RANGED,true) && DuelDeferred.stillOnBoard(CardManager.CARD_LIST_LOC_SEIGE,true),"deferred: a card on a unit row is still on the board");
         this.expect(!DuelDeferred.stillOnBoard(CardManager.CARD_LIST_LOC_GRAVEYARD,true) && !DuelDeferred.stillOnBoard(CardManager.CARD_LIST_LOC_HAND,true) && !DuelDeferred.stillOnBoard(CardManager.CARD_LIST_LOC_MELEE,false),"deferred: a card in a graveyard, a hand or deleted is not");
      }

      /**
       * A deferred scorch end for a synthetic target, guarded as CardInstance.duelRunScorched is: it sends the target
       * to the graveyard (or banishes it) and throws if the target already left its row.
       */
      private static function scorchMove(target:Object) : Function
      {
         return function():void
         {
            if(!DuelDeferred.stillOnBoard(target.list,target.exists))
            {
               return;
            }
            if(target.moves > 0)
            {
               throw new Error("moved twice");
            }
            target.moves++;
            if(target.banish)
            {
               target.exists = false;
               target.list = CardManager.CARD_LIST_LOC_INVALID;
            }
            else
            {
               target.list = CardManager.CARD_LIST_LOC_GRAVEYARD;
            }
         };
      }

      /** An effect that records its name in ran when it runs. */
      private static function recorder(ran:Array, name:String) : Function
      {
         return function():void
         {
            ran.push(name);
         };
      }

      /** A synthetic D with these args. */
      private static function decision(args:Array) : DuelMessage
      {
         return new DuelMessage(1,"0g0",9,DuelSession.DECISION,args,0);
      }

      /** Whether a route() result is the detail of a desync (anything but the routing words). */
      private static function isDesync(route:String) : Boolean
      {
         var words:Array = [DuelDecision.WAIT,DuelDecision.APPLY,DuelDecision.NOT_MINE,DuelMulligan.WAIT,DuelMulligan.REDRAW,DuelMulligan.DONE,DuelEnd.WAIT,DuelEnd.CONFIRM,DuelEnd.REPLAY,DuelEnd.LEAVE];
         return words.indexOf(route) < 0;
      }

      /** True if a fresh window queues (reports a gap for) a lone message with this seq. */
      private static function windowTake(matchId:String, seq:int) : Boolean
      {
         var window:DuelWindow = new DuelWindow(matchId);
         window.ingest(DuelCodec.encode(new DuelMessage(DuelCodec.PROTOCOL_VERSION,matchId,seq,"S",[],0)));
         return window.gap;
      }

      private static function raises(body:Function) : Boolean
      {
         try
         {
            body();
         }
         catch(error:Error)
         {
            return true;
         }
         return false;
      }

      private static function describe(m:DuelMessage) : String
      {
         if(m == null)
         {
            return "null";
         }
         return "[" + m.version + " " + m.matchId + " " + m.seq + " " + m.type + " (" + m.args.join(",") + ") " + m.hash + "]";
      }
   }
}
