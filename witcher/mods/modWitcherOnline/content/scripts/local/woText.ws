// The mod's own text. Its string table (the .w3strings files) is the 4.04 format, and Remastered cannot read
// it: every id came back empty and every key as rubbish. That left the round player menu's headings blank -
// which is why a player met an unnamed section with a cat in it - the party HUD's labels missing, and the
// mod's section of the game's options unreadable. The text lives here instead, so none of it depends on that
// file. All seventeen of the mod's language files held the same English text, so nothing is lost by it.
// Generated from content\en.csv; an id this does not know still goes the old way.
function WO_Text(id : int) : string
{
    switch(id)
    {
        case 2111114074: return "A faster mode of Gwent, with limited time to make each move.";
        case 2111114075: return "A classic mode of Gwent, with no time limit.";
        case 2111114076: return "Perform emote.";
        case 2111114095: return "Change morph.";
        case 2111114096: return "Send chat message.";
        case 2111114097: return "Morphs";
        case 2111114098: return "Chat";
        case 2111114099: return "Emotes";
        case 2111114102: return "Waiting for";
        case 2111114103: return "Party not ready";
        case 2111114104: return "Party ready";
        case 2111114105: return "In a cutscene";
        case 2111114106: return "Game paused";
        case 2111114107: return "In the bestiary menu";
        case 2111114108: return "In the tutorial menu";
        case 2111114109: return "In the characters menu";
        case 2111114110: return "In the books menu";
        case 2111114111: return "In the crafting menu";
        case 2111114112: return "In the alchemy menu";
        case 2111114113: return "In the inventory menu";
        case 2111114114: return "In the map menu";
        case 2111114115: return "In the quests menu";
        case 2111114116: return "In the character menu";
        case 2111114117: return "In the meditation menu";
        case 2111114118: return "In the blacksmith menu";
        case 2111114198: return "joined your party.";
        case 2111114199: return "left your party.";
        case 2111114200: return "Could not join party.";
        case 2111114201: return "That player is already in your party.";
        case 2111114202: return "You are already in";
        case 2111114203: return "'s party.";
        case 2111114204: return "You joined";
        case 2111114205: return "'s party.";
        case 2111114206: return "You are not in any party.";
        case 2111114207: return "You left the party.";
        case 2111114208: return "joined";
        case 2111114209: return "disconnected";
        case 2111114210: return "Teleporting to";
        case 2111114211: return "The gwent request was declined.";
        case 2111114212: return "Declined gwent duel request!";
        case 2111114213: return "The game is over. You won!";
        case 2111114214: return "The game is over. You lost!";
        case 2111114215: return "You received";
        case 2111114216: return "crowns.";
        case 2111114217: return "You lost";
        case 2111114218: return "crowns.";
        case 2111114219: return "You cannot duel yourself!";
        case 2111114220: return "You are already in a game of Gwent!";
        case 2111114221: return "You don't have enough crowns for that bet.";
        case 2111114222: return "Gwent duel request sent to";
        case 2111114223: return "The trade has been completed!";
        case 2111114224: return "The trade was declined.";
        case 2111114225: return "You do not have enough crowns to complete this trade!";
        case 2111114226: return "tried to send a trade request for an item that doesn't exist in your game.";
        case 2111114227: return "You cannot ride yourself!";
        case 2111114228: return "Trade request sent to";
        case 2111114229: return "To use morphs, switch to Sorceress in Custom Player Characters.";
        case 2111114230: return "Riding";
        case 2111114231: return "!";
        case 2111114232: return "No player found by that name.";
        case 2111114233: return "To use morphs, first dismount.";
        case 2111114234: return "To change morphs, first unmorph by holding Cast Sign.";
        case 2111114235: return "There are";
        case 2111114236: return "players online in";
        case 2111114237: return ".";
        case 2111114238: return "Welcome,";
        case 2111114239: return "!";
        case 2111114240: return "You are not connected to any Witcher Online server.";
        case 2111114241: return "The Gwent duel was declined.";
        case 2111114242: return "Trading with";
        case 2111114243: return "wants to trade for";
        case 2111114244: return "crowns";
        case 2111114245: return "Gwent: Playing";
        case 2111114246: return "wants to play Gwent and bets";
        case 2111114247: return "Asking Price";
        case 2111114248: return "Bet";
        case 2111114249: return "Failed to connect to server";
        case 2111114250: return "Another player is connected with the username";
        case 2111114251: return "Change your username in the Witcher Online config.";
        case 2111114252: return "You were banned from the server.";
        case 2111114253: return "You were kicked from the server.";
        case 2111114254: return "You are not whitelisted on this server.";
        case 2111114255: return "Player List";
        case 2111114256: return "connected";
        case 2111114257: return "in your current region";
        case 2111114258: return "in White Orchard";
        case 2111114259: return "in Novigrad/Velen";
        case 2111114260: return "in Skellige";
        case 2111114261: return "in Kaer Morhen";
        case 2111114262: return "in Toussaint";
        case 2111114263: return "in Vizima";
        case 2111114264: return "in Other/Unknown";
        case 2111114265: return "'s current location.";
        case 2111114270: return "[Leader]";
        default: return GetLocStringById(id);
    }
}
