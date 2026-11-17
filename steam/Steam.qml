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
  required property string dealsHelper
  required property string othersHelper
  // ~/.config/gamer-center, and whether it exists yet.
  required property string configDir
  property bool configDirReady: false

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
  // { running, persona }: whether Steam runs, and the account's name on it.
  readonly property var status: library ? library.steam : null
  // { appid: [Proton prefix bytes, shader cache bytes] }, from --sizes.
  property var sizes: ({})
  property double sizesAt: 0

  // Walks the prefixes and shader caches, so at most once a minute.
  function refreshSizes() {
    if (sizesProc.running || Date.now() - sizesAt < 60000) return
    sizesProc.running = true
  }

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

  // The game's install folder, in the file manager.
  function openFolder(id) {
    var g = game(id)
    var path = g ? Library.folder(g.folder) : ""
    if (!path) return false
    Quickshell.execDetached(Library.openCommand(path, !!library && library.uwsm))
    return true
  }

  // The other games are read once up front too, so their tab shows a count.
  onWatchersChanged: if (watchers > 0) { refresh(); refreshSizes(); if (!others) refreshOthers() }

  Process {
    id: sizesProc
    command: ["python3", "-I", root.helper, "--sizes"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data
        try { data = JSON.parse(text) } catch (e) { data = null }
        var cleaned = Library.cleanSizes(data)
        if (cleaned) { root.sizes = cleaned; root.sizesAt = Date.now() }
      }
    }
  }

  // ---- One game's full Steam Deck report, read when the panel asks.

  // The cleaned report ({ id, none, deck, machine, steamos, ... }) or null.
  property var deckReport: null
  // "idle", "reading", "ready" or "failed".
  property string deckPhase: "idle"
  property string deckWanted: ""

  function refreshDeck(id) {
    if (!Library.validId(id)) return
    deckWanted = id
    if (deckReport && deckReport.id === id) { deckPhase = "ready"; return }
    deckPhase = "reading"
    // One reading at a time: a game picked mid-reading is read when it ends.
    if (!deckProc.running) startDeck()
  }

  function startDeck() {
    deckProc.command = ["python3", "-I", root.helper, "--deck", deckWanted]
    deckProc.running = true
  }

  Process {
    id: deckProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data
        try { data = JSON.parse(text) } catch (e) { data = null }
        var cleaned = Library.cleanDeck(data)
        if (!cleaned) root.deckPhase = "failed"
        else if (cleaned.id === root.deckWanted) { root.deckReport = cleaned; root.deckPhase = "ready" }
        else Qt.callLater(root.startDeck)
      }
    }
  }

  // ---- Other games: app-menu entries in the Game category.

  // null until the first reading; "idle", "reading", "ready" or "failed".
  property var others: null
  property string othersPhase: "idle"
  readonly property var otherGames: others ? others.games : []

  // Read again each time the tab opens: it's quick, and a game installed
  // since shows up.
  function refreshOthers() {
    if (othersProc.running) return
    if (!others) othersPhase = "reading"
    othersProc.running = true
  }

  function takeOthers(raw) {
    var data
    try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
    var cleaned = Library.cleanOthers(data)
    if (cleaned) {
      others = cleaned
      othersPhase = "ready"
    } else if (!others) othersPhase = "failed"
  }

  function otherGame(id) {
    for (var i = 0; i < otherGames.length; i++) if (otherGames[i].id === id) return otherGames[i]
    return null
  }

  function launchOther(id) {
    var cmd = Library.entryCommand(id, !!others && others.uwsm)
    if (!otherGame(id) || !cmd.length) return false
    Quickshell.execDetached(cmd)
    return true
  }

  function openOtherFolder(id) {
    var g = otherGame(id)
    if (!g || !g.folder) return false
    Quickshell.execDetached(Library.openCommand(g.folder, !!others && others.uwsm))
    return true
  }

  Process {
    id: othersProc
    command: ["python3", "-I", root.othersHelper]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeOthers(text)
    }
  }

  // ---- Deals: 100% off games and wishlist sales, from Steam's store.

  // null until the first reading; "idle", "reading", "ready" or "failed".
  property var deals: null
  property string dealsPhase: "idle"
  property double dealsAt: 0
  // Wishlist games show from this discount up, in percent.
  property int dealMin: Library.DEAL_MIN_DEFAULT
  property string savedSettings: ""

  // Checks Steam when the last reading is over 15 minutes old.
  function refreshDeals() {
    if (dealsProc.running || (deals && Date.now() - dealsAt < 15 * 60000)) return
    if (!deals) dealsPhase = "reading"
    dealsProc.running = true
  }

  function takeDeals(raw) {
    var data
    try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
    var cleaned = Library.cleanDeals(data)
    if (cleaned) {
      deals = cleaned
      dealsAt = Date.now()
      dealsPhase = "ready"
    } else if (!deals) dealsPhase = "failed"
  }

  function setDealMin(v) {
    var m = Library.dealMin(v)
    if (m === dealMin) return
    dealMin = m
    saveTimer.restart()
  }

  Process {
    id: dealsProc
    command: ["python3", "-I", root.dealsHelper]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeDeals(text)
    }
  }

  // ~/.config/gamer-center/steam.json: { "wishlistDiscount": 50 }.
  FileView {
    id: settingsFile
    path: root.configDir + "/steam.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var raw = text()
      if (raw === root.savedSettings || saveTimer.running) return
      var data
      try { data = JSON.parse(raw) } catch (e) { data = null }
      root.dealMin = Library.dealMin(data && typeof data === "object" ? data.wishlistDiscount : null)
    }
    onFileChanged: reload()
  }

  Timer {
    id: saveTimer
    interval: 300
    onTriggered: {
      if (!root.configDirReady) { restart(); return }
      root.savedSettings = JSON.stringify({ wishlistDiscount: root.dealMin }, null, 2) + "\n"
      settingsFile.setText(root.savedSettings)
    }
  }

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
    onTriggered: { root.refresh(); root.refreshSizes() }
  }
}
