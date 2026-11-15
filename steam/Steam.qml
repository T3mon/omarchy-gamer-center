import QtQuick
import Quickshell
import Quickshell.Io
import "Library.js" as Library

// The Steam library, owned by the service: reads bin/gamercenter-steam while
// a panel shows the Steam page, and hands launches, installs and uninstalls
// to Steam through steam:// links.
Item {
  id: root

  required property string helper

  // How many open panels show the Steam page: they get a reading every 5 s.
  property int watchers: 0
  // The latest reading, cleaned; null until the first one lands.
  property var library: null
  // "reading" until the first answer, then "ready", "missing" (no Steam
  // folder) or "failed".
  property string phase: "reading"
  property string lastRaw: ""
  property bool refreshQueued: false

  readonly property var games: library ? library.games : []
  readonly property var drives: library ? library.drives : []

  function refresh() {
    if (readProc.running) refreshQueued = true
    else readProc.running = true
  }

  function take(raw) {
    raw = String(raw || "")
    if (raw === lastRaw && library) return
    var data
    try { data = JSON.parse(raw) } catch (e) { data = null }
    var cleaned = Library.clean(data)
    if (cleaned) {
      lastRaw = raw
      library = cleaned
      phase = "ready"
    } else if (!library) {
      phase = data && data.ok === false && data.error === "steam-not-found" ? "missing" : "failed"
    }
  }

  function game(id) {
    for (var i = 0; i < games.length; i++) if (games[i].id === id) return games[i]
    return null
  }

  // action: "run", "install" or "uninstall". Install and uninstall open
  // Steam's own dialog, which picks the drive or asks to confirm.
  function open(action, id) {
    var url = Library.steamUrl(action, id)
    if (!url) return false
    Quickshell.execDetached(Library.openCommand(url, !!library && library.uwsm))
    return true
  }

  onWatchersChanged: if (watchers > 0) refresh()

  Process {
    id: readProc
    command: ["python3", "-I", root.helper]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.take(text)
    }
    onRunningChanged: {
      if (running || !root.refreshQueued) return
      root.refreshQueued = false
      Qt.callLater(root.refresh)
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.watchers > 0
    onTriggered: root.refresh()
  }
}
