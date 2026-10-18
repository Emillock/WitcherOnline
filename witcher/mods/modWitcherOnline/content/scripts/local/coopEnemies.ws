// Shared enemies (true co-op, milestone 1). The party leader's game owns the hostile NPCs near the party and
// broadcasts them ("en" channel); members mirror them as puppets (AI off, moved and healed from the leader's
// state) and send their hits to the leader ("hit" channel), who applies them to the real NPC.
// Unmatched local hostiles near a member are hidden while they mirror the leader's world.

class r_CoopHostEnemy
{
    public var npc : CNewNPC;
    public var netId : int;
    public var lastSeenAt : float;
    public var deadAt : float;
}

class r_CoopPuppet
{
    public var npc : CNewNPC;
    public var netId : int;
    public var spawned : bool;  // created here (destroyed on release) or a local twin (AI given back on release)
    public var aiId : int;
    public var target : Vector;
    public var yaw : float;
    public var hp : float;
    public var alive : bool;
    public var predictUntil : float;
}

class r_CoopSuppressed
{
    public var npc : CNewNPC;
    public var aiId : int;
}

class r_CoopHit
{
    public var seq : int;
    public var netId : int;
    public var frac : float;
}

class r_CoopAck
{
    public var user : string;
    public var session : int;
    public var lastSeq : int;
}

class r_CoopEnemies
{
    private var epoch : int;    // this game as leader: changes on restart so members drop stale ids
    private var session : int;  // this game as member: lets the leader restart hit numbering
    private var nextNetId : int;
    private var nextHitSeq : int;

    private var hostEnemies : array<r_CoopHostEnemy>;
    private var acks : array<r_CoopAck>;
    private var wasHost : bool;
    private var lastHostSend : float;
    private var hostSeq : int;

    private var puppets : array<r_CoopPuppet>;
    private var suppressed : array<r_CoopSuppressed>;
    private var leaderName : string;
    private var leaderEpoch : int;
    private var lastSnapshotAt : float;
    private var pendingHits : array<r_CoopHit>;
    private var lastHitSend : float;
    private var lastHitSentCount : int;

    // set while this game changes a puppet itself, so the damage hook lets it through
    public var applyingHostState : bool;

    // diagnostics for logs and the test bot
    public var hitsSent : int;
    public var hitsApplied : int;
    public var puppetsSpawned : int;
    public var twinsBound : int;
    public var spawnFailures : int;
    public var lastError : string;

    default lastHostSend = -999;
    default lastSnapshotAt = -999;
    default lastHitSend = -999;

    private function EnsureIds()
    {
        if(epoch == 0)
        {
            epoch = RandRange(1000000000, 1);
            session = RandRange(1000000000, 1);
            nextNetId = 1;
            nextHitSeq = 1;
        }
    }

    // 0 off, 1 leader of a party with members, 2 member
    public function GetRole() : int
    {
        var client : r_MultiplayerClient;
        var globals : array<r_RemotePlayer>;
        var localOnly : bool;
        var me : string;
        var i : int;

        client = theGame.r_getMultiplayerClient();
        localOnly = theGame.GetInGameConfigWrapper().GetVarValue('MPGhosts_Main', 'MPGhosts_LocalEnemiesOnly');
        if(!client || localOnly)
        {
            return 0;
        }

        if(client.getInParty() && client.getJoinedParty() != "" && client.getJoinedParty() != "none")
        {
            return 2;
        }

        me = client.getUsername();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].inParty && globals[i].joinedParty == me)
            {
                return 1;
            }
        }
        return 0;
    }

    // called every frame from the client's tick while in game
    public function Tick()
    {
        var client : r_MultiplayerClient;
        var role : int;
        var now : float;

        client = theGame.r_getMultiplayerClient();
        if(!client || !thePlayer)
        {
            return;
        }

        EnsureIds();
        now = theGame.GetEngineTimeAsSeconds();
        role = GetRole();

        if(role == 1)
        {
            if(now - lastHostSend >= 0.1)
            {
                HostCollect(client, now);
                HostSend();
                lastHostSend = now;
            }
            wasHost = true;
        }
        else if(wasHost)
        {
            hostEnemies.Clear();
            HostSend();
            wasHost = false;
        }

        if(role == 2)
        {
            if(leaderName != client.getJoinedParty())
            {
                ReleaseAll();
                pendingHits.Clear();
                leaderName = client.getJoinedParty();
                leaderEpoch = 0;
            }

            // the leader's snapshots also stop while its game sits in a menu
            if(now - lastSnapshotAt > 8.0)
            {
                ReleaseAll();
            }
            else
            {
                UpdatePuppets(now);
            }
            SendHits(now);
        }
        else if(puppets.Size() > 0 || suppressed.Size() > 0)
        {
            ReleaseAll();
            leaderName = "";
        }
    }

    // ---------------------------------------------------------------- leader

    private function HostCollect(client : r_MultiplayerClient, now : float)
    {
        var candidates : array<CActor>;
        var entities : array<CGameplayEntity>;
        var globals : array<r_RemotePlayer>;
        var npc : CNewNPC;
        var e : r_CoopHostEnemy;
        var me : string;
        var area : int;
        var i, j : int;

        candidates = thePlayer.GetNPCsAndPlayersInRange(40, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);

        me = client.getUsername();
        area = WO_CurrentAreaCode();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(!globals[i] || !globals[i].inParty || globals[i].joinedParty != me || globals[i].area != area)
            {
                continue;
            }

            entities.Clear();
            FindGameplayEntitiesInSphere(entities, globals[i].pos, 40, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors, thePlayer);
            for(j = 0; j < entities.Size(); j += 1)
            {
                if((CActor)entities[j] && !candidates.Contains((CActor)entities[j]))
                {
                    candidates.PushBack((CActor)entities[j]);
                }
            }
        }

        for(i = 0; i < candidates.Size(); i += 1)
        {
            npc = (CNewNPC)candidates[i];
            if(!npc || npc.HasTag('MPEntity') || npc.IsHorse())
            {
                continue;
            }

            e = FindHostEnemyByNpc(npc);
            if(!e)
            {
                if(hostEnemies.Size() >= 24)
                {
                    continue;
                }
                e = new r_CoopHostEnemy in this;
                e.npc = npc;
                e.netId = nextNetId;
                e.deadAt = -1;
                nextNetId += 1;
                hostEnemies.PushBack(e);
            }
            e.lastSeenAt = now;
        }

        // keep dead enemies for a few seconds so members see the death; drop ones out of range
        for(i = hostEnemies.Size() - 1; i >= 0; i -= 1)
        {
            e = hostEnemies[i];
            if(!e.npc)
            {
                hostEnemies.Erase(i);
                continue;
            }
            if(e.deadAt < 0 && !e.npc.IsAlive())
            {
                e.deadAt = now;
            }
            if((e.deadAt >= 0 && now - e.deadAt > 4.0) || (e.deadAt < 0 && now - e.lastSeenAt > 3.0))
            {
                hostEnemies.Erase(i);
            }
        }
    }

    // "en epoch seq area acks{user session lastSeq} templates{path} enemies{netId tpl appearance x y z yaw hp alive}"
    private function HostSend()
    {
        var templates : array<string>;
        var body : string;
        var tpl : string;
        var pos : Vector;
        var e : r_CoopHostEnemy;
        var tplIndex : int;
        var alive : int;
        var i : int;

        hostSeq += 1;
        body = "";
        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            e = hostEnemies[i];
            tpl = CoopEncode(e.npc.GetReadableName());
            tplIndex = templates.FindFirst(tpl);
            if(tplIndex < 0)
            {
                templates.PushBack(tpl);
                tplIndex = templates.Size() - 1;
            }

            pos = e.npc.GetWorldPosition();
            alive = 0;
            if(e.deadAt < 0)
            {
                alive = 1;
            }

            body += " " + e.netId + " " + tplIndex + " " + CoopEncode(NameToString(e.npc.GetAppearance()))
                + " " + FloatToStringPrec(pos.X, 2) + " " + FloatToStringPrec(pos.Y, 2) + " " + FloatToStringPrec(pos.Z, 2)
                + " " + FloatToStringPrec(e.npc.GetHeading(), 1) + " " + FloatToStringPrec(MaxF(0, e.npc.GetHealthPercents()), 4)
                + " " + alive;
        }

        WO_Send("coop en " + epoch + " " + hostSeq + " " + WO_CurrentAreaCode() + " " + AcksText() + " " + TemplatesText(templates)
            + " " + hostEnemies.Size() + body);
    }

    private function AcksText() : string
    {
        var text : string;
        var i : int;

        text = "" + acks.Size();
        for(i = 0; i < acks.Size(); i += 1)
        {
            text += " " + acks[i].user + " " + acks[i].session + " " + acks[i].lastSeq;
        }
        return text;
    }

    private function TemplatesText(templates : array<string>) : string
    {
        var text : string;
        var i : int;

        text = "" + templates.Size();
        for(i = 0; i < templates.Size(); i += 1)
        {
            text += " " + templates[i];
        }
        return text;
    }

    private function FindHostEnemyByNpc(npc : CNewNPC) : r_CoopHostEnemy
    {
        var i : int;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            if(hostEnemies[i].npc == npc)
            {
                return hostEnemies[i];
            }
        }
        return NULL;
    }

    private function FindHostEnemy(netId : int) : r_CoopHostEnemy
    {
        var i : int;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            if(hostEnemies[i].netId == netId)
            {
                return hostEnemies[i];
            }
        }
        return NULL;
    }

    private function FindAck(user : string, memberSession : int) : r_CoopAck
    {
        var ack : r_CoopAck;
        var i : int;

        for(i = 0; i < acks.Size(); i += 1)
        {
            if(acks[i].user == user)
            {
                if(acks[i].session != memberSession)
                {
                    acks[i].session = memberSession;
                    acks[i].lastSeq = 0;
                }
                return acks[i];
            }
        }

        ack = new r_CoopAck in this;
        ack.user = user;
        ack.session = memberSession;
        acks.PushBack(ack);
        return ack;
    }

    // "hit leader epoch session count {seq netId fraction}": all hits the member has not seen acknowledged yet
    private function OnHits(sender : string, count : int)
    {
        var client : r_MultiplayerClient;
        var ack : r_CoopAck;
        var n, i, idx, seq : int;

        client = theGame.r_getMultiplayerClient();
        if(count < 5 || WO_Str(1) != client.getUsername() || StringToInt(WO_Str(2), 0) != epoch || !IsMyPartyMember(sender))
        {
            return;
        }

        ack = FindAck(sender, StringToInt(WO_Str(3), 0));
        n = StringToInt(WO_Str(4), 0);
        idx = 5;
        for(i = 0; i < n && idx + 2 < count; i += 1)
        {
            seq = StringToInt(WO_Str(idx), 0);
            if(seq > ack.lastSeq)
            {
                ApplyHit(sender, StringToInt(WO_Str(idx + 1), 0), StringToFloat(WO_Str(idx + 2), 0));
                ack.lastSeq = seq;
            }
            idx += 3;
        }
    }

    private function ApplyHit(sender : string, netId : int, frac : float)
    {
        var e : r_CoopHostEnemy;
        var action : W3DamageAction;
        var attacker : CActor;

        e = FindHostEnemy(netId);
        if(!e || !e.npc || !e.npc.IsAlive() || frac <= 0)
        {
            return;
        }

        attacker = GhostOf(sender);
        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(attacker, e.npc, theGame, "W3Coop", EHRT_Light, CPS_Undefined, false, false, false, false);
        action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, MinF(frac, 1) * e.npc.GetMaxHealth());
        action.SetCannotReturnDamage(true);
        theGame.damageMgr.ProcessAction(action);
        delete action;
        hitsApplied += 1;
    }

    private function IsMyPartyMember(user : string) : bool
    {
        var client : r_MultiplayerClient;
        var globals : array<r_RemotePlayer>;
        var i : int;

        client = theGame.r_getMultiplayerClient();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == user)
            {
                return globals[i].inParty && globals[i].joinedParty == client.getUsername();
            }
        }
        return false;
    }

    private function GhostOf(user : string) : CActor
    {
        var players : array<r_RemotePlayer>;
        var i : int;

        players = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].username == user)
            {
                return players[i].ghost;
            }
        }
        return NULL;
    }

    // ---------------------------------------------------------------- member

    // inbound COOP message from the client's pump; fields are read with WO_Str
    public function OnMessage()
    {
        var client : r_MultiplayerClient;
        var sender : string;
        var count : int;

        client = theGame.r_getMultiplayerClient();
        sender = WO_Str(-1);
        count = StringToInt(WO_Str(-3), 0);
        if(!client || sender == client.getUsername() || count < 1)
        {
            return;
        }

        EnsureIds();
        if(WO_Str(0) == "en")
        {
            OnSnapshot(sender, count);
        }
        else if(WO_Str(0) == "hit")
        {
            OnHits(sender, count);
        }
    }

    private function OnSnapshot(sender : string, count : int)
    {
        var templates : array<string>;
        var seen : array<int>;
        var pos : Vector;
        var snapshotEpoch, n, i, idx, netId, tplIndex : int;
        var hp, yaw : float;
        var alive : bool;
        var app : string;

        if(GetRole() != 2 || sender != leaderName || count < 4)
        {
            return;
        }

        if(StringToInt(WO_Str(3), 0) != WO_CurrentAreaCode())
        {
            ReleaseAll();
            return;
        }

        snapshotEpoch = StringToInt(WO_Str(1), 0);
        if(snapshotEpoch != leaderEpoch)
        {
            // the leader restarted: its enemy ids and hit acknowledgements start over
            ReleaseAll();
            pendingHits.Clear();
            leaderEpoch = snapshotEpoch;
        }
        lastSnapshotAt = theGame.GetEngineTimeAsSeconds();

        idx = 4;
        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx + 2 < count; i += 1)
        {
            if(WO_Str(idx) == theGame.r_getMultiplayerClient().getUsername() && StringToInt(WO_Str(idx + 1), 0) == session)
            {
                PruneHits(StringToInt(WO_Str(idx + 2), 0));
            }
            idx += 3;
        }

        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx < count; i += 1)
        {
            templates.PushBack(CoopDecode(WO_Str(idx)));
            idx += 1;
        }

        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx + 8 < count; i += 1)
        {
            netId = StringToInt(WO_Str(idx), 0);
            tplIndex = StringToInt(WO_Str(idx + 1), 0);
            app = CoopDecode(WO_Str(idx + 2));
            pos.X = StringToFloat(WO_Str(idx + 3), 0);
            pos.Y = StringToFloat(WO_Str(idx + 4), 0);
            pos.Z = StringToFloat(WO_Str(idx + 5), 0);
            pos.W = 1;
            yaw = StringToFloat(WO_Str(idx + 6), 0);
            hp = StringToFloat(WO_Str(idx + 7), 0);
            alive = WO_Str(idx + 8) == "1";
            idx += 9;

            if(tplIndex >= 0 && tplIndex < templates.Size())
            {
                ApplyEnemy(netId, templates[tplIndex], app, pos, yaw, hp, alive);
                seen.PushBack(netId);
            }
        }

        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            if(!seen.Contains(puppets[i].netId))
            {
                ReleasePuppet(puppets[i]);
                puppets.Erase(i);
            }
        }

        SuppressUnmatched();
    }

    private function ApplyEnemy(netId : int, tpl : string, app : string, pos : Vector, yaw : float, hp : float, alive : bool)
    {
        var p : r_CoopPuppet;
        var npc : CNewNPC;
        var spawned : bool;
        var now : float;

        now = theGame.GetEngineTimeAsSeconds();
        p = FindPuppet(netId);
        if(!p)
        {
            if(!alive || VecDistance(thePlayer.GetWorldPosition(), pos) > 70)
            {
                return;
            }

            npc = FindTwin(tpl, pos);
            if(npc)
            {
                twinsBound += 1;
            }
            else
            {
                npc = SpawnPuppet(tpl, app, pos, yaw);
                spawned = true;
            }
            if(!npc)
            {
                return;
            }
            p = MakePuppet(npc, netId, spawned);
        }

        p.target = pos;
        p.yaw = yaw;
        // after a local hit the leader's health arrives a moment later; don't flash back up meanwhile
        if(now >= p.predictUntil || hp < p.hp)
        {
            p.hp = hp;
        }

        if(!alive && p.alive)
        {
            KillPuppet(p);
        }
    }

    private function FindTwin(tpl : string, pos : Vector) : CNewNPC
    {
        var entities : array<CGameplayEntity>;
        var npc, best : CNewNPC;
        var dist, bestDist : float;
        var i : int;

        bestDist = 10.0;
        FindGameplayEntitiesInSphere(entities, pos, 10.0, 32, '', FLAG_OnlyAliveActors, thePlayer);
        for(i = 0; i < entities.Size(); i += 1)
        {
            npc = (CNewNPC)entities[i];
            if(!npc || npc.HasTag('MPEntity') || IsPuppet(npc) || npc.GetReadableName() != tpl)
            {
                continue;
            }
            dist = VecDistance(npc.GetWorldPosition(), pos);
            if(dist < bestDist)
            {
                bestDist = dist;
                best = npc;
            }
        }

        if(best)
        {
            Unsuppress(best);
        }
        return best;
    }

    private function SpawnPuppet(tpl : string, app : string, pos : Vector, yaw : float) : CNewNPC
    {
        var template : CEntityTemplate;
        var ent : CEntity;
        var npc : CNewNPC;
        var rot : EulerAngles;

        template = (CEntityTemplate)LoadResource(tpl, true);
        if(!template)
        {
            spawnFailures += 1;
            lastError = "no template '" + tpl + "'";
            return NULL;
        }

        rot.Yaw = yaw;
        ent = theGame.CreateEntity(template, pos, rot, true, false, false, PM_DontPersist);
        npc = (CNewNPC)ent;
        if(!npc)
        {
            if(ent)
            {
                ent.Destroy();
            }
            spawnFailures += 1;
            lastError = "'" + tpl + "' did not spawn an NPC";
            return NULL;
        }

        if(app != "")
        {
            npc.ApplyAppearance(app);
        }
        puppetsSpawned += 1;
        return npc;
    }

    private function MakePuppet(npc : CNewNPC, netId : int, spawned : bool) : r_CoopPuppet
    {
        var p : r_CoopPuppet;

        p = new r_CoopPuppet in this;
        p.npc = npc;
        p.netId = netId;
        p.spawned = spawned;
        p.alive = true;
        p.hp = npc.GetHealthPercents();
        p.target = npc.GetWorldPosition();
        p.yaw = npc.GetHeading();
        p.aiId = ForceIdle(npc);
        puppets.PushBack(p);
        return p;
    }

    private function ForceIdle(npc : CNewNPC) : int
    {
        var tree : CAIDoNothingAction;

        tree = new CAIDoNothingAction in npc;
        tree.OnCreated();
        return npc.ForceAIBehavior(tree, BTAP_AboveCombat);
    }

    private function UpdatePuppets(now : float)
    {
        var p : r_CoopPuppet;
        var current : float;
        var i : int;

        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            p = puppets[i];
            if(!p.npc)
            {
                puppets.Erase(i);
                continue;
            }
            if(!p.alive)
            {
                continue;
            }

            MovePuppet(p);

            current = p.npc.GetHealthPercents();
            if(current >= 0 && p.hp > 0 && AbsF(current - p.hp) > 0.002)
            {
                applyingHostState = true;
                p.npc.SetHealthPerc(p.hp);
                applyingHostState = false;
            }
        }
    }

    private function MovePuppet(p : r_CoopPuppet)
    {
        var adjustor : CMovementAdjustor;
        var ticket : SMovementAdjustmentRequestTicket;
        var rot : EulerAngles;
        var dist : float;

        dist = VecDistance(p.npc.GetWorldPosition(), p.target);
        if(dist > 12)
        {
            rot = p.npc.GetWorldRotation();
            rot.Yaw = p.yaw;
            p.npc.TeleportWithRotation(p.target, rot);
            return;
        }
        if(dist < 0.1 && AbsF(AngleDistance(p.yaw, p.npc.GetHeading())) < 3)
        {
            return;
        }

        adjustor = p.npc.GetMovingAgentComponent().GetMovementAdjustor();
        adjustor.Cancel(adjustor.GetRequest('w3coop_puppet'));
        ticket = adjustor.CreateNewRequest('w3coop_puppet');
        adjustor.AdjustmentDuration(ticket, 0.15);
        adjustor.AdjustLocationVertically(ticket, true);
        adjustor.ScaleAnimationLocationVertically(ticket, true);
        adjustor.RotateTo(ticket, p.yaw);
        adjustor.SlideTo(ticket, p.target);
    }

    private function KillPuppet(p : r_CoopPuppet)
    {
        p.alive = false;
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        applyingHostState = true;
        p.npc.Kill('W3Coop', true);
        applyingHostState = false;
    }

    // a puppet the leader no longer reports: spawned ones go away, local twins get their own AI back
    private function ReleasePuppet(p : r_CoopPuppet)
    {
        if(!p.npc || !p.alive)
        {
            return;
        }
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        if(p.spawned)
        {
            p.npc.Destroy();
        }
    }

    public function ReleaseAll()
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            ReleasePuppet(puppets[i]);
        }
        puppets.Clear();

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            Unsuppress(suppressed[i].npc);
        }
        suppressed.Clear();
    }

    // local hostiles near this member that the leader's world doesn't have: hidden and idle while in the party
    private function SuppressUnmatched()
    {
        var actors : array<CActor>;
        var npc : CNewNPC;
        var s : r_CoopSuppressed;
        var i : int;

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            if(!suppressed[i].npc)
            {
                suppressed.Erase(i);
            }
        }

        actors = thePlayer.GetNPCsAndPlayersInRange(30, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(!npc || npc.HasTag('MPEntity') || npc.IsHorse() || IsPuppet(npc) || IsSuppressed(npc))
            {
                continue;
            }

            s = new r_CoopSuppressed in this;
            s.npc = npc;
            s.aiId = ForceIdle(npc);
            npc.SetVisibility(false);
            npc.SetGameplayVisibility(false);
            npc.EnableCharacterCollisions(false);
            suppressed.PushBack(s);
        }
    }

    private function IsSuppressed(npc : CNewNPC) : bool
    {
        var i : int;

        for(i = 0; i < suppressed.Size(); i += 1)
        {
            if(suppressed[i].npc == npc)
            {
                return true;
            }
        }
        return false;
    }

    private function Unsuppress(npc : CNewNPC)
    {
        var i : int;

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            if(suppressed[i].npc == npc)
            {
                if(npc)
                {
                    npc.CancelAIBehavior(suppressed[i].aiId);
                    npc.SetVisibility(true);
                    npc.SetGameplayVisibility(true);
                    npc.EnableCharacterCollisions(true);
                }
                suppressed.Erase(i);
            }
        }
    }

    private function FindPuppet(netId : int) : r_CoopPuppet
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].netId == netId)
            {
                return puppets[i];
            }
        }
        return NULL;
    }

    private function FindPuppetByNpc(npc : CNewNPC) : r_CoopPuppet
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].npc == npc)
            {
                return puppets[i];
            }
        }
        return NULL;
    }

    public function IsPuppet(npc : CNewNPC) : bool
    {
        return FindPuppetByNpc(npc) != NULL;
    }

    // damage the local player dealt to a puppet (after this game's stats, resistances and crits) goes to the
    // leader as a fraction of max health; the caller then zeroes it here
    public function OnPuppetDamaged(npc : CNewNPC, action : W3DamageAction)
    {
        var p : r_CoopPuppet;
        var hit : r_CoopHit;
        var dmg, maxHp : float;

        p = FindPuppetByNpc(npc);
        if(!p || !p.alive || action.attacker != thePlayer)
        {
            return;
        }

        if(npc.UsesVitality())
        {
            dmg = action.processedDmg.vitalityDamage;
        }
        else
        {
            dmg = action.processedDmg.essenceDamage;
        }
        maxHp = npc.GetMaxHealth();
        if(dmg <= 0 || maxHp <= 0)
        {
            return;
        }

        hit = new r_CoopHit in this;
        hit.seq = nextHitSeq;
        hit.netId = p.netId;
        hit.frac = MinF(1, dmg / maxHp);
        nextHitSeq += 1;
        pendingHits.PushBack(hit);
        if(pendingHits.Size() > 32)
        {
            pendingHits.Erase(0);
        }
        hitsSent += 1;

        p.hp = MaxF(0.001, p.hp - hit.frac);
        p.predictUntil = theGame.GetEngineTimeAsSeconds() + 0.6;
        lastHitSend = -999;
    }

    private function PruneHits(lastSeq : int)
    {
        var i : int;

        for(i = pendingHits.Size() - 1; i >= 0; i -= 1)
        {
            if(pendingHits[i].seq <= lastSeq)
            {
                pendingHits.Erase(i);
            }
        }
    }

    // resends every unacknowledged hit until the leader's snapshot acknowledges it
    private function SendHits(now : float)
    {
        var text : string;
        var i : int;

        if(pendingHits.Size() == 0 && lastHitSentCount == 0)
        {
            return;
        }
        if(now - lastHitSend < 0.1)
        {
            return;
        }

        text = "coop hit " + leaderName + " " + leaderEpoch + " " + session + " " + pendingHits.Size();
        for(i = 0; i < pendingHits.Size(); i += 1)
        {
            text += " " + pendingHits[i].seq + " " + pendingHits[i].netId + " " + FloatToStringPrec(pendingHits[i].frac, 4);
        }
        WO_Send(text);
        lastHitSend = now;
        lastHitSentCount = pendingHits.Size();
    }

    // ---------------------------------------------------------------- diagnostics

    public function HostEnemyCount() : int
    {
        return hostEnemies.Size();
    }

    public function HostNetIdOf(npc : CNewNPC) : int
    {
        var e : r_CoopHostEnemy;

        e = FindHostEnemyByNpc(npc);
        if(e)
        {
            return e.netId;
        }
        return 0;
    }

    public function PuppetCount() : int
    {
        return puppets.Size();
    }

    public function PuppetAt(i : int) : CNewNPC
    {
        return puppets[i].npc;
    }

    public function PuppetHostHp(i : int) : float
    {
        return puppets[i].hp;
    }

    public function PuppetAlive(i : int) : bool
    {
        return puppets[i].alive;
    }

    public function PuppetSpawned(i : int) : bool
    {
        return puppets[i].spawned;
    }

    public function SuppressedCount() : int
    {
        return suppressed.Size();
    }

    public function PendingHitCount() : int
    {
        return pendingHits.Size();
    }
}

// Spaces separate fields on the wire; '*' can't appear in depot paths or appearance names.
function CoopEncode(text : string) : string
{
    if(text == "")
    {
        return "-";
    }
    return StrReplaceAll(text, " ", "*");
}

function CoopDecode(text : string) : string
{
    if(text == "-")
    {
        return "";
    }
    return StrReplaceAll(text, "*", " ");
}

// Damage to a puppet is computed here as usual, sent to the leader, and not applied locally: the leader's
// health comes back in its next snapshot.
@wrapMethod(CNewNPC)
function OnTakeDamage(action : W3DamageAction)
{
    var client : r_MultiplayerClient;
    var coop : r_CoopEnemies;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        coop = client.getCoopEnemies();
    }
    if(coop && !coop.applyingHostState && coop.IsPuppet(this))
    {
        coop.OnPuppetDamaged(this, action);
        action.SetAllProcessedDamageAs(0);
    }

    wrappedMethod(action);
}
