# Gamer Center

Game tools for the Omarchy shell. The panel has three pages:

- **Stats:** a HUD over your games (CPU and GPU load, temperature and clock, GPU power, RAM, VRAM, battery draw and the time) and a switch for MangoHud's in-game FPS counter.
- **Game mode:** frees memory before you play by closing big apps, stopping Docker projects and the file indexer, then brings them all back afterwards.
- **Steam:** your Steam games, installed or not, with search and filters, covers, time played, full size with mods, Linux native or Proton, SteamOS and Steam Deck ratings, DLC, builds and pending updates, and Launch, Install, Uninstall. Plus free games and wishlist sales, the other games on your PC, and the free space on each Steam drive.

## Install

```bash
omarchy plugin add https://github.com/T3mon/omarchy-gamer-center --enable
```

It shows up in the bar as a gamepad icon, lit while the overlay or game mode is on. Left-click opens the panel, right-click turns the overlay on or off, and middle-click turns game mode on or off.

## Overlay

The panel has a live preview. Click where the HUD should sit, pick the stats, a stacked or one-line layout, the size and the backdrop. Under Behavior you can keep it hidden until a window goes fullscreen, change the update rate, and pin a GPU or a display when you have more than one.

Settings are saved in `~/.config/gamer-center/overlay.json`. Edits to that file apply right away.

## FPS

The shell can't see a game's frame rate, so FPS comes from MangoHud, which draws inside the game. The panel can install it. "Show FPS in games" adds a marked block to `~/.config/MangoHud/MangoHud.conf` and leaves your own lines alone. The block puts the FPS on the side opposite the HUD, at a matching size.

MangoHud only runs in games started through it: add `mangohud %command%` to a Steam game's launch options (the panel copies it for you), or run `mangohud <game>`.

## Game mode

Ported from [omarchy-gamemode](https://github.com/YassineSawahi/omarchy-gamemode) by Yassine Sawahi (MIT, see `licenses/omarchy-gamemode.txt`), and it works the same way.

The page lists everything worth pausing: apps over 150 MB, each Docker Compose project, and the file indexer. Each row shows the RAM (plus swap) and VRAM it holds. Apps and the indexer are one list, biggest RAM first; Docker projects sit in their own folder, which starts folded once it has more than four, and its switch ticks or unticks all of them. The **All** switch beside "Tick what to pause" ticks or unticks everything. Tick what you want gone and press **Pause ticked**. Chrome, Chromium, Slack, Discord, the indexer and Compose projects start ticked, and your ticks are remembered. While game mode is on, each switch acts at once: switch one off to bring just that back, or on to pause one more. **Restore all** brings everything back.

- **Apps** get SIGTERM, so they can save and quit; nothing is killed. They reopen with their original command line, on the workspaces their windows were on, and Chrome, Chromium and Brave come back with their last session.
- **Containers** stop with `docker stop` and start again dependencies first, waiting for healthchecks.
- **Never touched:** terminals and anything running an AI coding agent, game launchers and games (Steam, Proton, Wine, Lutris, Heroic, gamescope, any `.exe`), browsers started by automation tools, the desktop itself, sandboxed apps, and other accounts' processes.
- **The record** of what was paused lives in `~/.local/state/gamer-center/gamemode/` (private to you), so "Restore all" still works after a reboot.
- A runtime-suspended NVIDIA GPU is never woken to read its VRAM.

Turn game mode on before you launch the game, so the memory is free from the start. Or switch on **Turn on when a game opens**: game mode then pauses what's ticked when a game starts and brings it back 15 seconds after the game closes. A game counts when Steam launches it (its `reaper SteamLaunch` process), when a Windows `.exe` runs through Wine or Proton, or under gamescope; Steam sitting idle doesn't. If you restore things yourself mid-game, they stay back until that game ends, and game mode you turned on by hand is never turned off for you.

Chromium-based browsers rewrite their command line into one string; it's split back into arguments when saved, so Brave and Chrome reopen.

## Steam

Apart from the Deals tab, the Steam page only reads Steam's own files on disk; nothing goes online, covers included.

### Tabs

- **Installed** and **Not installed** split the games you own. Sort them by **Recent** (last played), **Name** or **Size** (installed games only).
- **Deals:** games that are free to keep right now (100% off), then games on your wishlist at or over a discount you set with − / + (50% to start). Owned ones are marked; **Store page** opens the game in Steam. This is the one part that goes online: it reads Steam's store search and your public wishlist, with no key and no login, at most every 15 minutes. A private wishlist reads as empty.
- **Other games:** games outside Steam that are in your app menu under Games (Flatpak, Heroic, Lutris, itch and so on), with their icon, size and folder, and **Launch**. A game with no app-menu entry, or one not in the Game category, doesn't show.

### Search and filters

- **Search** filters the list as you type: every word has to be in the name, and case and accents don't matter. Press `/` or Enter on it to type; Esc clears it, then leaves it.
- **Filters** beside the search opens a card:
  - **Runs on:** Linux native, SteamOS Compatible, Not on SteamOS, Not rated. Tick any number; a game shows if it matches one of them.
  - **Played:** any, played, or never played.
  - **Only:** favorites (your Steam Favorites collection), and on Installed, games waiting on an update.
  
  Each choice shows how many games it would leave, changes apply at once, and the card shows how many games are left. The filters you have on show as chips under the search; click one to remove it, or **Clear all**. Tab counts follow the filters.

SteamOS is the rating used here rather than the Steam Deck one, as it's the closest to how a game runs on a desktop Linux like Arch. Steam only rates SteamOS as Compatible or Unsupported.

### Game details

The list shows each game's cover, when you last played it, its size, a star for favorites and a sync icon while an update waits or downloads. The game you pick shows on the right:

- **Badges:** Linux native or Proton, its SteamOS rating, Favorite, and its update state (waiting, downloading with a percent, paused, or mods to update).
- **Played:** when, and for how long.
- **Size:** everything it takes and on which drive, broken down into the game, workshop mods (with their count), its Proton prefix and its shader cache.
- **Runs with:** the Proton version it last ran with, or the one forced in Steam.
- **Build:** its build id and when it was last updated.
- **Buttons:** **Launch** (green), **Install** or **Uninstall** (red), which open Steam's own dialog where you pick the drive or confirm. Then a folder icon that opens the install folder, and a terminal icon that opens the game's Properties in Steam, where its launch options are set; hovering it shows the current ones (such as `mangohud %command%`).
- **DLC:** a folded list, with how many you own and have installed. Open it to see each one as installed, owned or not owned.

Click the SteamOS badge for the full compatibility report Valve stores for the game: the SteamOS, Steam Deck and Steam Machine ratings, when and on which build it was tested, every test result in plain words (such as "Some text is too small to read comfortably" or "Its anti-cheat doesn't support SteamOS"), and the settings Valve recorded, such as the recommended Proton, whether it needs the internet for single player, and HDR. Esc closes it.

At the bottom: a green dot and "Steam is running" with your name on Steam, or a yellow one when it isn't, and each drive that holds a Steam library with how much is free.

Keyboard: up and down move through the games; right goes to the SteamOS badge, then down to the buttons and the DLC list; left comes back. Colors come from your theme.

Covers are the ones Steam already keeps in `appcache/librarycache`. A game Steam has no art for shows a gamepad instead.

Owned games come from your account's license cache, so refunded games and expired free weekends are left out. Tools such as Proton, and DLC, aren't listed as games. The library reading is ported from [omarchy-quick-steam](https://github.com/Rysen-Winters/omarchy-quick-steam) by Rysen Winters (MIT, see `licenses/omarchy-quick-steam.txt`).

## Commands

```bash
omarchy-shell gamercenter toggle      # the overlay; also: show, hide
omarchy-shell gamercenter position bottom-right
omarchy-shell gamercenter fps on      # also: off, toggle
omarchy-shell gamercenter gamemode on # also: off, toggle
omarchy-shell gamercenter status      # settings and state as JSON
omarchy-shell gamercenter stats       # the latest sample as JSON
```

Positions: `top-left`, `top-center`, `top-right`, `bottom-left`, `bottom-center`, `bottom-right`.

## Notes

- Stats come from `bin/gamercenter-stats` (Python, standard library only). It runs only while the HUD is showing or the panel is open, reads `/proc` and `/sys` plus NVML for NVIDIA cards, and never wakes a GPU that is asleep.
- If you turn on Hyprland's `render:direct_scanout`, a fullscreen game can't use it on a monitor while the HUD is showing there.
- Game mode runs `bin/gamercenter-gamemode` (Python, standard library only): every 20 seconds, every 3 while its page is open.
- The Steam page runs `bin/gamercenter-steam` (Python, standard library only) when it opens and every 5 seconds while it stays open. A reading takes about 0.15 s. Proton prefix and shader cache sizes need a folder walk, so they're read at most once a minute; the compatibility report is read when you open it. Deals come from `bin/gamercenter-deals` and other games from `bin/gamercenter-games`.
- Run the tests with `tests/run.sh`.
