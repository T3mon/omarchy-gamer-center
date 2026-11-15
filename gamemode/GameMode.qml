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
    if (!item || !validKey(item.key)) return
    if (gameOn) {
      // While game mode is on a switch acts at once: pause one more, or bring one back.
      if (working) return
      var p = Object.assign({}, itemPending)
      p[item.key] = paused(item) ? "resume" : "pause"
      itemPending = p
      launch([p[item.key], item.key])
      return
    }
    var s = Object.assign({}, selectPending)
    s[item.key] = !ticked(item)
    selectPending = s
    selectProc.command = ["python3", "-I", root.helper, "select", item.key, s[item.key] ? "on" : "off"]
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
