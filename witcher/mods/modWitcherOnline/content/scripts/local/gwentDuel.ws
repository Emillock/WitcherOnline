// Gwent duels on the 5.01 board: Witcher Online's additions to the vanilla CR4GwintManager and CR4GwintGameMenu.
// The rebuilt board (WitcherOnline\gwent) reads the flash values set here and calls the events below from Flash.
// Outside a duel (multiplayerSeed 0) the menu runs as vanilla; the board falls back to vanilla when gwint.game.seed is 0.
// gwentHooks.ws adds HandleOutgoingGwentAction and NotifyGwentMatchEnded, which hand messages and results to the client.
//
// Transport: the client sends the last 20 outbound messages as one "~"-joined window in its wo3 packet and hands the
// opponent's window to the board (gwint.game.remoteInput) whenever its counter changes. The client clears its window
// when a duel starts and WO_GwentWindowLingerSeconds() after one ends. Second line of defence: every message carries
// the match id (<seed hex>g<game number>), and the board's DuelWindow ignores messages of any other match id, so a
// window left from an earlier duel or game can never be applied to the current one.

// How long the window of a finished duel keeps being sent, so the last messages (final move, surrender, leave, desync
// report) still reach the opponent after this menu closed.
function WO_GwentWindowLingerSeconds() : float
{
    return 30.0;
}

// How long after a duel starts its board must have opened; without one the client leaves the duel (R49). The same
// limit as the board's own wait for the opponent's Hello (stuck-wait limit, spec 10).
function WO_GwentBoardOpenSeconds() : float
{
    return 120.0;
}

// How long the opponent's packets may stop during a duel before the client takes it as gone (its game closed or it
// lost its connection; r_MultiplayerClient.gwentOpponentSilent). Witcher Online drops a silent player after 5 s and
// the server after about 6 s; the opponent's packets come about 60 times a second. R50: well above both, so a relay
// hiccup does not end a duel; still far under the board's own 120 s stuck-wait limit.
function WO_GwentOpponentSilentSeconds() : float
{
    return 30.0;
}

// A gap longer than this between two calls of r_MultiplayerClient.gwentGameLoop is a stall on this side (a hitch):
// the opponent's packets may not have been read meanwhile, so the silence clock starts again (R50).
function WO_GwentLoopStallSeconds() : float
{
    return 3.0;
}

// Real milliseconds since startMs (theGame.GetLocalTimeAsMilliseconds, which runs on while a menu pauses the game,
// unlike engine time; it starts again from 0 at midnight).
function WO_GwentMsSince(startMs : int) : int
{
    var elapsed : int;

    elapsed = theGame.GetLocalTimeAsMilliseconds() - startMs;
    if(elapsed < 0)
    {
        elapsed += 86400000;
    }
    return elapsed;
}

// ---- duel protocol marker and deck exchange (wo3 packet) ----

// The Gwent duel protocol this build speaks. Clients only duel when both send the same value; raise it whenever the
// duel messages, the deck fields or the board's duel rules change incompatibly.
function WO_GwentProtocol() : int
{
    return 1;
}

// The wo3 packet's deck fields after the faction field: "gp<protocol> <leader> <specialCard> <card> <card> ...".
// Card names never contain spaces in 5.01 (all 228 names match [A-Za-z0-9_]+); a space (a card mod) is sent as %20.
// An empty name is "_". 4.04 clients send "<leaderIndex> <cardIndex> ..." here, which has no marker.
function WO_GwentDeckFields(deck : SDeckDefinition) : string
{
    var fields : string;
    var i : int;

    fields = "gp" + IntToString(WO_GwentProtocol()) + " " + WO_GwentEncodeName(deck.leaderCard) + " "
        + WO_GwentEncodeName(deck.specialCard);
    for(i = 0; i < deck.cards.Size(); i += 1)
    {
        fields += " " + WO_GwentEncodeName(deck.cards[i]);
    }
    return fields;
}

// Reads the wo3 deck fields (gwentData: the faction field, then WO_GwentDeckFields). Returns the sender's protocol
// marker, 0 when there is none (a 4.04 or an older 5.x client) or it is malformed. `deck` gets the cards only when the
// marker is this build's protocol, else it stays empty.
function WO_GwentParseDeck(gwentData : string, out deck : SDeckDefinition) : int
{
    var tokens : array<string>;
    var empty : SDeckDefinition;
    var protocol : int;
    var i : int;

    deck = empty;
    tokens = WO_GwentSplit(gwentData);
    if(tokens.Size() < 2 || !StrBeginsWith(tokens[1], "gp"))
    {
        return 0;
    }
    protocol = StringToInt(StrAfterFirst(tokens[1], "gp"), 0);
    if(protocol <= 0)
    {
        return 0;
    }
    if(protocol != WO_GwentProtocol() || tokens.Size() < 4)
    {
        return protocol;
    }

    deck.deckName = WO_GwentDuelDeckName();
    deck.leaderCard = WO_GwentDecodeName(tokens[2]);
    deck.specialCard = WO_GwentDecodeName(tokens[3]);
    deck.unlocked = true;
    for(i = 4; i < tokens.Size(); i += 1)
    {
        deck.cards.PushBack(WO_GwentDecodeName(tokens[i]));
    }
    return protocol;
}

function WO_GwentEncodeName(n : name) : string
{
    if(!IsNameValid(n))
    {
        return "_";
    }
    return StrReplaceAll(NameToString(n), " ", "%20");
}

function WO_GwentDecodeName(token : string) : name
{
    if(token == "_" || token == "")
    {
        return '';
    }
    return WO_ToName(StrReplaceAll(token, "%20", " "));
}

// The non-empty words of `text` (split on single spaces).
function WO_GwentSplit(text : string) : array<string>
{
    var words : array<string>;
    var word : string;
    var rest : string;

    rest = text;
    while(StrSplitFirst(rest, " ", word, rest))
    {
        if(word != "")
        {
            words.PushBack(word);
        }
    }
    if(rest != "")
    {
        words.PushBack(rest);
    }
    return words;
}

// ---- duel state on the Gwent manager (set by r_MultiplayerClient.startGwentGame, cleared when the duel ends) ----

// The duel's shared seed; 0 means no duel.
@addField(CR4GwintManager)
var multiplayerSeed : int;

// Whether this client sent the challenge.
@addField(CR4GwintManager)
var multiplayerIsHost : bool;

// Timed mode (60 s turns).
@addField(CR4GwintManager)
var multiplayerIsTimed : bool;

// The opponent's deck, built from the names in its wo3 packet.
@addField(CR4GwintManager)
var multiplayerEnemyDeck : SDeckDefinition;

// Test switches, only test tools (the w3test bot) set them; a normal player keeps them all off. They go to the board as
// gwint.game.debug.* each time the Gwent menu opens. duelSelfTest runs the board's self-test of the duel classes
// (DuelSelfTest), which reports "DUEL SELFTEST pass=<n> fail=<m>" through OnDuelLog.
@addField(CR4GwintManager)
var duelSelfTest : bool;

@addField(CR4GwintManager)
var duelDebugAutoplay : bool;

// Autoplay redraws at the mulligan instead of declining.
@addField(CR4GwintManager)
var duelDebugMulligan : bool;

// Autoplay plays its leader as soon as it can be used (the leader decisions the vanilla AI never picks).
@addField(CR4GwintManager)
var duelDebugLeaderFirst : bool;

// The outbound sequence number the board corrupts (0: off; -1: the end of game message).
@addField(CR4GwintManager)
var duelDebugCorruptAt : int;

// Game 0 of the duel ends as a draw whatever the score.
@addField(CR4GwintManager)
var duelDebugForceDraw : bool;

// On a draw, autoplay presses Replay instead of closing the end screen.
@addField(CR4GwintManager)
var duelDebugReplay : bool;

@addField(CR4GwintManager)
var duelDebugBreakTemplates : bool;

// The board gets seed 0 and so runs as the vanilla board, without duel code, while this script still treats the menu
// as a duel: what a client without the rebuilt board does (its close must settle nothing).
@addField(CR4GwintManager)
var duelDebugNoBoard : bool;

// Makes the next Gwent menu a duel against `deck`.
@addMethod(CR4GwintManager)
public function SetEnemyDeckFromMultiplayer(deck : SDeckDefinition)
{
    multiplayerEnemyDeck = deck;
}

@addMethod(CR4GwintManager)
public function IsMultiplayerGame() : bool
{
    return multiplayerSeed != 0;
}

// Back to single-player Gwent.
@addMethod(CR4GwintManager)
public function ClearMultiplayerState()
{
    var empty : SDeckDefinition;

    multiplayerSeed = 0;
    multiplayerIsHost = false;
    multiplayerIsTimed = false;
    multiplayerEnemyDeck = empty;
}

// ---- duel state on the open menu ----

// The seed this menu opened with (0: a single-player match). Read once at OnConfigUI, so the close still knows it was a
// duel after the client clears its own state.
@addField(CR4GwintGameMenu)
var duelSeed : int;

// The board ended a draw without a replay (OnMultiplayerDraw). Contract with the board (Task 14): it calls
// OnMultiplayerDraw only when the match ends as a draw that is not replayed. Defensively the flag is also cleared by a
// later result (OnMatchResult), a surrender (OnQuitGameConfirmed: a surrender is a loss, not a draw), the menu opening
// and a new game of the duel (a new match id).
@addField(CR4GwintGameMenu)
var duelDraw : bool;

// The board cancelled the duel game as no contest (OnMultiplayerAbort). Sticky for the rest of that game: a later
// result or a surrender does not clear it, and the close then settles nothing (no settleGwentBet, no
// NotifyGwentMatchEnded), so a player who leaves an aborted board through the surrender popup pays nothing. Only the
// menu opening and a new game of the duel (a new match id) clear it.
@addField(CR4GwintGameMenu)
var duelAborted : bool;

// The match id of the last outbound message ("<seed hex>g<game number>"); a different one means a new game started.
@addField(CR4GwintGameMenu)
var duelMatchId : string;

@addField(CR4GwintGameMenu)
var duelAbortReason : string;

// The board sent its Hello: an outbound H of this build's duel protocol (WO_GwentProtocol()), so this menu runs
// Witcher Online's rebuilt duel board. A board that never does (the vanilla 5.01 board, the 4.04 bundle or another
// Gwent mod in its place) plays the opponent's deck with the vanilla AI, and the close of such a duel settles nothing
// (no contest, reason "board"); the opponent ends by its own Hello wait as no contest too. The Hello is sent once per
// duel, so only the menu opening clears it, not a replayed game.
@addField(CR4GwintGameMenu)
var duelBoardSpoke : bool;

// The board sent the end of game message (E) of the current game: from then on the end confirmation settles that game,
// and a surrender popup that stayed open across the end is not taken (OnQuitGameConfirmed). Cleared with the end
// signals, and when the board starts the next game after a replay (OnDuelLog, "DUEL GAME ").
@addField(CR4GwintGameMenu)
var duelEndSent : bool;

@addMethod(CR4GwintGameMenu)
function IsDuel() : bool
{
    return duelSeed != 0;
}

@wrapMethod(CR4GwintGameMenu)
function OnConfigUI()
{
    var manager : CR4GwintManager;
    var client : r_MultiplayerClient;

    manager = theGame.GetGwintManager();
    client = theGame.r_getMultiplayerClient();
    duelSeed = 0;
    if(client && client.getInGwentGame())
    {
        duelSeed = manager.multiplayerSeed;
    }
    else if(manager.IsMultiplayerGame())
    {
        // left over from a duel whose menu never opened: this is a single-player match
        manager.ClearMultiplayerState();
    }
    ClearDuelEndSignals();
    duelMatchId = "";
    duelBoardSpoke = false;

    wrappedMethod();

    m_flashValueStorage.SetFlashBool("gwint.game.debug.autoplay", manager.duelDebugAutoplay);
    m_flashValueStorage.SetFlashBool("gwint.game.debug.mulligan", manager.duelDebugMulligan);
    m_flashValueStorage.SetFlashBool("gwint.game.debug.leaderFirst", manager.duelDebugLeaderFirst);
    m_flashValueStorage.SetFlashInt("gwint.game.debug.corruptAt", manager.duelDebugCorruptAt);
    m_flashValueStorage.SetFlashBool("gwint.game.debug.forceDraw", manager.duelDebugForceDraw);
    m_flashValueStorage.SetFlashBool("gwint.game.debug.replay", manager.duelDebugReplay);
    m_flashValueStorage.SetFlashBool("gwint.game.debug.breakTemplates", manager.duelDebugBreakTemplates);
    m_flashValueStorage.SetFlashBool("gwint.game.debug.selfTest", manager.duelSelfTest);
}

// The duel values reach the board before the decks, so the board knows it is in a duel when the decks arrive.
@addMethod(CR4GwintGameMenu)
function SendDuelValues()
{
    if(gwintManager.duelDebugNoBoard)
    {
        m_flashValueStorage.SetFlashInt("gwint.game.seed", 0);
    }
    else
    {
        m_flashValueStorage.SetFlashInt("gwint.game.seed", duelSeed);
    }
    m_flashValueStorage.SetFlashBool("gwint.game.isHost", IsDuel() && gwintManager.multiplayerIsHost);
    m_flashValueStorage.SetFlashBool("gwint.game.isTimed", IsDuel() && gwintManager.multiplayerIsTimed);
    m_flashValueStorage.SetFlashBool("gwint.game.opponentLeft", false);
}

// In a duel both decks are plain: leader, special card and cards, without the AI deck balancing (dynamicCards from
// the deck name, additionalCards). Both boards convert the names with their own card table.
@wrapMethod(CR4GwintGameMenu)
function SendDecksInformation()
{
    var playerDeck : SDeckDefinition;
    var enemyDeck : SDeckDefinition;
    var dynamicCards : array<SDynamicCard>;

    SendDuelValues();
    if(!IsDuel())
    {
        wrappedMethod();
        return;
    }

    playerDeck = gwintManager.GetCurrentPlayerDeck();
    playerDeck.deckName = WO_GwentDuelDeckName();
    enemyDeck = gwintManager.multiplayerEnemyDeck;
    enemyDeck.deckName = WO_GwentDuelDeckName();

    m_flashValueStorage.SetFlashObject("gwint.game.player.deck", CreateDeckDefinitionFlash(playerDeck));
    m_flashValueStorage.SetFlashObject("gwint.game.enemy.deck", CreateDeckDefinitionFlash(enemyDeck));
    // CreateDeckDefinitionFlash adds the dynamic cards of the deck name: none must exist for the duel deck name
    dynamicCards = gwintManager.GetDynamicCards(WO_GwentDuelDeckName());
    OnDuelLog("DUEL DYNAMIC cards=" + dynamicCards.Size());
}

// A deck name no deck definition uses, so GetDynamicCards finds nothing for duel decks.
function WO_GwentDuelDeckName() : name
{
    return 'wo_gwent_duel';
}

@wrapMethod(CR4GwintGameMenu)
function SendPlayerNames()
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(IsDuel() && client && client.multiplayerLocalName != "")
    {
        m_flashValueStorage.SetFlashString("gwint.player.name.one", client.multiplayerLocalName);
        m_flashValueStorage.SetFlashString("gwint.player.name.two", client.multiplayerOpponentName);
        return;
    }
    wrappedMethod();
}

// Surrender: the board sends its QUITGAME message (onQuitConfirmed) before the menu closes as a forfeit.
@wrapMethod(CR4GwintGameMenu)
function OnQuitGameConfirmed()
{
    var fxNotifyQuit : CScriptedFlashFunction;

    if(IsDuel())
    {
        if(duelEndSent)
        {
            // the popup was opened before the game ended and accepted after this board sent its E: the end
            // confirmation settles this game (the end screen's close), so the surrender sends nothing and pays nothing
            OnDuelLog("DUEL SURRENDER ignored: the game already ended");
            return;
        }
        // a surrender is a loss, not a draw; an abort stays (an aborted game settles nothing, surrender or not)
        duelDraw = false;
        // the board sends QUITGAME: "1" (it settles: a loss here, a win there) once its Hello is complete, "0" before
        // (no contest, it calls OnMultiplayerAbort)
        fxNotifyQuit = m_flashModule.GetMemberFlashFunction("onQuitConfirmed");
        if(fxNotifyQuit)
        {
            fxNotifyQuit.InvokeSelf();
        }
        if(duelMatchId == "")
        {
            // the board has sent nothing yet, not even its Hello (it may not have its duel values yet): the opponent
            // never learns of a forfeit, so nobody pays (it ends by its own Hello wait as no contest)
            OnDuelLog("DUEL END result=nocontest reason=quit game=0");
            OnMultiplayerAbort("quit");
        }
    }
    wrappedMethod();
}

@wrapMethod(CR4GwintGameMenu)
function OnMatchResult(pWon : bool)
{
    wrappedMethod(pWon);
    duelDraw = false;
}

// Settles the duel after vanilla's close: abort and draw move no money, otherwise win or loss as before. A duel whose
// board never sent its Hello (not the duel board, see duelBoardSpoke) is an abort, reason "board", decided before the
// vanilla close so its DUEL END line comes before anything another wrap of the close logs.
@wrapMethod(CR4GwintGameMenu)
function OnClosingMenu()
{
    var client : r_MultiplayerClient;

    if(IsDuel() && !duelBoardSpoke && !duelAborted)
    {
        OnDuelLog("DUEL END result=nocontest reason=board game=0");
        OnMultiplayerAbort("board");
    }

    wrappedMethod();

    if(IsDuel())
    {
        client = theGame.r_getMultiplayerClient();
        if(duelAborted)
        {
            if(client && client.getInGwentGame())
            {
                client.onGwentGameAborted(duelAbortReason);
            }
        }
        else if(duelDraw)
        {
            if(client && client.getInGwentGame())
            {
                client.onGwentGameDraw();
            }
        }
        else
        {
            NotifyGwentMatchEnded(playerWon);
        }
        gwintManager.ClearMultiplayerState();
        duelSeed = 0;
    }
}

// ---- board to script ----

// The end signals, at the menu opening and when a new game of the duel starts.
@addMethod(CR4GwintGameMenu)
function ClearDuelEndSignals()
{
    duelDraw = false;
    duelAborted = false;
    duelAbortReason = "";
    duelEndSent = false;
}

// One outbound duel message (a token without spaces or "~": "<version>.<matchId>.<seq>.<type>.<args>.<hash>").
@addMethod(CR4GwintGameMenu)
event OnMultiplayerMessage(message : string)
{
    var version : string;
    var matchId : string;
    var seq : string;
    var type : string;
    var rest : string;

    if(StrSplitFirst(message, ".", version, rest) && StrSplitFirst(rest, ".", matchId, rest))
    {
        if(duelMatchId != "" && matchId != duelMatchId)
        {
            // the first message of a replayed game: the end signals of the earlier game no longer apply
            ClearDuelEndSignals();
        }
        duelMatchId = matchId;
        if(StrSplitFirst(rest, ".", seq, rest) && StrSplitFirst(rest, ".", type, rest))
        {
            if(type == "H" && version == IntToString(WO_GwentProtocol()))
            {
                duelBoardSpoke = true;
            }
            else if(type == "E")
            {
                duelEndSent = true;
            }
        }
    }
    HandleOutgoingGwentAction(message);
}

// The board cancelled the duel as no contest (desync, Hello mismatch, opponent_left, stuck_wait, hello_timeout).
@addMethod(CR4GwintGameMenu)
event OnMultiplayerAbort(reason : string)
{
    if(!duelAborted)
    {
        duelAborted = true;
        duelAbortReason = reason;
    }
}

// A drawn duel that is left without a replay: nobody pays.
@addMethod(CR4GwintGameMenu)
event OnMultiplayerDraw()
{
    duelDraw = true;
}

// The board's duel log (DuelSelfTest, DuelSession).
@addMethod(CR4GwintGameMenu)
event OnDuelLog(line : string)
{
    var client : r_MultiplayerClient;

    if(StrBeginsWith(line, "DUEL GAME "))
    {
        // the board started the next game after a replay (DuelSession.startNextGame): the E it sent was the last game's
        duelEndSent = false;
    }
    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.duelLog(line);
    }
    else
    {
        LogChannel('GwentDuel', line);
    }
}

// ---- script to board ----

// Witcher Online lost the opponent during the duel (its game closed or it disconnected; r_MultiplayerClient.
// gwentGameLoop): the board ends the duel as no contest (opponent_left) once what the opponent sent has applied.
@addMethod(CR4GwintGameMenu)
public function SetDuelOpponentLeft()
{
    if(IsDuel())
    {
        m_flashValueStorage.SetFlashBool("gwint.game.opponentLeft", true);
    }
}

// The opponent's latest message window ("~"-joined tokens, "none" when empty).
@addMethod(CR4GwintGameMenu)
public function ReceiveRemoteGwentAction(message : string)
{
    if(IsDuel())
    {
        m_flashValueStorage.SetFlashString("gwint.game.remoteInput", message);
    }
}

// ---- the Scoia'tael popup (who goes first) in a duel ----

// The popup was answered (go first or go second).
@addField(W3ChooseGwintTurnPopup)
var duelAnswered : bool;

@wrapMethod(W3ChooseGwintTurnPopup)
function OnUserAccept()
{
    duelAnswered = true;
    wrappedMethod();
}

@wrapMethod(W3ChooseGwintTurnPopup)
function OnUserDecline()
{
    duelAnswered = true;
    wrappedMethod();
}

// R48: in a duel the popup closed without an answer counts as its first option, "go first" (the board would otherwise
// wait for the choice forever, and the opponent with it). OnClosing belongs to W3PopupData, so the wrap is there.
@wrapMethod(W3PopupData)
function OnClosing()
{
    var turnPopup : W3ChooseGwintTurnPopup;
    var client : r_MultiplayerClient;

    turnPopup = (W3ChooseGwintTurnPopup)this;
    if(turnPopup && !turnPopup.duelAnswered && turnPopup.gwintMenuRef && turnPopup.gwintMenuRef.IsDuel())
    {
        turnPopup.duelAnswered = true;
        client = theGame.r_getMultiplayerClient();
        if(client)
        {
            client.duelLog("DUEL COIN popup closed unanswered: go first");
        }
        turnPopup.gwintMenuRef.SetPlayerStarts(true);
    }
    wrappedMethod();
}

// R53: in a Timed duel the Scoia'tael choice ran out and the board answered its first option itself; the popup goes,
// marked answered first so its close (OnClosing above) answers nothing again.
@addMethod(CR4GwintGameMenu)
event OnDuelCoinTimeUp()
{
    var client : r_MultiplayerClient;

    if(!IsDuel() || !chooseTurnPopup || chooseTurnPopup.duelAnswered)
    {
        return true;
    }
    chooseTurnPopup.duelAnswered = true;
    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.duelLog("DUEL COIN popup closed: the time ran out");
    }
    chooseTurnPopup.ClosePopupOverlay();
    return true;
}
