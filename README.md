# Gamer Center

Game tools for the Omarchy shell. The panel has two pages:

- **Stats:** a HUD over your games (CPU and GPU load, temperature and clock, GPU power, RAM, VRAM, battery draw and the time) and a switch for MangoHud's in-game FPS counter.
- **Game mode:** frees memory before you play by closing big apps, stopping Docker projects and the file indexer, then brings them all back afterwards.

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

The page lists everything worth pausing: apps over 150 MB, each Docker Compose project, and the file indexer. Each row shows the RAM (plus swap) and VRAM it holds. Tick what you want gone and press **Pause ticked**. Chrome, Chromium, Slack, Discord, the indexer and Compose projects start ticked, and your ticks are remembered. While game mode is on, each switch acts at once: switch one off to bring just that back, or on to pause one more. **Restore all** brings everything back.

- **Apps** get SIGTERM, so they can save and quit; nothing is killed. They reopen with their original command line, and Chrome and Chromium come back with their last session.
- **Containers** stop with `docker stop` and start again dependencies first, waiting for healthchecks.
- **Never touched:** terminals and anything running an AI coding agent, game launchers and games (Steam, Proton, Wine, Lutris, Heroic, gamescope, any `.exe`), browsers started by automation tools, the desktop itself, sandboxed apps, and other accounts' processes.
- **The record** of what was paused lives in `~/.local/state/gamer-center/gamemode/` (private to you), so "Restore all" still works after a reboot.
- A runtime-suspended NVIDIA GPU is never woken to read its VRAM.

Turn game mode on before you launch the game, so the memory is free from the start.

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
- Run the tests with `tests/run.sh`.
