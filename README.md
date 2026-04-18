# DailySync

> Automatically shares today's rotating daily quests with every other player who has this addon, so your whole guild or party knows the daily the moment anyone picks it up.

---

## What it does

In Burning Crusade Classic the normal dungeon daily, heroic dungeon daily, cooking daily, fishing 
daily, and PvP daily all rotate each day. DailySync detects whichever ones you encounter and silently 
broadcasts them over guild, party, and yell channels using a hidden addon message. 

The minimap button opens a popup listing every known daily for the day — rotating quests, both PvP tower quests, Ogri'la, and Sha'tari Skyguard — with clickable quest links, completion ticks, and a live reset timer.

---

## Features

- **Auto-detect & broadcast** — fires as soon as you open or accept a tracked daily quest
- **Popup UI** — minimap button opens a scrollable panel showing all five rotating dailies, PvP towers, Ogri'la, and Skyguard quests with rich tooltips and rep rewards
- **Completion ticks** — green checkmark next to any quest you've already completed today
- **Oceanic / realm-offset support** — `/dsync offset 7` for AEST realms where the daily cycle doesn't align with the server reset
- **Smart dedup** — won't spam the same data twice; staggered random delays prevent addon-message floods when multiple players are online

---

## Installation

1. Download the latest release zip
2. Extract the `DailySync` folder into `Interface\AddOns\`
3. Reload WoW or log in — DailySync will announce itself in chat

The required libraries (LibStub, LibDataBroker-1.1, LibDBIcon-1.0) are bundled — no separate downloads needed.

---

## Usage

| Command | Description |
|---|---|
| `/dsync` | Toggle the daily quests popup |
| `/dsync reset` | Clear all stored daily data for today |
| `/dsync offset N` | Set daily-change offset in hours (default `0` for US; use `7` for Oceanic/AEST) |
| `/dsync debug` | Toggle verbose debug output to chat |

The **Share** button in the popup manually re-broadcasts everything you know to all available channels.

---

## How syncing works

On login DailySync waits 8 seconds, then broadcasts to guild, party, and yell with a request for any data you're missing. When you move to a new outdoor zone it yells again (at most every 5 minutes). When you join a group it pings the party. Incoming messages from other players are validated against the current day's reset window before being stored, so stale data from a previous rotation is never accepted.

---

## Tracked quests

| Category | Source |
|---|---|
| Normal Dungeon daily | Nether-Stalker Mah'duun, Shattrath Lower City |
| Heroic Dungeon daily | Wind Trader Zhareem, Shattrath Lower City |
| Cooking daily | The Rokk, Shattrath Lower City |
| Fishing daily | Old Man Barlo, Silmyr Lake |
| PvP daily | Alliance Brigadier General / Horde Warbringer |
| PvP Towers | Hellfire Fortifications, Spirits of Auchindoun |
| Ogri'la | The Relic's Emanation, Banish More Demons, Bomb Them Again!, Wrangle More Aether Rays! |
| Sha'tari Skyguard | Fires Over Skettis, Escape from Skettis, and more |

---

## Compatibility

- **WoW Anniversary / TBC Classic** — Interface version 20505

---

## Author

**Beckylava** (Dreamscythe)
