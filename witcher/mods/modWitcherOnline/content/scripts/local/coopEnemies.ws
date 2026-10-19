// Shared enemies (true co-op, milestone 1). The party leader's game owns the hostile NPCs near the party and
// broadcasts them ("en" channel); members mirror them as puppets (AI off, moved and healed from the leader's
// state) and send their hits to the leader ("hit" channel), who applies them to the real NPC. The leader's
// monsters attack members' ghosts; those hits go to the member ("hurt" channel) and land on their Geralt.
// Unmatched local hostiles near a member are hidden while they mirror the leader's world.

class r_CoopHostEnemy
{
    public var npc : CNewNPC;
    public var netId : int;
    public var lastSeenAt : float;
    public var deadAt : float;
    public var attackSeq : int;
    public var attackAnim : name;
    public var hitAnimTime : float;  // animation time of the current attack's hit
    public var hitSeq : int;         // hits it took, for members to replay the reaction
    public var hitBy : string;
    public var hitReaction : int;
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
    public var attackSeq : int;
    public var attackPlayedAt : float;
    public var animAiId : int;
    public var hitSeq : int;
    public var wasInHitAnim : bool;
    public var reactUntil : float;  // forced idle lifted until then, so the AI plays the hit reaction
    public var addedNoFinishers : array<name>;
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

// a leader monster's hit on a member's ghost: raw damage before the ghost's own stats
class r_CoopHurt
{
    public var user : string;
    public var seq : int;
    public var netId : int;
    public var hitReaction : int;
    public var attackSeq : int;     // the attack that landed it, to line it up with the puppet's swing
    public var hitAnimTime : float;
    public var due : float;         // member: when to apply it
    public var receivedAt : float;
    public var types : array<name>;
    public var values : array<float>;
    public var effects : array<int>; // EEffectType of the hit's buffs (bleeding, knockdown, ...)
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
    private var hurts : array<r_CoopHurt>;
    private var nextHurtSeq : int;
    private var lastHurtSend : float;
    private var lastHurtSentCount : int;
    private var armedGhosts : array<CActor>;
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
    private var hurtAck : int;
    private var lastSentHurtAck : int;
    private var leaderListsMyHurts : bool;
    private var delayedHurts : array<r_CoopHurt>;

    // journal entries (quests, objectives) whose status changed this session, latest status per tag
    private var journalTags : array<name>;
    private var journalStatus : array<int>;
    private var journalTick : int;
    private var lastJournalSend : float;
    private var applyingJournal : bool;
    private var journalIndexTags : array<name>;
    private var journalIndexEntries : array<CJournalBase>;
    private var journalIndexBuiltAt : float;

    // scenes and the leader's tracking (sent with the journal list)
    private var currentScene : string;
    private var sceneSkipSeq : int;
    private var sceneSkipValue : int;
    private var applyingSkip : bool;
    private var sentTrackedQuest : name;
    private var sentHighlighted : name;
    private var leaderTrackedQuest : name;
    private var leaderHighlighted : name;
    private var leaderSceneSeen : string;
    private var leaderSkipSeen : int;

    // set while this game changes a puppet itself, so the damage hook lets it through
    public var applyingHostState : bool;

    // diagnostics for logs and the test bot
    public var hitsSent : int;
    public var hitsApplied : int;
    public var puppetsSpawned : int;
    public var twinsBound : int;
    public var spawnFailures : int;
    public var lastError : string;
    public var lastHitFrac : float;
    public var hurtsCaptured : int;
    public var ghostHitsSeen : int;
    public var hurtsApplied : int;
    public var hurtsDodged : int;
    public var hurtDamageTaken : float;
    public var attacksSeen : int;
    public var attacksPlayed : int;
    public var attackPlayFailures : int;
    public var lastHurtDelay : float;
    public var hitReactionsMirrored : int;
    public var hitAnimsSeen : int;  // puppets entering a hit animation (shows the reactions really play)
    public var hurtEffectsApplied : int;
    public var journalApplied : int;
    public var lastJournalApplied : name;
    public var journalMessages : int;   // journal lists accepted from the leader
    public var journalMissing : int;    // entries this game could not find
    public var lastJournalSeen : string;
    public var trackedApplied : int;
    public var lastTrackedApplied : name;
    public var skipsApplied : int;
    public var lastJournalAppliedStatus : int;

    default lastHostSend = -999;
    default lastSnapshotAt = -999;
    default lastHitSend = -999;
    default lastHurtSend = -999;
    default lastJournalSend = -999;
    default journalIndexBuiltAt = -999;

    private function EnsureIds()
    {
        if(epoch == 0)
        {
            epoch = RandRange(1000000000, 1);
            session = RandRange(1000000000, 1);
            nextNetId = 1;
            nextHitSeq = 1;
            nextHurtSeq = 1;
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
            SendHurts(now);
            if(TrackingChanged())
            {
                lastJournalSend = -999;
            }
            SendJournal(now);
            wasHost = true;
        }
        else if(wasHost)
        {
            hostEnemies.Clear();
            hurts.Clear();
            DisarmGhosts();
            HostSend();
            SendHurts(now);
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
                hurtAck = 0;
                delayedHurts.Clear();
            }

            // the leader's snapshots also stop while its game sits in a menu; far from the leader, this world
            // runs its own monsters again
            if(now - lastSnapshotAt > 8.0 || !LeaderNear())
            {
                ReleaseAll();
            }
            else
            {
                UpdatePuppets(now);
            }
            ApplyDueHurts(now);
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
        var attitudeRef : CGameplayEntity;
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
            if(!globals[i] || !globals[i].inParty || globals[i].joinedParty != me || globals[i].area != area
                || VecDistance(globals[i].pos, thePlayer.GetWorldPosition()) > COOP_SHARE_RANGE())
            {
                continue;
            }

            // hostile to the member's ghost (armed below) as well as to this Geralt
            attitudeRef = GhostOf(globals[i].username);
            if(!attitudeRef)
            {
                attitudeRef = thePlayer;
            }
            entities.Clear();
            FindGameplayEntitiesInSphere(entities, globals[i].pos, 40, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors, attitudeRef);
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

        ArmGhosts(client);

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

    // "en epoch seq area acks{user session lastSeq} templates{path}
    //  enemies{netId tpl appearance x y z yaw hp alive attackSeq attackAnim hitSeq hitBy hitReaction}"
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
                + " " + alive + " " + e.attackSeq + " " + CoopEncode(NameToString(e.attackAnim))
                + " " + e.hitSeq + " " + CoopEncode(e.hitBy) + " " + e.hitReaction;
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

    // "hit leader epoch session hurtAck count {seq netId fraction}": all hits the member has not seen
    // acknowledged yet, and the last hurt it applied
    private function OnHits(sender : string, count : int)
    {
        var client : r_MultiplayerClient;
        var ack : r_CoopAck;
        var n, i, idx, seq : int;

        client = theGame.r_getMultiplayerClient();
        if(count < 6 || WO_Str(1) != client.getUsername() || StringToInt(WO_Str(2), 0) != epoch || !IsMyPartyMember(sender))
        {
            return;
        }

        PruneHurts(sender, StringToInt(WO_Str(4), 0));
        ack = FindAck(sender, StringToInt(WO_Str(3), 0));
        n = StringToInt(WO_Str(5), 0);
        idx = 6;
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
        var difficultyMult : float;

        e = FindHostEnemy(netId);
        if(!e || !e.npc || !e.npc.IsAlive() || frac <= 0)
        {
            return;
        }

        attacker = GhostOf(sender);

        // the damage processor scales an NPC attacker's damage by the NPC difficulty multiplier (3.3x was
        // measured); the member's game already applied its own stats, so divide that back out
        difficultyMult = 1;
        if(attacker && !attacker.IgnoresDifficultySettings())
        {
            difficultyMult = CalculateAttributeValue(attacker.GetAttributeValue(theGame.params.DIFFICULTY_DMG_MULTIPLIER));
            if(difficultyMult <= 0)
            {
                difficultyMult = 1;
            }
        }

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(attacker, e.npc, theGame, "W3Coop", EHRT_Light, CPS_Undefined, false, false, false, false);
        action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, MinF(frac, 1) * e.npc.GetMaxHealth() / difficultyMult);
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

    // Party members' ghosts join the player's attitude group and become gameplay-visible, so this game's
    // monsters attack them as they would the leader (they stay invulnerable). Undone when they leave.
    private function ArmGhosts(client : r_MultiplayerClient)
    {
        var players : array<r_RemotePlayer>;
        var wanted : array<CActor>;
        var ghost : CActor;
        var i : int;

        players = client.getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].ghost && IsMyPartyMember(players[i].username))
            {
                wanted.PushBack(players[i].ghost);
            }
        }

        for(i = armedGhosts.Size() - 1; i >= 0; i -= 1)
        {
            if(!wanted.Contains(armedGhosts[i]))
            {
                Disarm(armedGhosts[i]);
                armedGhosts.Erase(i);
            }
        }

        for(i = 0; i < wanted.Size(); i += 1)
        {
            ghost = wanted[i];
            if(!armedGhosts.Contains(ghost))
            {
                ghost.SetTemporaryAttitudeGroup(thePlayer.GetAttitudeGroup(), AGP_Default);
                armedGhosts.PushBack(ghost);
            }
            // Witcher Online hides ghosts from gameplay again in some states (e.g. mounting)
            ghost.SetGameplayVisibility(true);
        }
    }

    private function Disarm(ghost : CActor)
    {
        if(ghost)
        {
            ghost.SetTemporaryAttitudeGroup('friendly_to_player', AGP_Default);
            ghost.SetGameplayVisibility(false);
        }
    }

    private function DisarmGhosts()
    {
        var i : int;

        for(i = 0; i < armedGhosts.Size(); i += 1)
        {
            Disarm(armedGhosts[i]);
        }
        armedGhosts.Clear();
    }

    private function GhostOwner(ghost : CActor) : string
    {
        var players : array<r_RemotePlayer>;
        var i : int;

        players = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].ghost == ghost && IsMyPartyMember(players[i].username))
            {
                return players[i].username;
            }
        }
        return "";
    }

    // Called for every damage action before it is processed; true drops it. On the leader, a shared
    // monster's hit on a member's ghost is recorded for that member, and ghosts' own AI deals no damage
    // (members' hits arrive as claims instead).
    public function OnBeforeDamage(act : W3DamageAction) : bool
    {
        var attacker, victim : CActor;
        var e : r_CoopHostEnemy;
        var user : string;

        attacker = (CActor)act.attacker;
        victim = (CActor)act.victim;

        // a member's puppets only hurt it through the leader's hits
        if((CNewNPC)attacker && IsPuppet((CNewNPC)attacker) && act.GetBuffSourceName() != "W3CoopHurt")
        {
            return true;
        }

        if(!wasHost)
        {
            return false;
        }
        if(attacker && attacker.HasTag('MPEntity') && act.GetBuffSourceName() != "W3Coop")
        {
            return true;
        }

        if(victim && victim.HasTag('MPEntity') && !act.IsDoTDamage())
        {
            ghostHitsSeen += 1;
            e = FindHostEnemyByNpc((CNewNPC)attacker);
            user = GhostOwner(victim);
            if(e && user != "")
            {
                QueueHurt(user, e, act);
            }
        }
        return false;
    }

    private function QueueHurt(user : string, e : r_CoopHostEnemy, act : W3DamageAction)
    {
        var dts : array<SRawDamage>;
        var effects : array<EEffectType>;
        var h : r_CoopHurt;
        var i : int;

        h = new r_CoopHurt in this;
        act.GetEffectTypes(effects);
        for(i = 0; i < effects.Size(); i += 1)
        {
            h.effects.PushBack((int)effects[i]);
        }
        act.GetDTs(dts);
        for(i = 0; i < dts.Size(); i += 1)
        {
            if(dts[i].dmgVal > 0)
            {
                h.types.PushBack(dts[i].dmgType);
                h.values.PushBack(dts[i].dmgVal);
            }
        }
        if(h.types.Size() == 0)
        {
            return;
        }

        h.user = user;
        h.seq = nextHurtSeq;
        h.netId = e.netId;
        h.hitReaction = (int)act.GetHitReactionType();
        h.attackSeq = e.attackSeq;
        h.hitAnimTime = e.hitAnimTime;
        nextHurtSeq += 1;
        hurts.PushBack(h);
        if(hurts.Size() > 16)
        {
            hurts.Erase(0);
        }
        hurtsCaptured += 1;
        lastHurtSend = -999;
    }

    private function PruneHurts(user : string, lastSeq : int)
    {
        var i : int;

        for(i = hurts.Size() - 1; i >= 0; i -= 1)
        {
            if(hurts[i].user == user && hurts[i].seq <= lastSeq)
            {
                hurts.Erase(i);
            }
        }
    }

    // "hurt epoch count {user seq netId hitReaction attackSeq hitAnimTime types {type value} effects {type}}": every
    // hurt not yet acknowledged
    private function SendHurts(now : float)
    {
        var text : string;
        var h : r_CoopHurt;
        var i, j : int;

        if((hurts.Size() == 0 && lastHurtSentCount == 0) || now - lastHurtSend < 0.1)
        {
            return;
        }

        text = "coop hurt " + epoch + " " + hurts.Size();
        for(i = 0; i < hurts.Size(); i += 1)
        {
            h = hurts[i];
            text += " " + h.user + " " + h.seq + " " + h.netId + " " + h.hitReaction + " " + h.attackSeq
                + " " + FloatToStringPrec(h.hitAnimTime, 2) + " " + h.types.Size();
            for(j = 0; j < h.types.Size(); j += 1)
            {
                text += " " + NameToString(h.types[j]) + " " + FloatToStringPrec(h.values[j], 2);
            }
            text += " " + h.effects.Size();
            for(j = 0; j < h.effects.Size(); j += 1)
            {
                text += " " + h.effects[j];
            }
        }
        WO_Send(text);
        lastHurtSend = now;
        lastHurtSentCount = hurts.Size();
    }

    // A shared monster started (AET_DurationStart) or finished (AET_DurationEnd, where the hit is processed) an
    // attack's hit window. Members replay the animation on its puppet.
    public function OnEnemyAttack(npc : CNewNPC, eventType : EAnimationEventType, animInfo : SAnimationEventAnimInfo)
    {
        var e : r_CoopHostEnemy;

        if(!wasHost)
        {
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }

        if(eventType == AET_DurationStart)
        {
            e.attackSeq += 1;
            e.attackAnim = GetAnimNameFromEventAnimInfo(animInfo);
            e.hitAnimTime = GetLocalAnimTimeFromEventAnimInfo(animInfo);
            attacksSeen += 1;
            lastHostSend = -999;  // send it now, not on the next 100 ms tick
        }
        else if(eventType == AET_DurationEnd)
        {
            e.hitAnimTime = GetLocalAnimTimeFromEventAnimInfo(animInfo);
        }
    }

    // A shared monster took damage here: members replay the hit reaction on its puppet (the hitter's own game
    // already played it).
    public function OnEnemyDamaged(npc : CNewNPC, action : W3DamageAction)
    {
        var e : r_CoopHostEnemy;
        var attacker : CActor;

        if(!wasHost || !action.DealsAnyDamage() || action.IsDoTDamage())
        {
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }

        attacker = (CActor)action.attacker;
        e.hitBy = "";
        if(attacker == thePlayer)
        {
            e.hitBy = theGame.r_getMultiplayerClient().getUsername();
        }
        else if(attacker && attacker.HasTag('MPEntity'))
        {
            e.hitBy = GhostOwner(attacker);
        }
        e.hitSeq += 1;
        e.hitReaction = (int)action.GetHitReactionType();
        lastHostSend = -999;
    }

    public function PendingHurtCount() : int
    {
        return hurts.Size();
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
        else if(WO_Str(0) == "hurt")
        {
            OnHurts(sender, count);
        }
        else if(WO_Str(0) == "jr")
        {
            OnJournal(sender, count);
        }
    }

    private function OnSnapshot(sender : string, count : int)
    {
        var templates : array<string>;
        var seen : array<int>;
        var pos : Vector;
        var attackAnim : name;
        var hitBy : string;
        var snapshotEpoch, n, i, idx, netId, tplIndex, attackSeq, hitSeq, hitReaction : int;
        var hp, yaw : float;
        var alive : bool;
        var app : string;

        if(GetRole() != 2 || sender != leaderName || count < 4)
        {
            return;
        }

        if(StringToInt(WO_Str(3), 0) != WO_CurrentAreaCode() || !LeaderNear())
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
            hurtAck = 0;
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
        for(i = 0; i < n && idx + 13 < count; i += 1)
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
            attackSeq = StringToInt(WO_Str(idx + 9), 0);
            attackAnim = '';
            if(WO_Str(idx + 10) != "-")
            {
                attackAnim = WO_NameAt(idx + 10);
            }
            hitSeq = StringToInt(WO_Str(idx + 11), 0);
            hitBy = CoopDecode(WO_Str(idx + 12));
            hitReaction = StringToInt(WO_Str(idx + 13), 0);
            idx += 14;

            if(tplIndex >= 0 && tplIndex < templates.Size())
            {
                ApplyEnemy(netId, templates[tplIndex], app, pos, yaw, hp, alive, attackSeq, attackAnim, hitSeq, hitBy, hitReaction);
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

    private function OnHurts(sender : string, count : int)
    {
        var me, user : string;
        var listed : bool;
        var h : r_CoopHurt;
        var p : r_CoopPuppet;
        var now : float;
        var n, i, j, idx, seq, typeCount, effectCount, effectsAt : int;

        if(GetRole() != 2 || sender != leaderName || leaderEpoch == 0 || count < 3 || StringToInt(WO_Str(1), 0) != leaderEpoch)
        {
            return;
        }

        me = theGame.r_getMultiplayerClient().getUsername();
        now = theGame.GetEngineTimeAsSeconds();
        n = StringToInt(WO_Str(2), 0);
        idx = 3;
        for(i = 0; i < n && idx + 6 < count; i += 1)
        {
            user = WO_Str(idx);
            seq = StringToInt(WO_Str(idx + 1), 0);
            typeCount = StringToInt(WO_Str(idx + 6), 0);
            effectsAt = idx + 7 + typeCount * 2;
            if(effectsAt >= count)
            {
                break;
            }
            effectCount = StringToInt(WO_Str(effectsAt), 0);
            if(effectsAt + 1 + effectCount > count)
            {
                break;
            }
            if(user == me)
            {
                listed = true;
                if(seq > hurtAck)
                {
                    h = new r_CoopHurt in this;
                    h.seq = seq;
                    h.netId = StringToInt(WO_Str(idx + 2), 0);
                    h.hitReaction = StringToInt(WO_Str(idx + 3), 0);
                    h.attackSeq = StringToInt(WO_Str(idx + 4), 0);
                    h.hitAnimTime = StringToFloat(WO_Str(idx + 5), 0);
                    for(j = 0; j < typeCount; j += 1)
                    {
                        h.types.PushBack(WO_NameAt(idx + 7 + j * 2));
                        h.values.PushBack(StringToFloat(WO_Str(idx + 8 + j * 2), 0));
                    }
                    for(j = 0; j < effectCount; j += 1)
                    {
                        h.effects.PushBack(StringToInt(WO_Str(effectsAt + 1 + j), 0));
                    }

                    // land it when this world's copy of the swing reaches the hit (immediately if this world
                    // missed that attack); a dodge before then avoids it
                    h.receivedAt = now;
                    h.due = now;
                    p = FindPuppet(h.netId);
                    if(p && p.alive && p.attackSeq == h.attackSeq && p.attackPlayedAt > 0)
                    {
                        h.due = MaxF(now, p.attackPlayedAt + MinF(h.hitAnimTime, 1.5));
                    }
                    delayedHurts.PushBack(h);
                    hurtAck = seq;
                }
            }
            idx = effectsAt + 1 + effectCount;
        }
        leaderListsMyHurts = listed;
    }

    private function ApplyDueHurts(now : float)
    {
        var i : int;

        for(i = 0; i < delayedHurts.Size(); i += 1)
        {
            if(delayedHurts[i].due <= now)
            {
                lastHurtDelay = now - delayedHurts[i].receivedAt;
                ApplyHurt(delayedHurts[i]);
                delayedHurts.Erase(i);
                i -= 1;
            }
        }
    }

    // The leader's monster hit this player's ghost: apply its raw damage here, with the monster's local copy
    // as attacker, so this game's armor, Quen and difficulty count. A hit landing mid-dodge misses.
    private function ApplyHurt(h : r_CoopHurt)
    {
        var action : W3DamageAction;
        var p : r_CoopPuppet;
        var attacker : CActor;
        var before : float;
        var i : int;

        if(thePlayer.IsCurrentlyDodging())
        {
            hurtsDodged += 1;
            return;
        }

        p = FindPuppet(h.netId);
        if(p && p.alive)
        {
            attacker = p.npc;
        }

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(attacker, thePlayer, theGame, "W3CoopHurt", (EHitReactionType)h.hitReaction, CPS_AttackPower, true, false, false, false);
        for(i = 0; i < h.types.Size(); i += 1)
        {
            action.AddDamage(h.types[i], h.values[i]);
        }
        // the monster's buffs; this game's immunities and resistances decide whether they take hold
        for(i = 0; i < h.effects.Size(); i += 1)
        {
            action.AddEffectInfo((EEffectType)h.effects[i]);
        }
        hurtEffectsApplied += h.effects.Size();
        before = thePlayer.GetStat(BCS_Vitality);
        theGame.damageMgr.ProcessAction(action);
        delete action;
        hurtDamageTaken += MaxF(0, before - thePlayer.GetStat(BCS_Vitality));
        hurtsApplied += 1;
    }

    private function ApplyEnemy(netId : int, tpl : string, app : string, pos : Vector, yaw : float, hp : float, alive : bool,
        attackSeq : int, attackAnim : name, hitSeq : int, hitBy : string, hitReaction : int)
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
            p.attackSeq = attackSeq;  // don't replay an attack or a hit from before this puppet existed
            p.hitSeq = hitSeq;
        }

        // hits by others (this player's own hits already reacted here)
        if(hitSeq != p.hitSeq)
        {
            p.hitSeq = hitSeq;
            if(p.alive && hitBy != "" && hitBy != theGame.r_getMultiplayerClient().getUsername())
            {
                MirrorHit(p, hitBy, hitReaction);
            }
        }

        if(attackSeq != p.attackSeq)
        {
            p.attackSeq = attackSeq;
            if(p.alive && IsNameValid(attackAnim))
            {
                PlayAttack(p, attackAnim);
            }
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
        // a finisher would kill it here, outside the leader's say ('DisableFinishers' blocks the killing-blow
        // finisher, 'DisableFinisher' the one on a living target)
        BlockFinisher(p, 'DisableFinishers');
        BlockFinisher(p, 'DisableFinisher');
        puppets.PushBack(p);
        return p;
    }

    // Replays another player's hit on a puppet through the damage manager with a negligible damage, so the
    // vanilla reaction path runs (the leader's health is restored right after).
    // The forced idle tree swallows hit reactions; lift it briefly so the monster's own AI plays one. Its
    // attacks in that time do no damage here (OnBeforeDamage drops a puppet's own damage).
    private function OpenReactionWindow(p : r_CoopPuppet)
    {
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        p.reactUntil = theGame.GetEngineTimeAsSeconds() + 0.8;
    }

    private function MirrorHit(p : r_CoopPuppet, hitBy : string, hitReaction : int)
    {
        var action : W3DamageAction;

        OpenReactionWindow(p);

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(GhostOf(hitBy), p.npc, theGame, "W3CoopHitFx", (EHitReactionType)hitReaction, CPS_Undefined, true, false, false, false);
        action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, COOP_FX_DAMAGE());
        action.SetCannotReturnDamage(true);
        applyingHostState = true;
        theGame.damageMgr.ProcessAction(action);
        applyingHostState = false;
        delete action;
        hitReactionsMirrored += 1;
    }

    private function BlockFinisher(p : r_CoopPuppet, ability : name)
    {
        if(!p.npc.HasAbility(ability))
        {
            p.npc.AddAbility(ability, false);
            p.addedNoFinishers.PushBack(ability);
        }
    }

    // Through the AI, above the forced idle tree (a direct ActionPlaySlotAnimationAsync is refused while that
    // tree owns the puppet's actions); when the animation ends the puppet is idle again.
    private function PlayAttack(p : r_CoopPuppet, anim : name)
    {
        var action : CAIPlayAnimationSlotAction;

        p.attackPlayedAt = theGame.GetEngineTimeAsSeconds();
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
        }
        action = new CAIPlayAnimationSlotAction in p.npc;
        action.OnCreated();
        action.animName = anim;
        action.slotName = 'NPC_ANIM_SLOT';
        action.blendInTime = 0.1;
        action.blendOutTime = 0.2;
        p.animAiId = p.npc.ForceAIBehavior(action, BTAP_Emergency);
        if(p.animAiId != 0)
        {
            attacksPlayed += 1;
        }
        else
        {
            attackPlayFailures += 1;
            lastError = "attack animation '" + NameToString(anim) + "' did not play";
        }
    }

    // within sharing range of the leader, in the same area
    private function LeaderNear() : bool
    {
        var globals : array<r_RemotePlayer>;
        var i : int;

        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == leaderName)
            {
                return globals[i].area == WO_CurrentAreaCode()
                    && VecDistance(globals[i].pos, thePlayer.GetWorldPosition()) <= COOP_SHARE_RANGE();
            }
        }
        return false;
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

            if(p.npc.IsInHitAnim() && !p.wasInHitAnim)
            {
                hitAnimsSeen += 1;
            }
            p.wasInHitAnim = p.npc.IsInHitAnim();

            if(p.aiId == 0 && now >= p.reactUntil)
            {
                p.aiId = ForceIdle(p.npc);
            }

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
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
            p.animAiId = 0;
        }
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
        var i : int;

        if(!p.npc || !p.alive)
        {
            return;
        }
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
            p.animAiId = 0;
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
        else
        {
            for(i = 0; i < p.addedNoFinishers.Size(); i += 1)
            {
                p.npc.RemoveAbility(p.addedNoFinishers[i]);
            }
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
        delayedHurts.Clear();

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
        if(FindPuppetByNpc(npc))
        {
            return true;
        }
        return false;
    }

    // damage the local player dealt to a puppet (after this game's stats, resistances and crits) goes to the
    // leader as a fraction of max health; the caller then zeroes it here
    public function OnPuppetDamaged(npc : CNewNPC, action : W3DamageAction)
    {
        var p : r_CoopPuppet;
        var hit : r_CoopHit;
        var dmg, maxHp : float;

        p = FindPuppetByNpc(npc);
        if(!p || !p.alive)
        {
            return;
        }
        OpenReactionWindow(p);
        if(action.attacker != thePlayer)
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
        lastHitFrac = hit.frac;
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

        if(pendingHits.Size() == 0 && lastHitSentCount == 0 && hurtAck == lastSentHurtAck && !leaderListsMyHurts)
        {
            return;
        }
        if(now - lastHitSend < 0.1)
        {
            return;
        }

        text = "coop hit " + leaderName + " " + leaderEpoch + " " + session + " " + hurtAck + " " + pendingHits.Size();
        for(i = 0; i < pendingHits.Size(); i += 1)
        {
            text += " " + pendingHits[i].seq + " " + pendingHits[i].netId + " " + FloatToStringPrec(pendingHits[i].frac, 4);
        }
        WO_Send(text);
        lastHitSend = now;
        lastHitSentCount = pendingHits.Size();
        lastSentHurtAck = hurtAck;
    }

    // ---------------------------------------------------------------- journal (milestone 3)

    // Every game records its quest and objective updates (the HUD hears about all of them, also the quest
    // system's own); the leader sends them, and members apply the ones that move them forward.
    public function OnJournalChange(journalEntry : CJournalBase)
    {
        var tag : name;
        var status, i : int;

        if(!journalEntry || applyingJournal)
        {
            return;
        }
        tag = journalEntry.GetUniqueScriptTag();
        if(!IsNameValid(tag))
        {
            return;
        }
        status = (int)theGame.GetJournalManager().GetEntryStatus(journalEntry);

        i = journalTags.FindFirst(tag);
        if(i < 0)
        {
            journalTags.PushBack(tag);
            journalStatus.PushBack(status);
            if(journalTags.Size() > 48)
            {
                journalTags.Erase(0);
                journalStatus.Erase(0);
            }
        }
        else
        {
            journalStatus[i] = status;
        }
        lastJournalSend = -999;
    }

    private function TrackingChanged() : bool
    {
        var manager : CWitcherJournalManager;
        var trackedTag, highlightedTag : name;

        manager = theGame.GetJournalManager();
        if(manager.GetTrackedQuest())
        {
            trackedTag = manager.GetTrackedQuest().GetUniqueScriptTag();
        }
        if(manager.GetHighlightedObjective())
        {
            highlightedTag = manager.GetHighlightedObjective().GetUniqueScriptTag();
        }
        if(trackedTag == sentTrackedQuest && highlightedTag == sentHighlighted)
        {
            return false;
        }
        sentTrackedQuest = trackedTag;
        sentHighlighted = highlightedTag;
        return true;
    }

    // "jr epoch tick trackedQuest highlightedObjective scene skipSeq skipValue count {tag status}"; the tick
    // changes every send so a member that joins later still gets it (the client passes unchanged state once)
    private function SendJournal(now : float)
    {
        var text : string;
        var i : int;

        if(now - lastJournalSend < 1.0)
        {
            return;
        }
        journalTick += 1;
        text = "coop jr " + epoch + " " + journalTick + " " + CoopEncode(NameToString(sentTrackedQuest))
            + " " + CoopEncode(NameToString(sentHighlighted)) + " " + CoopEncode(currentScene) + " " + sceneSkipSeq
            + " " + sceneSkipValue + " " + journalTags.Size();
        for(i = 0; i < journalTags.Size(); i += 1)
        {
            // tags can contain spaces ("Win unique card from crossroads innkeeper A485F434-...")
            text += " " + CoopEncode(NameToString(journalTags[i])) + " " + journalStatus[i];
        }
        WO_Send(text);
        lastJournalSend = now;
    }

    private function OnJournal(sender : string, count : int)
    {
        var manager : CWitcherJournalManager;
        var journalEntry : CJournalBase;
        var tag, trackedTag, highlightedTag : name;
        var status, current, n, i, idx : int;

        if(GetRole() != 2 || sender != leaderName || leaderEpoch == 0 || count < 9 || StringToInt(WO_Str(1), 0) != leaderEpoch)
        {
            return;
        }

        manager = theGame.GetJournalManager();
        journalMessages += 1;
        if(WO_Str(3) != "-")
        {
            trackedTag = WO_NameAt(3);
        }
        if(WO_Str(4) != "-")
        {
            highlightedTag = WO_NameAt(4);
        }
        ApplyLeaderSkip(CoopDecode(WO_Str(5)), StringToInt(WO_Str(6), 0), StringToInt(WO_Str(7), 0));

        n = StringToInt(WO_Str(8), 0);
        idx = 9;
        for(i = 0; i < n && idx + 1 < count; i += 1)
        {
            // the client restores the spaces of encoded fields, so this is the exact tag
            tag = WO_NameAt(idx);
            status = StringToInt(WO_Str(idx + 1), 0);
            idx += 2;

            lastJournalSeen = NameToString(tag) + "=" + status;
            journalEntry = FindJournalEntry(tag);
            if(!journalEntry)
            {
                journalMissing += 1;
                continue;
            }
            current = (int)manager.GetEntryStatus(journalEntry);
            if(JournalAdvances(current, status))
            {
                applyingJournal = true;
                manager.ActivateEntry(journalEntry, (EJournalStatus)status, true, true);
                applyingJournal = false;
                journalApplied += 1;
                lastJournalApplied = tag;
                lastJournalAppliedStatus = status;
            }
        }

        // after the statuses: a quest the leader just activated can be tracked here too
        ApplyLeaderTracking(trackedTag, highlightedTag);
    }

    // The leader's tracked quest and highlighted objective, applied when the leader changes them (so a member
    // can still track something else in between) and only for quests that are active here.
    private function ApplyLeaderTracking(trackedTag : name, highlightedTag : name)
    {
        var manager : CWitcherJournalManager;
        var journalQuest : CJournalQuest;
        var journalObjective : CJournalQuestObjective;

        manager = theGame.GetJournalManager();
        if(trackedTag != leaderTrackedQuest)
        {
            journalQuest = (CJournalQuest)FindJournalEntry(trackedTag);
            if(!IsNameValid(trackedTag) || (journalQuest && manager.GetEntryStatus(journalQuest) == JS_Active))
            {
                leaderTrackedQuest = trackedTag;
            }
            if(journalQuest && manager.GetEntryStatus(journalQuest) == JS_Active && manager.GetTrackedQuest() != journalQuest)
            {
                manager.SetTrackedQuest(journalQuest);
                trackedApplied += 1;
                lastTrackedApplied = trackedTag;
            }
        }
        if(highlightedTag != leaderHighlighted)
        {
            journalObjective = (CJournalQuestObjective)FindJournalEntry(highlightedTag);
            if(!IsNameValid(highlightedTag) || (journalObjective && manager.GetEntryStatus(journalObjective) == JS_Active))
            {
                leaderHighlighted = highlightedTag;
            }
            if(journalObjective && manager.GetEntryStatus(journalObjective) == JS_Active)
            {
                manager.SetHighlightedObjective(journalObjective);
            }
        }
    }

    // ---------------------------------------------------------------- scenes

    public function OnSceneStarted(scene : CStoryScene)
    {
        if(scene)
        {
            currentScene = scene.GetPath();
        }
    }

    public function OnSceneEnded()
    {
        currentScene = "";
    }

    // the bots have no quest scene to share; they name one
    public function SetSceneForTest(path : string)
    {
        currentScene = path;
    }

    // The leader skipped a line or cutscene: members in the same scene skip with it.
    public function OnLocalSkip(value : int)
    {
        if(!wasHost || applyingSkip)
        {
            return;
        }
        sceneSkipSeq += 1;
        sceneSkipValue = value;
        lastJournalSend = -999;
    }

    private function ApplyLeaderSkip(scene : string, skipSeq : int, skipValue : int)
    {
        var count, i : int;

        // a new scene of the leader's: its earlier skips belong to another scene
        if(scene != leaderSceneSeen)
        {
            leaderSceneSeen = scene;
            leaderSkipSeen = skipSeq;
            return;
        }
        if(skipSeq <= leaderSkipSeen)
        {
            return;
        }
        count = Min(skipSeq - leaderSkipSeen, 3);
        leaderSkipSeen = skipSeq;
        if(scene == "" || scene != currentScene)
        {
            return;
        }

        applyingSkip = true;
        for(i = 0; i < count; i += 1)
        {
            theGame.GetStorySceneSystem().SendSignal(SSST_Skip, skipValue);
        }
        applyingSkip = false;
        skipsApplied += count;
    }

    private function FindJournalEntry(tag : name) : CJournalBase
    {
        var journalEntry : CJournalBase;
        var i : int;

        journalEntry = theGame.GetJournalManager().GetEntryByTag(tag);
        if(journalEntry)
        {
            return journalEntry;
        }

        i = journalIndexTags.FindFirst(tag);
        if(i < 0 && theGame.GetEngineTimeAsSeconds() - journalIndexBuiltAt > 5.0)
        {
            BuildJournalIndex();
            i = journalIndexTags.FindFirst(tag);
        }
        if(i >= 0)
        {
            return journalIndexEntries[i];
        }
        return NULL;
    }

    // Quests this game knows and their objectives, by unique tag: GetEntryByTag doesn't find objectives that
    // are still inactive here (the map menu walks the same hierarchy).
    private function BuildJournalIndex()
    {
        var quests : array<CJournalBase>;
        var journalQuest : CJournalQuest;
        var phase : CJournalQuestPhase;
        var child : CJournalBase;
        var i, j, k : int;

        journalIndexTags.Clear();
        journalIndexEntries.Clear();
        theGame.GetJournalManager().GetActivatedOfType('CJournalQuest', quests);
        for(i = 0; i < quests.Size(); i += 1)
        {
            journalQuest = (CJournalQuest)quests[i];
            if(!journalQuest)
            {
                continue;
            }
            journalIndexTags.PushBack(journalQuest.GetUniqueScriptTag());
            journalIndexEntries.PushBack(journalQuest);
            for(j = 0; j < journalQuest.GetNumChildren(); j += 1)
            {
                phase = (CJournalQuestPhase)journalQuest.GetChild(j);
                if(!phase)
                {
                    continue;
                }
                for(k = 0; k < phase.GetNumChildren(); k += 1)
                {
                    child = phase.GetChild(k);
                    if((CJournalQuestObjective)child)
                    {
                        journalIndexTags.PushBack(child.GetUniqueScriptTag());
                        journalIndexEntries.PushBack(child);
                    }
                }
            }
        }
        journalIndexBuiltAt = theGame.GetEngineTimeAsSeconds();
    }

    // inactive -> active -> succeeded/failed; never back, never from one outcome to the other
    private function JournalAdvances(current : int, wanted : int) : bool
    {
        if(current == (int)JS_Inactive)
        {
            return wanted != (int)JS_Inactive;
        }
        if(current == (int)JS_Active)
        {
            return wanted == (int)JS_Success || wanted == (int)JS_Failed;
        }
        return false;
    }

    public function JournalStatusOf(tag : name) : int
    {
        var journalEntry : CJournalBase;

        journalEntry = FindJournalEntry(tag);
        if(!journalEntry)
        {
            return -1;
        }
        return (int)theGame.GetJournalManager().GetEntryStatus(journalEntry);
    }

    public function JournalRecorded(tag : name) : bool
    {
        return journalTags.Contains(tag);
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

    public function PuppetInHitAnim(i : int) : bool
    {
        return puppets[i].npc.IsInHitAnim();
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

// what a puppet keeps of a hit, so the vanilla hit reaction runs (its health is the leader's anyway)
function COOP_FX_DAMAGE() : float
{
    return 0.01;
}

// players farther apart than this run their own monsters (the leader's world doesn't simulate far away)
function COOP_SHARE_RANGE() : float
{
    return 60.0;
}

@wrapMethod(CNewNPC)
function OnPreAttackEvent(animEventName : name, animEventType : EAnimationEventType, data : CPreAttackEventData, animInfo : SAnimationEventAnimInfo)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnEnemyAttack(this, animEventType, animInfo);
    }
    return wrappedMethod(animEventName, animEventType, data, animInfo);
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

@wrapMethod(W3DamageManagerProcessor)
function ProcessAction(act : W3DamageAction)
{
    var client : r_MultiplayerClient;
    var coop : r_CoopEnemies;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        coop = client.getCoopEnemies();
    }
    if(coop && coop.OnBeforeDamage(act))
    {
        return;
    }

    wrappedMethod(act);
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
        // a negligible remainder instead of zero keeps the vanilla hit reaction (it needs damage dealt)
        action.SetAllProcessedDamageAs(0);
        action.processedDmg.vitalityDamage = COOP_FX_DAMAGE();
        action.processedDmg.essenceDamage = COOP_FX_DAMAGE();
    }
    else if(coop)
    {
        coop.OnEnemyDamaged(this, action);
    }

    wrappedMethod(action);
}

@wrapMethod(CR4ScriptedHud)
function OnQuestEvent(journalQuest : CJournalQuest)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnJournalChange(journalQuest);
    }
    return wrappedMethod(journalQuest);
}

@wrapMethod(CR4ScriptedHud)
function OnQuestObjectiveEvent(journalQuest : CJournalQuest, journalObjective : CJournalQuestObjective)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnJournalChange(journalQuest);
        client.getCoopEnemies().OnJournalChange(journalObjective);
    }
    return wrappedMethod(journalQuest, journalObjective);
}
