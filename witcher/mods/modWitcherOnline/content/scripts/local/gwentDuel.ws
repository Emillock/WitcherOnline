// Gwent duels on the 5.01 board: Witcher Online's additions to the vanilla CR4GwintGameMenu.
// The rebuilt board (WitcherOnline\gwent) calls these events from Flash.

// Lines this menu logged, kept for test tools to read while the menu is open (they clear it).
@addField(CR4GwintGameMenu)
var duelLogLines : array<string>;

// The board's build probe: DuelProbe.ping, called once from GwintGameMenu.configUI, raises it with "probe-1".
@addMethod(CR4GwintGameMenu)
event OnDuelProbe(arg : string)
{
    DuelLog("probe " + arg);
}

@addMethod(CR4GwintGameMenu)
function DuelLog(line : string)
{
    LogChannel('GwentDuel', line);
    duelLogLines.PushBack("GwentDuel: " + line);
}
