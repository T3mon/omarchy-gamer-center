# Gamer Center

Omarchy shell plugin `t3mon.gamercenter`: game tools in the bar. The panel has two pages: Stats (a stats HUD over games and a MangoHud FPS switch) and Game mode (ported from YassineSawahi/omarchy-gamemode, MIT). Ideas for later, built only when asked: Steam free games and deals, FPS for browser games.

Before writing plugin code, load the `omarchy-plugin-dev` skill. It covers how Omarchy plugins load, the `qs.Ui` kit, IPC, layer shell and the reload loop. This file covers only this plugin.

## Files

| Path | What it does |
|---|---|
| `manifest.json` | id `t3mon.gamercenter`, kinds `service` and `bar-widget` |
| `Service.qml` | Always running. Owns the overlay settings, the stats helper, fullscreen detection, one HUD window per target screen, MangoHud control, and the IPC target `gamercenter` |
| `Panel.qml` | Bar icon (gamepad) and the panel with its Stats and Game mode pages. Left-click opens the panel, right-click toggles the overlay, middle-click toggles game mode |
| `gamemode/GameMode.qml` | Game mode state, owned by the service: reads `gamercenter-gamemode status`, cleans it, starts switches detached |
| `overlay/Metrics.js` | Pure JS with no QML types: settings defaults and sanitizing, positions, turning a stats sample into HUD lines. Tested in Node |
| `overlay/HudWindow.qml` | Layer-shell window on the Overlay layer: click-through, no keyboard focus, namespace `gamer-center-hud` |
| `overlay/HudCard.qml` | Draws the HUD (stacked grid or one line). The panel reuses it for its preview |
| `bin/gamercenter-stats` | Stats streamer, Python standard library, one JSON object per line |
| `bin/gamercenter-mangohud` | Manages our block in MangoHud.conf: `status`, `apply`, `remove` |
| `bin/gamercenter-gamemode` | Game mode helper, ported from omarchy-gamemode: `status`, `select`, `on`, `off`, `toggle`, `pause`, `resume`, `auto`, `detect` |
| `licenses/omarchy-gamemode.txt` | The MIT notice the port must keep |
| `i18n/en.json` | Every UI string |
| `tests/` | `run.sh` runs all checks |

## How it fits together

- **Settings** live in `~/.config/gamer-center/overlay.json`, read through a watched `FileView` and always passed through `Metrics.sanitize`. Changes go through `update()` and are saved 300 ms later; the service ignores the echo of its own write. A new feature gets its own file in that folder (`gamemode.json`, ...).
- **Stats**: `statsProc` runs `python3 -I bin/gamercenter-stats --interval N --gpu auto|SLOT` only while `streaming` is true (HUD showing, or the panel holding a preview through `retainPreview()` / `releasePreview()`). It restarts when the interval or GPU changes and backs off up to 30 s when it keeps failing.
- **Sample shape**: `{cpu:{load,temp,mhz}, ram:{used,total}, gpus:[{id,vendor,driver,discrete,asleep,name,label,load,temp,mhz,vramUsed,vramTotal,power}], primary, battery:{watts,state}|null}`. Memory is in MiB, and a value is null when the hardware doesn't report it.
- **HUD**: `Metrics.rows(stats, metrics, opts)` → `hudRows` → `Variants` over `targetScreens` → `HudWindow` → `HudCard`. Target screens: the pinned display; else every screen in fullscreen-only mode; else the focused monitor.
- **Fullscreen**: `Hyprland.monitorFor(screen).activeWorkspace.toplevels`, with `lastIpcObject.fullscreen & 2`, refreshed on Hyprland raw events (debounced 100 ms, re-read 250 ms later). Over a fullscreen window the HUD ignores exclusive zones; otherwise it sits below the bar.
- **MangoHud**: `mangoRun()` runs the helper one call at a time, queueing the rest. "Show FPS" writes the block on the side opposite the HUD, with a font size taken from the HUD scale, and `mangoFollow` re-applies it when the HUD moves. The install button opens a floating terminal running `omarchy pkg add mangohud`, plus `lib32-mangohud` when multilib has it.
- **Panel to service**: the panel finds the service with `bar.shell.serviceFor("t3mon.gamercenter")`, retrying every second because the lookup isn't reactive. Every edit goes through the service: `setValue()`, `toggleMetric()`, `setEnabled()`, `setFps()`, `setFpsGraph()`.

## Game mode

- Ported from omarchy-gamemode 1.0.2 with its behavior kept. Our changes: state in `~/.local/state/gamer-center/gamemode/`, notifications as "Gamer Center", `nvidia-smi` skipped while the NVIDIA GPU is runtime-suspended, run as `python3 -I`.
- `GameMode.qml` reads status every 20 s, every 3 s while the Game mode page is open (`watchers`), every 1 s while a switch runs. Switches run through `setsid -f` so they outlive a shell restart; a lock file in the state folder marks one in flight.
- Item keys go back to the helper as single argv entries, after `validKey()`. `select`, `pause` and `resume` take several keys (up to 64, checked against `ITEM_KEY`), so a section's switch is one call: `GameMode.setItems(list, on)`.
- The caption line "Tick what to pause" carries an **All** switch at its right end (`gmAll`, row `gm-all`, lined up with the row switches); below it apps and the indexer flat and sorted by RAM (`gmLoose`), then Docker in a folder (`gmGroups`, sorted by RAM too, one bordered `GroupTitle` row: target 0 folds it via `gmFolds`, folded by default over four projects; target 1 switches the whole folder). Rows are `GmRow`. Labels and details are stripped of control characters.
- Automatic mode (our addition): `auto on|off` saves `"auto"` in `selection.json`; `detect` prints `{"game": name|null}` from comm and cmdline only (reaper SteamLaunch, a non-helper `.exe`, gamescope). `GameMode.qml` runs it every 3 s while auto is on, needs 2 readings in a row, runs `on --auto` (state `"auto": true`), and runs `off` 15 s after the game is gone only when the state has that mark. `gameHandled` stops it re-pausing after a manual restore mid-game.
- Workspaces (our addition): pausing an app saves `windows` ([{class, title, workspace}] from `hyprctl clients -j`, matched by the app's pids). `reopen()` starts a thread that watches for new windows of those classes for up to 30 s and moves each one with `hl.dsp.window.move({ workspace, follow = false, window = "address:…" })`, matching by title, else the most-used workspace. Workspace names and addresses are checked against strict patterns before going into the Lua string.
- Docker items need the user in the `docker` group; without it `docker ps` is refused and no projects are listed. Omarchy leaves users out of that group on purpose (it's root-equivalent); the opt-in is Setup > Security > Sudoless Docker, and it needs a reboot, not just a logout.
- `split_title()`: Chromium-based browsers put their whole command line in argv[0]; it's split when its first word is the program (`/proc/<pid>/exe`).
- Tests must never run `on`, `off`, `pause` or `resume` for real: they close the user's apps and stop containers.

## Stats helper

- NVIDIA: NVML through ctypes, using memory info v2 (v1 counts reserved memory as used). nvidia-smi is only a fallback (`--no-nvml`).
- Intel: busy time from DRM fdinfo. Other GPUs: sysfs `gpu_busy_percent` and hwmon.
- A runtime-suspended dGPU is reported as `asleep` and never woken.
- The primary GPU is the busier one, with hysteresis (10-point margin held for 3 samples) so it doesn't flap.
- The helper exits when its parent dies or stdout closes. A sample takes about 5 ms.
- `--root DIR` reads a fixture tree instead of /proc and /sys (used by the tests).

## Rules

- Every `Text` sets `textFormat: Text.PlainText`; `tests/check_plaintext.py` fails otherwise.
- Processes get argv arrays. Never build a shell string from settings, helper output or IPC input.
- Anything read from disk, a helper or IPC goes through `Metrics.sanitize`, `printable` or a whitelist first.
- All UI strings go in `i18n/en.json`, and numbers go through `Commons.I18n.formatNumber`.
- Helpers use the Python standard library only and run as `python3 -I`.
- The stats helper runs only while something is on screen.
- Don't copy Ready Room's UI (gdeyoung/omarchy-ready-room) 1:1.

## Loop

```bash
omarchy restart shell        # after any QML/JS change; hot reload keeps the old code
journalctl --user -t omarchy-shell -n 80 --no-pager
omarchy-shell gamercenter status
tests/run.sh                 # the JS tests need node on PATH
omarchy plugin validate .
```

## Not verified yet

- The HUD over a real fullscreen game, including the exclusion-mode switch.
- The Install MangoHud and Copy buttons.
- Right-click on the bar icon.
- Game mode's Pause and Restore on this machine (they would close the user's apps).
- Automatic mode with a real game running.
- Middle-click on the bar icon.
- The All switch and the Docker folder's switch in the Game mode list (folding was checked).

## Git

Commits are authored as T3mon only: no Co-Authored-By line and no Claude mention anywhere. Use one short subject line with no body.
