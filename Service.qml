import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "overlay"
import "gamemode"
import "steam"
import "overlay/Metrics.js" as Metrics

// Owns the Gamer Center overlay (its settings file, the stats helper, the HUD windows,
// the MangoHud block), game mode and the Steam library. The bar panel only reads from here and calls in.
Item {
  id: root

  // Injected by the shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/+$/, "")
  readonly property string statsHelper: pluginDir + "/bin/gamercenter-stats"
  readonly property string mangoHelper: pluginDir + "/bin/gamercenter-mangohud"
  readonly property string gameModeHelper: pluginDir + "/bin/gamercenter-gamemode"
  readonly property string steamHelper: pluginDir + "/bin/gamercenter-steam"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/gamer-center"
  readonly property string configPath: configDir + "/overlay.json"

  property var config: Metrics.sanitize(null)
  property bool configReady: false
  property bool configDirReady: false
  property string savedText: ""

  property var stats: null
  property int statsFailures: 0
  readonly property bool statsFailed: statsFailures >= 3
  property string timeText: ""
  // The panel holds one of these while open, so its readouts stay live
  // even when the HUD itself is off.
  property int previewRequests: 0

  property var mango: ({ installed: false, lib32: false, managed: false, position: null, graph: false, fontSize: null })
  property bool mangoReady: false
  property bool mangoFailed: false
  readonly property bool mangoBusy: mangoProc.running

  // Bumped after Hyprland's window list refreshes, so fullscreenOn() re-reads it.
  property int hyprRevision: 0

  readonly property bool hudOn: configReady && config.enabled
  readonly property var screenNames: Quickshell.screens.map(function(s) { return String(s.name) })

  // Which outputs get a HUD: the pinned one, else the focused one. In
  // fullscreen-only mode every output gets a window that stays unmapped
  // until something goes fullscreen on it, so a game on a second monitor is
  // still covered after focus moves away from it.
  readonly property var targetScreens: {
    var screens = Quickshell.screens
    if (!hudOn || !screens.length) return []
    var pinned = config.screen
    for (var i = 0; pinned && i < screens.length; i++)
      if (String(screens[i].name) === pinned) return [screens[i]]
    if (config.fullscreenOnly) return screens.slice()
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name) : ""
    for (var j = 0; j < screens.length; j++)
      if (String(screens[j].name) === focused) return [screens[j]]
    return [screens[0]]
  }

  readonly property bool anyFullscreen: {
    var list = targetScreens
    for (var i = 0; i < list.length; i++) if (fullscreenOn(list[i])) return true
    return false
  }
  readonly property bool hudShowing: hudOn && targetScreens.length > 0 && (!config.fullscreenOnly || anyFullscreen)
  readonly property bool streaming: hudShowing || previewRequests > 0

  readonly property var hudLabels: ({
    cpu: strings.t("hud.cpu"),
    gpu: strings.t("hud.gpu"),
    ram: strings.t("hud.ram"),
    vram: strings.t("hud.vram"),
    battery: strings.t("hud.battery"),
    asleep: strings.t("hud.asleep"),
    ac: strings.t("hud.ac")
  })
  readonly property var hudRows: Metrics.rows(stats, config.metrics, {
    formatNumber: function(value, decimals) { return Commons.I18n.formatNumber(value, decimals) },
    timeText: timeText,
    labels: hudLabels
  })

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------ settings

  function setValue(key, value) {
    update(Metrics.withValue(config, key, value))
  }

  function toggleMetric(id) {
    update(Metrics.toggleMetric(config, id))
  }

  function setEnabled(on) {
    setValue("enabled", on === true)
  }

  function update(next) {
    if (!configReady) return false
    var clean = Metrics.sanitize(next)
    if (JSON.stringify(clean) === JSON.stringify(config)) return true
    var moved = clean.position !== config.position || clean.scale !== config.scale
    config = clean
    saveTimer.restart()
    if (moved && mango.managed) mangoFollow.restart()
    return true
  }

  function takeConfig(raw) {
    // Our own write coming back through the file watch, or a stale event
    // while a newer change is still waiting to be written: keep what we have.
    if (configReady && (raw === savedText || saveTimer.running)) return
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    config = Metrics.sanitize(parsed)
    configReady = true
  }

  function save() {
    if (!configDirReady) { saveTimer.restart(); return }
    savedText = JSON.stringify(config, null, 2) + "\n"
    configFile.setText(savedText)
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", "--", root.configDir]
    onExited: function(code) { root.configDirReady = code === 0 }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.takeConfig(text())
    onLoadFailed: root.takeConfig("")
    onFileChanged: reload()
  }

  Timer {
    id: saveTimer
    interval: 300
    onTriggered: root.save()
  }

  // ------------------------------------------------------------ stats

  property string statsKey: ""
  property bool statsRestarting: false

  function statsCommand() {
    return ["python3", "-I", statsHelper, "--interval", String(config.interval), "--gpu", config.gpu]
  }

  function syncStats() {
    var key = streaming ? JSON.stringify(statsCommand()) : ""
    if (statsProc.running) {
      if (key === statsKey) return
      statsRestarting = key !== ""
      statsProc.running = false
      return
    }
    if (!key || statsRetry.running) return
    statsKey = key
    statsProc.command = statsCommand()
    statsProc.running = true
  }

  function takeStats(line) {
    if (!line || line.length > 65536) return
    var parsed = null
    try { parsed = JSON.parse(line) } catch (e) { return }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return
    statsFailures = 0
    stats = parsed
  }

  onStreamingChanged: {
    if (!streaming) stats = null
    syncStats()
  }

  onConfigChanged: syncStats()

  Process {
    id: statsProc
    stdout: SplitParser {
      onRead: function(line) { root.takeStats(line) }
    }
    onRunningChanged: {
      if (running) return
      root.statsKey = ""
      if (root.statsRestarting) {
        root.statsRestarting = false
        root.syncStats()
        return
      }
      if (!root.streaming) return
      // Died on its own: back off so a broken helper does not spin.
      root.statsFailures++
      statsRetry.interval = Math.min(30000, 1000 * Math.pow(2, Math.min(root.statsFailures, 5)))
      statsRetry.restart()
    }
  }

  Timer {
    id: statsRetry
    onTriggered: root.syncStats()
  }

  function refreshTime() {
    timeText = new Date().toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.streaming && root.config.metrics.indexOf("time") !== -1
    onTriggered: root.refreshTime()
  }

  // ------------------------------------------------------------ fullscreen

  function fullscreenOn(screen) {
    var revision = hyprRevision
    var monitor = screen ? Hyprland.monitorFor(screen) : null
    var workspace = monitor ? monitor.activeWorkspace : null
    if (!workspace || !workspace.toplevels) return false
    var windows = workspace.toplevels.values
    for (var i = 0; i < windows.length; i++) {
      var ipc = windows[i].lastIpcObject || {}
      // 1 is maximized; only 2 and 3 cover the whole output.
      if ((Number(ipc.fullscreen) & 2) !== 0) return true
    }
    return false
  }

  Connections {
    target: Hyprland
    enabled: root.hudOn
    function onRawEvent(event) {
      switch (event.name) {
      case "fullscreen": case "openwindow": case "closewindow": case "movewindowv2":
      case "activewindowv2": case "workspacev2": case "focusedmonv2":
        hyprRefresh.restart()
      }
    }
  }

  // Debounce a burst of events, then let the IPC answer land before re-reading.
  Timer {
    id: hyprRefresh
    interval: 100
    onTriggered: { Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels(); hyprSettle.restart() }
  }

  Timer {
    id: hyprSettle
    interval: 250
    onTriggered: root.hyprRevision++
  }

  onHudOnChanged: if (hudOn) hyprRefresh.restart()

  Variants {
    model: root.targetScreens

    delegate: Component {
      HudWindow {
        required property var modelData
        screen: modelData
        service: root
      }
    }
  }

  // ------------------------------------------------------------ MangoHud

  property var mangoQueued: null

  function mangoRun(args) {
    if (mangoProc.running) { mangoQueued = args; return }
    mangoProc.command = ["python3", "-I", mangoHelper].concat(args)
    mangoProc.running = true
  }

  function mangoApplyArgs(graph) {
    var args = ["apply", "--position", Metrics.mangoPosition(config.position),
                "--font-size", String(Metrics.mangoFontSize(config.scale))]
    if (graph) args.push("--graph")
    return args
  }

  function refreshMango() { mangoRun(["status"]) }
  function setFps(on) { mangoRun(on ? mangoApplyArgs(mango.graph) : ["remove"]) }
  function setFpsGraph(on) { if (mango.managed) mangoRun(mangoApplyArgs(on === true)) }

  function takeMango(text) {
    var parsed = null
    try { parsed = JSON.parse(String(text || "")) } catch (e) { parsed = null }
    if (!parsed || typeof parsed !== "object" || parsed.error !== undefined) {
      mangoFailed = true
      return
    }
    mangoFailed = false
    mangoReady = true
    mango = {
      installed: parsed.installed === true,
      lib32: parsed.lib32 === true,
      managed: parsed.managed === true,
      position: typeof parsed.position === "string" ? parsed.position : null,
      graph: parsed.graph === true,
      fontSize: typeof parsed.fontSize === "number" ? parsed.fontSize : null
    }
  }

  // Fixed command: nothing from settings or the network goes into it.
  function installMango() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      "omarchy pkg add mangohud && if pacman -Si lib32-mangohud >/dev/null 2>&1; then omarchy pkg add lib32-mangohud; fi"])
  }

  function copyLaunchOption() {
    Quickshell.execDetached(["wl-copy", "--", "mangohud %command%"])
  }

  Process {
    id: mangoProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeMango(text)
    }
    onExited: {
      if (!root.mangoQueued) return
      var next = root.mangoQueued
      root.mangoQueued = null
      root.mangoRun(next)
    }
  }

  // Keep MangoHud on the other side of the HUD and sized with it.
  Timer {
    id: mangoFollow
    interval: 500
    onTriggered: {
      if (!root.mango.managed) return
      if (root.mango.position === Metrics.mangoPosition(root.config.position)
          && root.mango.fontSize === Metrics.mangoFontSize(root.config.scale)) return
      root.mangoRun(root.mangoApplyArgs(root.mango.graph))
    }
  }

  // ------------------------------------------------------------ game mode

  readonly property alias gameMode: gameModeItem

  GameMode {
    id: gameModeItem
    helper: root.gameModeHelper
  }

  // ------------------------------------------------------------ steam

  readonly property alias steam: steamItem

  Steam {
    id: steamItem
    helper: root.steamHelper
    dealsHelper: root.pluginDir + "/bin/gamercenter-deals"
    configDir: root.configDir
    configDirReady: root.configDirReady
  }

  // ------------------------------------------------------------ panel hooks

  function retainPreview() { previewRequests++ }
  function releasePreview() { previewRequests = Math.max(0, previewRequests - 1) }

  function statusObject() {
    var out = {}
    for (var key in config) out[key] = config[key]
    out.showing = hudShowing
    out.streaming = streaming
    out.screens = targetScreens.map(function(s) { return String(s.name) })
    out.mangohud = mango
    out.gameMode = gameModeItem.gameOn
    return out
  }

  ShellIpc {
    target: "gamercenter"

    function toggle(): string {
      if (!root.configReady) return "not ready"
      root.setEnabled(!root.config.enabled)
      return root.config.enabled ? "on" : "off"
    }
    function show(): string {
      if (!root.configReady) return "not ready"
      root.setEnabled(true)
      return "on"
    }
    function hide(): string {
      if (!root.configReady) return "not ready"
      root.setEnabled(false)
      return "off"
    }
    function position(name: string): string {
      if (Metrics.POSITIONS.indexOf(name) === -1) return "unknown position; use one of " + Metrics.POSITIONS.join(", ")
      root.setValue("position", name)
      return root.config.position
    }
    function fps(state: string): string {
      var on = state === "on" ? true : state === "off" ? false : state === "toggle" ? !root.mango.managed : null
      if (on === null) return "use on, off or toggle"
      root.setFps(on)
      return on ? "on" : "off"
    }
    function gamemode(state: string): string {
      var gm = gameModeItem
      var on = state === "on" ? true : state === "off" ? false : state === "toggle" ? !gm.gameOn : null
      if (on === null) return "use on, off or toggle"
      if (!gm.status) return "not ready"
      if (gm.working) return "busy"
      if (on && !gm.gameOn && gm.tickedCount === 0) return "nothing is ticked"
      gm.setGameMode(on)
      return on ? "on" : "off"
    }
    function status(): string { return JSON.stringify(root.statusObject()) }
    function stats(): string { return JSON.stringify(root.stats || {}) }
  }

  Component.onCompleted: {
    mkdirProc.running = true
    refreshMango()
  }
}
