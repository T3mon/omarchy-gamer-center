# Gamer Center

Omarchy shell plugin `t3mon.gamercenter`: game tools in the bar. The panel has three pages and opens on Steam: Stats (a stats HUD over games and a MangoHud FPS switch), Game mode (ported from YassineSawahi/omarchy-gamemode, MIT) and Steam (the library, its readers ported from Rysen-Winters/omarchy-quick-steam, MIT). Ideas for later, built only when asked: Steam free games and deals, FPS for browser games.

Before writing plugin code, load the `omarchy-plugin-dev` skill. It covers how Omarchy plugins load, the `qs.Ui` kit, IPC, layer shell and the reload loop. This file covers only this plugin.

## Files

| Path | What it does |
|---|---|
| `manifest.json` | id `t3mon.gamercenter`, kinds `service` and `bar-widget` |
| `Service.qml` | Always running. Owns the overlay settings, the stats helper, fullscreen detection, one HUD window per target screen, MangoHud control, and the IPC target `gamercenter` |
| `Panel.qml` | Bar icon (gamepad) and the panel with its Stats, Game mode and Steam pages. Left-click opens the panel, right-click toggles the overlay, middle-click toggles game mode |
| `gamemode/GameMode.qml` | Game mode state, owned by the service: reads `gamercenter-gamemode status`, cleans it, starts switches detached |
| `steam/Steam.qml` | The Steam library, owned by the service: reads `gamercenter-steam` while a panel shows the Steam page, opens steam:// links |
| `steam/Library.js` | Pure JS for the Steam page: cleaning the reading, the two lists, their sort and search, cover and folder paths, Deck status, theme colors, days ago, the steam:// links. Tested in Node |
| `overlay/Metrics.js` | Pure JS with no QML types: settings defaults and sanitizing, positions, turning a stats sample into HUD lines. Tested in Node |
| `overlay/HudWindow.qml` | Layer-shell window on the Overlay layer: click-through, no keyboard focus, namespace `gamer-center-hud` |
| `overlay/HudCard.qml` | Draws the HUD (stacked grid or one line). The panel reuses it for its preview |
| `bin/gamercenter-stats` | Stats streamer, Python standard library, one JSON object per line |
| `bin/gamercenter-mangohud` | Manages our block in MangoHud.conf: `status`, `apply`, `remove` |
| `bin/gamercenter-gamemode` | Game mode helper, ported from omarchy-gamemode: `status`, `select`, `on`, `off`, `toggle`, `pause`, `resume`, `auto`, `detect` |
| `bin/gamercenter-steam` | Steam library reader: one JSON object with drives and games. `--root DIR` reads a fixture Steam folder |
| `licenses/omarchy-gamemode.txt`, `licenses/omarchy-quick-steam.txt` | The MIT notices the ports must keep |
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
- Browsers reopen through `reopen_argv()`: `--app=`, `--app-id=`, `--new-window` and URLs are dropped, since the first window's process may be an Omarchy web app and `--app` skips the session restore.
- `split_title()`: Chromium-based browsers put their whole command line in argv[0]; it's split when its first word is the program (`/proc/<pid>/exe`).
- Tests must never run `on`, `off`, `pause` or `resume` for real: they close the user's apps and stop containers.

## Steam

- Bare minimum on purpose, as asked: drives, Installed / Not installed, sort (Recent, Name, Size), search, details with time played and Steam Deck status, Launch, Install, Uninstall, an open-folder icon, a launch-options icon, and local covers. Laid out like Quick Steam (list left, details right, drives along the bottom), without its search, ProtonDB, Store button or key hints. Nothing else until asked.
- `gamercenter-steam` reads, under the Steam root: `libraryfolders.vdf`, every `appmanifest_*.acf` (installed, `SizeOnDisk`), `userdata/<id>/config/licensecache` (live licenses; unscrambled with the account id as seed, CRC-checked, refunded and expired flags dropped), `appcache/packageinfo.vdf` (apps per package), `appcache/appinfo.vdf` (name and type, parsed only for owned or installed ids), `localconfig.vdf` (LastPlayed, Playtime in minutes, LaunchOptions), `installdir` from each manifest (`game_folder()`: a plain name under `steamapps/common`, a real folder, not a link), Deck status from appinfo's `steam_deck_compatibility.category` (0 unknown, 1 unsupported, 2 playable, 3 verified), and covers from `appcache/librarycache/<appid>/`: the file appinfo's `library_assets_full.library_capsule.image` names (checked against `SAFE_ASSET`), else `library_600x900.jpg`, else any `*/library_capsule.jpg`. Never fetched; `Library.cover()` only lets through paths in that cache. Only type `game` is listed; tools and DLC aren't. No licensecache means every cached package counts.
- Drives are merged by `st_dev`: one row per disk, with `statvfs` free and total.
- `Steam.qml` runs the helper when a panel's Steam page opens (`watchers`) and every 5 s while it stays open; an unchanged reading is skipped. A reading takes about 0.1 s here (118 games).
- Actions are `steam://rungameid/N`, `steam://install/N`, `steam://uninstall/N`, `steam://gameproperties/N` through `uwsm-app -- xdg-open URL` (plain `xdg-open` without uwsm). Install and Uninstall open Steam's own dialog (drive pick, confirm); the panel closes after any action. Quick Steam's `steam -silent +app_install ID FOLDER` path is not used.
- The page is wider than the others (`contentWidth` 760 vs 400). The list is a `ListView` with an int model over `stGames`, so a new reading updates rows in place. `stGameId` is the picked game; `stIndex` falls back to the first row, so the right side is never empty while there are games.
- Search: `stQuery`, matched by `Library.matches()` (every word, case and accents folded). The box is a plain `TextInput`; while `stSearching` is true `keyCatcher.blocked` hands it every key, and its own handler takes Esc (clear, then leave), Up, Down, Enter and Tab. `/` or Enter on `st-search` starts it. Cleared when the panel closes.
- Actions: `stActions` is the text buttons (run, uninstall / install) then the icon-only ones, `folder` (installed with a folder) and `options` (`steam://gameproperties/N`, Steam's Properties window with the launch options; the tooltip shows the current ones). The folder opens through `Steam.openFolder()` with the same `uwsm-app -- xdg-open` argv, after `Library.folder()`.
- Colors: Launch green, Install accent, Uninstall `Color.urgent`; Deck Verified green, Playable yellow, Unsupported urgent. The shell has no green or yellow, so `themeColorsFile` reads the theme's `colors.toml` (`Library.themeColors()`: `green`/`yellow`, else `color2`/`color3`) when the panel or the Steam page opens; foreground when missing.
- Keyboard rows: `st-top` (two tabs, then the sorts), `st-search`, `st-game-i` (moving onto one picks it), `st-actions`. Right on a game goes to the buttons; left at the first button, or up, goes back. Esc closes the panel.
- Dates: `Library.daysAgo()` counts calendar days from `stNow`, set when the panel opens: today, yesterday, N days ago under 30, else "MMM yyyy".

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
- The Steam page's Launch, Install, Uninstall, folder and launch-options buttons (they start Steam, its dialogs or the file manager), and its keyboard and mouse use: tab switch, sort, picking a game, moving to the buttons, typing in search, the icon tooltips. Both tabs, a preset search, the colors, and the Deck line were checked in screenshots.

## Git

Commits are authored as T3mon only: no Co-Authored-By line and no Claude mention anywhere. Use one short subject line with no body.
