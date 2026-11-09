# Witcher Online
<div align="left">
  <a href="https://www.youtube.com/watch?v=E36I77ardm4">
    <img
      src="https://github.com/user-attachments/assets/2f2c39ab-7d48-4095-8a89-56fbede324ef"
    >
  </a>
</div>

**Witcher Online** is a mod that adds multiplayer to *The Witcher 3: Wild Hunt*, turning your single player experience into an MMO experience. Join servers to play with your friends, customize your character using [Custom Player Characters](https://www.nexusmods.com/witcher3/mods/5940) and relax in taverns using [Chill Out](https://www.nexusmods.com/witcher3/mods/6402). Play Gwent and join parties with other players. Chat with strangers and perform emotes to roleplay with other players. Complete quests alongside friends.

## Getting started
To play Witcher Online, go to the [nexus page](https://www.nexusmods.com/witcher3/mods/11590).

For general information, go to the [Witcher Online Wiki](https://rejuvenate.gitbook.io/witcheronline).

Special thanks to Werasik2aa for his [multiplayer implementation](https://github.com/werasik2aa/Witcher3-Multiplayer) which helped a lot.

## Features / Playguide

Full movement, combat, and appearance sync with other players. Perform emotes and send chat to other players using the player menu or in-game console. Morph into various animals, ride horses and boats with other players.

Sit down at tables and benches using Chill Out and change into any character in the game with Custom Player Characters.

Play Gwent with other players, using the cards in your deck. Play Timed or Normal mode and place bets.

Play in parties to synchronize time, weather, and dialog choices. NPC sync is **NOT** implemented.

This mod is designed to turn *The Witcher 3* into an MMO experience, where you can see other players on the path.

[Features](https://rejuvenate.gitbook.io/witcheronline/general-information/features)

### MMO Experience

Join the public server to wander the world with lots of other players.

![MMO Experience](assets/mmo.gif)

### Chill Out
Sit down in taverns and other locations throughout the world.

![Chill Out](assets/chill.gif)

### Party System
Join a party with other players to synchronize time, weather, and cutscene dialog choices.

![Party System](assets/world.gif)

![Party System 2](assets/party.gif)

### Cutscene Sync
Dialogue choices the party leader chooses are selected for all players in the party.

![Cutscene Sync](assets/dialog.gif)

### Gwent Duels

Play Gwent with other players, using your own decks.

![Gwent Duels](assets/gwent.gif)

#### Gwent duels on The Witcher 3 Remastered 5.01

On Remastered 5.01 the duels run on CDPR's own 5.01 Gwent board, patched with our own lockstep code (both clients play
the same match from the same seed and exchange only the moves). Built and tested on game build **5.0.0.1048522** only
(no duel board has been built on Steam's update of 2026-10-29, build 5.0.0.1090142, yet); both players need the same
build and the same Witcher Online build. The board is built from your own game files, see the
[build guide and test checklist](gwent/README.md). Without the built board a duel is cancelled when its menu closes, and
no bet is paid on either side.

- **What works:** challenges, your own decks, all factions and leaders (including the choices they ask for), mulligan,
  the Scoia'tael coin toss, the 5.01 cards, bets, and a drawn match that both players replay with the same bet. The
  automated tests play duels between two bot-driven games. A test with two players over the Steam relay is still to be
  done; its checklist is in [gwent/README.md](gwent/README.md).
- **Two modes:** Normal has no turn clock, but a player who takes more than 2 minutes to make a move (or to answer the
  mulligan or a choice) cancels the match for both, with no money moved. Timed gives each player 60 seconds per turn,
  mulligan and choice; when the time runs out the turn is passed, an open choice takes its first option and the
  mulligan counts as done.
- **Out of sync:** both clients compare a hash of the match on every move. If they differ, the match is cancelled with
  "The match went out of sync and was cancelled".
- **Opponent leaves:** if the other player's game closes or its connection drops (no packets for 30 seconds), the match is
  cancelled with "Your opponent left. The match was cancelled".
- **Stuck waits:** if the other client sends nothing for 120 seconds (Timed: 90 seconds), the match is cancelled with "No
  answer in time. The match was cancelled". In Normal mode this is also what happens when the other player simply
  thinks for more than 2 minutes.
- **Surrender:** closing the board and confirming the surrender loses the bet for the one who quits and wins it for the
  other player, unless it is confirmed before the two boards have greeted each other (right at the start), when the
  match is cancelled with no money moved. A surrender confirmed after the game ended does nothing.
- **No money moves** when a match is cancelled (out of sync, opponent left, no answer in time, a player without the
  built board), or when a drawn match is not replayed. Each client settles its own bet: nothing is held in escrow.
- **Challenge:** on Remastered the player menu is empty, so challenge from the console: `duel("<their username>")`, the
  other player's Witcher Online username as in their `bin\WitcherOnline\config.xml`.

### Player Riding

Sit back and relax while other players drive you to your destination.

![Player Riding](assets/riding.gif)

### Vehicle Passengers

Ride horses and boats with other players.

![Vehicle Passengers Horse](assets/horse.gif)

![Vehicle Passengers Boat](assets/boat.gif)

### Item Trading

Trade items with other players, for a price.

![Item Trading](assets/trading.gif)

### Morphs

Transform into an owl, crow, fox, or cat.

![Morphs](assets/morphs.gif)

### Emotes

50+ player emotes, some using props.

![Emotes](assets/emotes.gif)

Since only other player locations are synced (not quest progress, NPCs, or the world state), everyone can use their own save file safely.

You can still easily do a full playthrough with each other, just make the same dialog choices and complete quests at the same time as one another.

[Playguide](https://rejuvenate.gitbook.io/witcheronline/general-information/playguide)

## Socials

Join the Discord to report any bugs or issues you encounter with the mod.

- [Discord](https://discord.gg/AGXXvGNnH8)
- [Wolven Workshop](https://discord.com/invite/RzkhYYr7fk) (`#rejuvenate-rock-farm`)
- [Wiki](https://rejuvenate.gitbook.io/witcheronline)
- [YouTube](https://www.youtube.com/@rejuvenate7/videos)
- [Donate](https://ko-fi.com/rejuvenate)

## Credits
- [rejuvenate7](https://github.com/rejuvenate7) - Lead developer
- [x4lva](https://github.com/x4lva) - Co-developer, Gwent sync
- [Flawkee](https://github.com/flawkee) - Co-developer, Native hook / NPC sync (in progress)
