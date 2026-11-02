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

// Witcher Online's radial menu for the nearest player (the party, trading, emotes, riding along, Gwent). It is
// what interacting with a player opens; this is the way in when no one is in reach of an interaction.
exec function coopmenu()
{
    var player : r_RemotePlayer;

    player = W3CoopNearestPlayer();
    if(!player)
    {
        theGame.GetGuiManager().ShowNotification("W3Coop: no player of yours is near.");
        return;
    }
    if(!theGame.r_getMultiplayerClient().createMenu(player.ghost))
    {
        theGame.GetGuiManager().ShowNotification("W3Coop: the menu could not be built.");
    }
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
