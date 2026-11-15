# Gamer Center

Game tools for the Omarchy shell. For now that's a stats HUD over your games (CPU and GPU load, temperature and clock, GPU power, RAM, VRAM, battery draw and the time) and a switch for MangoHud's in-game FPS counter.

## Install

```bash
omarchy plugin add https://github.com/T3mon/omarchy-gamer-center --enable
```

It shows up in the bar as a gamepad icon. Left-click opens the panel, right-click turns the overlay on or off.

## Overlay

The panel has a live preview. Click where the HUD should sit, pick the stats, a stacked or one-line layout, the size and the backdrop. Under Behavior you can keep it hidden until a window goes fullscreen, change the update rate, and pin a GPU or a display when you have more than one.

Settings are saved in `~/.config/gamer-center/overlay.json`. Edits to that file apply right away.

## FPS

The shell can't see a game's frame rate, so FPS comes from MangoHud, which draws inside the game. The panel can install it. "Show FPS in games" adds a marked block to `~/.config/MangoHud/MangoHud.conf` and leaves your own lines alone. The block puts the FPS on the side opposite the HUD, at a matching size.

MangoHud only runs in games started through it: add `mangohud %command%` to a Steam game's launch options (the panel copies it for you), or run `mangohud <game>`.

## Commands

```bash
omarchy-shell gamercenter toggle      # the overlay; also: show, hide
omarchy-shell gamercenter position bottom-right
omarchy-shell gamercenter fps on      # also: off, toggle
omarchy-shell gamercenter status      # settings and state as JSON
omarchy-shell gamercenter stats       # the latest sample as JSON
```

Positions: `top-left`, `top-center`, `top-right`, `bottom-left`, `bottom-center`, `bottom-right`.

## Notes

- Stats come from `bin/gamercenter-stats` (Python, standard library only). It runs only while the HUD is showing or the panel is open, reads `/proc` and `/sys` plus NVML for NVIDIA cards, and never wakes a GPU that is asleep.
- If you turn on Hyprland's `render:direct_scanout`, a fullscreen game can't use it on a monitor while the HUD is showing there.
- Run the tests with `tests/run.sh`.
