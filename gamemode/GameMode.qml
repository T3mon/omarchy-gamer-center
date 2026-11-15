import QtQuick
import Quickshell
import Quickshell.Io

// Game mode state, ported from omarchy-gamemode by Yassine Sawahi (MIT).
// bin/gamercenter-gamemode does the work; this reads its status and starts
// its switches. The service owns one of these; the panel shows it.
Item {
  id: root

  required property string helper

  // Latest `status` reading, cleaned; null until the first one lands.
  property var status: null
  // How many open panels are looking: they get a reading every 3 s.
  property int watchers: 0
  property bool refreshQueued: false

  // "on" or "off" clicked but not yet finished. Switches run detached, so they
  // survive a shell restart; while one holds the lock the reading is fast.
  property string pending: ""
  // key → ticked, for a tick not yet confirmed by a reading.
  property var selectPending: ({})
  // key → "pause" or "resume", for one item switched while game mode is on.
  property var itemPending: ({})

  readonly property bool working: pending !== "" || Object.keys(itemPending).length > 0
    || (!!status && status.busy)
  readonly property bool gameOn: pending !== "" ? pending === "on" : !!status && status.on
  readonly property var items: status ? status.items : []
  readonly property var mem: status ? status.mem : null
  readonly property var gpu: status ? status.gpu : null

  function ticked(item) {
    var p = selectPending[item.key]
    return p !== undefined ? p : item.selected
  }

  function paused(item) {
    var p = itemPending[item.key]
    return p !== undefined ? p === "pause" : item.paused
  }

  readonly property int tickedMB: items.reduce(function(sum, i) {
    return sum + (!i.paused && root.ticked(i) ? i.mb : 0)
  }, 0)
  readonly property int tickedVram: items.reduce(function(sum, i) {
    return sum + (!i.paused && root.ticked(i) ? i.vram : 0)
  }, 0)
  readonly property int tickedCount: items.filter(function(i) { return !i.paused && root.ticked(i) }).length

  // ------------------------------------------------------------ reading

  function text(v, max) {
    return typeof v === "string" ? v.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").slice(0, max) : ""
  }

  function count(v) {
    return typeof v === "number" && isFinite(v) && v > 0 ? Math.round(v) : 0
  }

  // Keys go back to the helper as one argv entry each, never through a shell.
  function validKey(k) {
    return typeof k === "string" && k.length <= 160 && /^(indexer|app:[^\s\u0000-\u001f]+|docker:[^\u0000-\u001f]+)$/.test(k)
  }

  function clean(data) {
    if (!data || typeof data !== "object" || !Array.isArray(data.items)) return null
    var items = []
    for (var i = 0; i < data.items.length && items.length < 64; i++) {
      var it = data.items[i]
      if (!it || !validKey(it.key)) continue
      items.push({
        key: it.key,
        kind: ["app", "docker", "indexer"].indexOf(it.kind) >= 0 ? it.kind : "app",
        label: text(it.label, 80),
        detail: text(it.detail, 160),
        mb: count(it.mb),
        vram: count(it.vram),
        paused: it.paused === true,
        selected: it.selected === true
      })
    }
    var mem = data.mem && typeof data.mem === "object"
      ? { availableMB: count(data.mem.availableMB), totalMB: count(data.mem.totalMB) } : null
    var gpu = data.gpu && typeof data.gpu === "object" && count(data.gpu.totalMB) > 0
      ? { usedMB: count(data.gpu.usedMB), totalMB: count(data.gpu.totalMB) } : null
    return {
      on: data.on === true,
      auto: data.auto === true,
      autoOn: data.autoOn === true,
      busy: data.busy === true,
      since: count(data.since),
      freedMB: count(data.freedMB),
      freedVramMB: count(data.freedVramMB),
      mem: mem,
      gpu: gpu,
      items: items
    }
  }

  function refresh() {
    if (readProc.running) refreshQueued = true
    else readProc.running = true
  }

  function applyReading(raw) {
    var data
    try { data = clean(JSON.parse(String(raw || ""))) } catch (e) { data = null }
    if (!data) return
    status = data
    if (data.busy) return
    if (pending !== "" && data.on === (pending === "on")) pending = ""
    // An item switch is done once the helper let go and the item shows the new state.
    var left = {}
    for (var k in itemPending) {
      var want = itemPending[k] === "pause"
      var item = data.items.find(function(i) { return i.key === k })
      if (item && item.paused !== want) left[k] = itemPending[k]
    }
    itemPending = left
    if (!selectProc.running) selectPending = ({})
  }

  // ------------------------------------------------------------ automatic
  //
  // With the switch on, a game opening turns game mode on (marked --auto), and
  // the game closing turns it off again, but only if a game turned it on. A
  // game is handled once: restoring by hand mid-game sticks until it ends.

  property var autoPending: null   // true/false while `auto on|off` is being saved
  readonly property bool autoEnabled: autoPending !== null ? autoPending : !!status && status.auto
  property string game: ""         // the running game's name, "" when none
  property int gameSeen: 0         // readings in a row that saw a game
  property double gameLastSeen: 0
  property bool gameHandled: false
  readonly property int gameEndGrace: 15000

  function setAuto(on) {
    autoPending = on === true
    autoProc.command = ["python3", "-I", root.helper, "auto", autoPending ? "on" : "off"]
    autoProc.running = true
  }

  function takeDetect(raw) {
    var name = null
    try { var d = JSON.parse(String(raw || "")); name = d && typeof d.game === "string" ? d.game : null } catch (e) { name = null }
    game = name ? text(name, 80) : ""
    if (!autoEnabled) { gameSeen = 0; gameHandled = false; return }
    if (!status) return
    if (game !== "") {
      gameSeen++
      gameLastSeen = Date.now()
      // Two readings in a row, so a short-lived installer .exe doesn't count.
      if (gameSeen >= 2 && !gameHandled) {
        gameHandled = true
        if (!gameOn && !working && tickedCount > 0) {
          pending = "on"
          launch(["on", "--auto"])
        }
      }
      return
    }
    gameSeen = 0
    if (!gameHandled || Date.now() - gameLastSeen < gameEndGrace) return
    gameHandled = false
    if (status.on && status.autoOn && !working) {
      pending = "off"
      launch(["off"])
    }
  }

  Process {
    id: autoProc
    onExited: { root.autoPending = null; root.refresh() }
  }

  Process {
    id: detectProc
    command: ["python3", "-I", root.helper, "detect"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeDetect(text)
    }
  }

  Timer {
    interval: 3000
    running: root.autoEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!detectProc.running) detectProc.running = true
  }

  // ------------------------------------------------------------ switching

  // Detached, so a long restore carries on even if the shell restarts.
  function launch(args) {
    Quickshell.execDetached(["setsid", "-f", "python3", "-I", root.helper].concat(args))
    giveUp.restart()
    refresh()
  }

  // Returns false when there's nothing to do (busy, no reading, nothing ticked).
  function setGameMode(on) {
    if (working || !status) return false
    if (on === gameOn) return true
    if (on && tickedCount === 0) return false
    pending = on ? "on" : "off"
    launch([pending])
    return true
  }

  function toggleGameMode() { return setGameMode(!gameOn) }

  function clickItem(item) {
    if (!item) return
    setItems([item], gameOn ? !paused(item) : !ticked(item))
  }

  // Switches several items to one state: ticked (off) or paused (on). A
  // group's switch uses this, so a whole Docker section is one helper call.
  function setItems(list, on) {
    var keys = (list || []).filter(function(i) {
      return i && validKey(i.key) && (root.gameOn ? root.paused(i) : root.ticked(i)) !== on
    }).map(function(i) { return i.key }).slice(0, 64)
    if (!keys.length) return
    if (gameOn) {
      // While game mode is on a switch acts at once: pause more, or bring some back.
      if (working) return
      var p = Object.assign({}, itemPending)
      keys.forEach(function(k) { p[k] = on ? "pause" : "resume" })
      itemPending = p
      launch([on ? "pause" : "resume"].concat(keys))
      return
    }
    if (selectProc.running) return
    var s = Object.assign({}, selectPending)
    keys.forEach(function(k) { s[k] = on })
    selectPending = s
    selectProc.command = ["python3", "-I", root.helper, "select"].concat(keys, [on ? "on" : "off"])
    selectProc.running = true
  }

  Process {
    id: readProc
    command: ["python3", "-I", root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyReading(text)
    }
    onExited: {
      if (!root.refreshQueued) return
      root.refreshQueued = false
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: selectProc
    onExited: root.refresh()
  }

  // If the helper never got going, stop showing it as busy.
  Timer {
    id: giveUp
    interval: 300000
    onTriggered: {
      root.pending = ""
      root.itemPending = ({})
    }
  }

  Timer {
    interval: root.working ? 1000 : root.watchers > 0 ? 3000 : 20000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
