// Console commands (the game's console needs -debugscripts). The party is also offered when interacting with a
// player; these stay as a way in when a screen of the mod's own doesn't come up.

exec function coopjoin(user : string)
{
    theGame.r_getMultiplayerClient().joinParty(user);
}

exec function coopleave()
{
    theGame.r_getMultiplayerClient().leaveParty();
}

// Witcher Online's radial menu for the nearest player (trading, emotes, riding along, Gwent): it shows no entries
// on Remastered, so this also says whether its entries are items this game knows at all.
exec function coopmenu()
{
    var player : r_RemotePlayer;
    var inventory : CInventoryComponent;
    var ids : array<SItemUniqueId>;

    player = W3CoopNearestPlayer();
    if(!player)
    {
        theGame.GetGuiManager().ShowNotification("W3Coop: no player of yours is near.");
        return;
    }
    inventory = new CInventoryComponent in theGame;
    inventory.AddAnItem('wo_joinParty', 1);
    inventory.GetAllItems(ids);
    theGame.GetGuiManager().ShowNotification("W3Coop: the menu's entries are " + ids.Size() + " item(s) here (1 = the mod's"
        + " items load, 0 = they don't).");
    theGame.r_getMultiplayerClient().createMenu(player.ghost);
}

exec function cooptrade()
{
    var player : r_RemotePlayer;

    player = W3CoopNearestPlayer();
    if(!player)
    {
        theGame.GetGuiManager().ShowNotification("W3Coop: no player of yours is near.");
        return;
    }
    theGame.r_getMultiplayerClient().tradeWithPlayer(player.ghost);
}

function W3CoopNearestPlayer() : r_RemotePlayer
{
    var players : array<r_RemotePlayer>;
    var best : r_RemotePlayer;
    var bestDist, d : float;
    var i : int;

    players = theGame.r_getMultiplayerClient().getPlayers();
    bestDist = 100000;
    for(i = 0; i < players.Size(); i += 1)
    {
        if(players[i])
        {
            if(players[i].ghost)
            {
                d = VecDistance(players[i].ghost.GetWorldPosition(), thePlayer.GetWorldPosition());
                if(d < bestDist)
                {
                    bestDist = d;
                    best = players[i];
                }
            }
        }
    }
    return best;
}
