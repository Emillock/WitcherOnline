// Gwent duels on the 5.01 board: Witcher Online's additions to the vanilla CR4GwintGameMenu.
// The rebuilt board (WitcherOnline\gwent) calls these events from Flash.

// Lines this menu logged, kept for test tools to read while the menu is open (they clear it).
@addField(CR4GwintGameMenu)
var duelLogLines : array<string>;

// Test tools (the w3test bot, only while it runs) set this before opening the Gwent menu: the board then runs its
// self-test of the duel classes (DuelSelfTest) and reports "DUEL SELFTEST pass=<n> fail=<m>" through OnDuelLog.
// Nothing else sets it, so a normal player never runs the self-test.
@addField(CR4GwintManager)
var duelSelfTest : bool;

@wrapMethod(CR4GwintGameMenu)
function OnConfigUI()
{
    wrappedMethod();

    if(theGame.GetGwintManager().duelSelfTest)
    {
        m_flashValueStorage.SetFlashBool("gwint.game.debug.selfTest", true);
    }
}

// The board's duel log (DuelSelfTest now; DuelSession from Task 9 on).
@addMethod(CR4GwintGameMenu)
event OnDuelLog(line : string)
{
    DuelLog(line);
}

@addMethod(CR4GwintGameMenu)
function DuelLog(line : string)
{
    LogChannel('GwentDuel', line);
    duelLogLines.PushBack("GwentDuel: " + line);
}
