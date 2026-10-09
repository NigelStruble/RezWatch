# RezWatch

Shows on your raid frames when a dead player is being resurrected, and by
whom, so the healers bringing a group back after a wipe can see which bodies
are already taken. Made for WoW: Forever, whose raid frames show no
incoming-res icon.

## Features

- **An icon on the dead player's frame** while someone casts a resurrection
  on them, with the resser's name under it. It shows only on the player the
  res is aimed at, whether the resser targeted the body, clicked a raid frame
  or used a mouseover macro, and whatever their class: Goblin Jumper Cables
  count too. Heals and other casts never show.
- **Doubles in red.** When two players res the same body, a red 2 shows by
  the icon.
- **Rezzed, waiting to accept.** Once a res lands, the icon turns green and
  says Rezzed until the player accepts it or the offer runs out a minute
  later, so nobody casts a second one meanwhile.
- **A warning when you pick a taken body.** Start a res on someone who
  already has one coming or waiting, and RezWatch says so in chat, with a
  sound. The warning covers ressers who run RezWatch and offers a dead
  player's RezWatch reports; any other res on your target shows as the red 2
  on their frame.
- **Shared between RezWatch users.** Players who run RezWatch tell each other
  exactly whom they are ressing, and a dead player's RezWatch tells the group
  when a res has landed on them, and when they decline it.
- **Any raid frames.** The icon goes on every frame that shows a group
  member: Blizzard's party and raid frames, EllesmereUI's, ElvUI's, and other
  raid frame addons built on the game's unit buttons.

## Supported game versions

| Game | Folder | Interface |
|---|---|---|
| WoW: Forever | `_classic_beta_` (beta) | 16001 |

## Installing

Copy the `RezWatch` folder into the game's AddOns folder, for example
`World of Warcraft\_classic_beta_\Interface\AddOns\RezWatch`, and restart the
game (a new addon is only found at start-up, not by `/reload`).

## Commands

| Command | Does |
|---|---|
| `/rezwatch` or `/rezw` | List the commands and the current settings |
| `/rezwatch test` | Show sample icons on your group's frames for 15 seconds |
| `/rezwatch size 24` | The icon's size, from 8 to 64 |
| `/rezwatch anchor CENTER 0 0` | Where the icon sits on the frame (TOPLEFT, TOP, TOPRIGHT, LEFT, CENTER, RIGHT, BOTTOMLEFT, BOTTOM or BOTTOMRIGHT), and how far it is moved from there |
| `/rezwatch names` | Show or hide the ressers' names |
| `/rezwatch accept` | Keep the green icon while a res waits to be accepted, or not |
| `/rezwatch warn` | Turn the chat warning on or off |
| `/rezwatch sound` | Turn the warning's sound on or off |
| `/rezwatch share` | Tell other RezWatch users whom you are ressing, or not |
| `/rezwatch debug` | Print what RezWatch sees of each res, for reporting problems |
| `/rezwatch reset` | Go back to the default settings |

Settings are saved for your account. The game keeps other players' spells
from addons except to show them, so debug lines naming another player's spell
can't be copied out of chat; take a screenshot instead.

## Development

```
RezWatch/
  RezWatch.toc   Interface number and load order
  Locales.lua    Strings (English; other languages can be added here)
  Core.lua       Res casts, offers, messages between RezWatch users, /rezwatch
  Display.lua    The icons on the raid frames
tests/           Tests run against a mock of the WoW API
```

Run the tests with Lua 5.1 from the repository root:

```
lua5.1 tests/run_tests.lua
```

While developing, you can link the `RezWatch` folder into the game's AddOns
folder (a directory junction or symbolic link) instead of copying it, so
changes show up after a `/reload`.

When a patch changes the interface number, change the `## Interface:` line in
`RezWatch.toc`.
