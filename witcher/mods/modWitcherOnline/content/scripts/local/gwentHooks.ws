// Witcher Online's hooks on the 5.01 CR4GwintGameMenu (the vanilla menu has neither method; the 4.04 build wraps the
// ones its own gwintGameMenu.ws override declares). gwentDuel.ws calls them.

// An outbound duel message goes into the client's message window (sent in the wo3 packet).
@addMethod(CR4GwintGameMenu)
public function HandleOutgoingGwentAction(message : string)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client && client.getInGwentGame())
    {
        client.setLastGwentAction(message);
    }
}

// A duel ended with a winner: the client settles the bet.
@addMethod(CR4GwintGameMenu)
public function NotifyGwentMatchEnded(wonMatch : bool)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client && client.getInGwentGame())
    {
        client.onGwentGameEnd(wonMatch);
    }
}
