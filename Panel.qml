import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "overlay"
import "overlay/Metrics.js" as Metrics

// Bar icon + the overlay panel. All state lives in the service; this file
// only shows it and calls in.
Panel {
  id: root
  moduleName: "t3mon.gamercenter"
  ipcTarget: "t3mon.gamercenter"

  readonly property string pluginId: "t3mon.gamercenter"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------ service

  property var service: null
  property var heldService: null

  readonly property var config: service ? service.config : Metrics.sanitize(null)
  readonly property bool hudOn: !!service && service.hudOn
  readonly property var mango: service ? service.mango : ({ installed: false, managed: false, graph: false })
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dimFg: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int labelWidth: Style.space(64)

  // Which page shows: "stats" (the overlay) or "gamemode". Kept until the
  // shell restarts.
  property string page: "stats"
  readonly property var gm: service ? service.gameMode : null
  readonly property bool gameOn: !!gm && gm.gameOn
  readonly property var gmItems: gm ? gm.items : []

  // serviceFor() is a plain lookup, not a binding: ask again whenever the
  // answer could have changed, and keep asking until the service is up.
  function resolveService() {
    if (service) return
    var api = bar && bar.shell ? bar.shell : null
    var found = api && typeof api.serviceFor === "function" ? api.serviceFor(pluginId) : null
    if (found) service = found
  }

  // While the panel is open the service streams stats even with the HUD off,
  // so the preview below is live.
  function syncPreview() {
    var want = opened && page === "stats" && service ? service : null
    if (want !== heldService) {
      if (heldService) heldService.releasePreview()
      heldService = want
      if (want) want.retainPreview()
    }
    var watch = opened && page === "gamemode" && gm ? gm : null
    if (watch !== watchedGameMode) {
      if (watchedGameMode) watchedGameMode.watchers = Math.max(0, watchedGameMode.watchers - 1)
      watchedGameMode = watch
      if (watch) { watch.watchers++; watch.refresh() }
    }
  }

  property var watchedGameMode: null

  function setPage(name) {
    if (name !== "stats" && name !== "gamemode") return
    page = name
  }

  onPageChanged: syncPreview()

  // Middle click and the Pause button: with nothing ticked, show what could be.
  function toggleGameMode() {
    if (!gm) return
    if (!gm.toggleGameMode() && !gm.gameOn && !gm.working) {
      setPage("gamemode")
      if (!opened) open()
    }
  }

  onBarChanged: resolveService()
  onServiceChanged: { syncPreview(); refreshGpuChoices() }
  Component.onCompleted: resolveService()
  Component.onDestruction: {
    if (heldService) heldService.releasePreview()
    if (watchedGameMode) watchedGameMode.watchers = Math.max(0, watchedGameMode.watchers - 1)
  }

  Timer {
    interval: 1000
    repeat: true
    running: !root.service
    onTriggered: root.resolveService()
  }

  onOpenedChanged: {
    if (opened) resolveService()
    syncPreview()
    if (!opened) return
    if (service) service.refreshMango()
    cursorRow = page === "stats" ? "enabled" : "gm-power"
    cursorCol = 0
    cursorActive = false
    cursorByMouse = false
  }

  // Pick up an install finishing in the terminal.
  Timer {
    interval: 3000
    repeat: true
    running: root.opened && !!root.service && !root.mango.installed
    onTriggered: root.service.refreshMango()
  }

  // ------------------------------------------------------------ choices

  readonly property var positionGrid: [["top-left", "top-center", "top-right"],
                                       ["bottom-left", "bottom-center", "bottom-right"]]
  readonly property var layoutOptions: [
    { value: "stack", label: strings.t("layout.stack") },
    { value: "row", label: strings.t("layout.row") }
  ]
  readonly property var intervalOptions: Metrics.INTERVALS.map(function(v) {
    return { value: String(v), label: strings.t("interval.seconds").arg(Commons.I18n.formatNumber(v, v < 1 ? 1 : 0)) }
  })
  readonly property var screenChoices: [{ value: "", label: strings.t("screen.focused") }].concat(
    (service ? service.screenNames : []).map(function(name) { return { value: name, label: name } }))

  // Rebuilt only when the set of GPUs changes, not on every sample, so the
  // chips are not recreated under the pointer once a second.
  property var gpuChoices: [{ value: "auto", label: strings.t("gpu.auto") }]
  function refreshGpuChoices() {
    var next = [{ value: "auto", label: strings.t("gpu.auto") }].concat(Metrics.gpuOptions(service ? service.stats : null))
    if (JSON.stringify(next) !== JSON.stringify(gpuChoices)) gpuChoices = next
  }

  Connections {
    target: root.service
    function onStatsChanged() { root.refreshGpuChoices() }
  }

  readonly property real screenRatio: {
    var list = service && service.targetScreens.length ? service.targetScreens : Quickshell.screens
    var s = list.length ? list[0] : null
    return s && s.width > 0 && s.height > 0 ? Math.max(1.25, Math.min(2.4, s.width / s.height)) : 16 / 9
  }

  readonly property string statusText: {
    if (!service || !service.configReady) return strings.t("status.starting")
    if (service.statsFailed && service.streaming) return strings.t("status.failed")
    if (!config.enabled) return strings.t("status.off")
    var full = config.fullscreenOnly
    var names = service.targetScreens.filter(function(s) { return !full || service.fullscreenOn(s) })
      .map(function(s) { return String(s.name) })
    if (!names.length) return strings.t("status.waiting")
    return strings.t("status.on").arg(names.join(", "))
  }

  // Which sections are unfolded. Look and Behavior start folded; the choice
  // lasts until the shell restarts.
  property var folds: ({ position: true, stats: true, look: false, behavior: false, fps: true })
  readonly property bool positionOpen: folds.position
  readonly property bool statsOpen: folds.stats
  readonly property bool lookOpen: folds.look
  readonly property bool behaviorOpen: folds.behavior
  readonly property bool fpsOpen: folds.fps

  function toggleFold(id) {
    var name = id.replace(/^fold-/, "")
    if (!(name in folds)) return
    var next = {}
    for (var k in folds) next[k] = folds[k]
    next[name] = !next[name]
    folds = next
  }

  readonly property string positionSummary: strings.t("pos." + config.position)
  readonly property string statsSummary: strings.t("fold.statsCount").arg(Commons.I18n.formatNumber(config.metrics.length))
  readonly property string fpsSummary: !mango.installed ? strings.t("fold.fpsMissing")
    : (mango.managed ? strings.t("fold.fpsOn") : strings.t("fold.fpsOff"))

  readonly property string lookSummary: {
    var layout = root.layoutOptions.filter(function(o) { return o.value === config.layout })
    return (layout.length ? layout[0].label : "") + " · " + Commons.I18n.formatNumber(Math.round(config.scale * 100)) + "%"
  }

  readonly property string behaviorSummary: {
    var parts = [strings.t("interval.seconds").arg(Commons.I18n.formatNumber(config.interval, config.interval < 1 ? 1 : 0))]
    if (config.fullscreenOnly) parts.unshift(strings.t("fold.fullscreen"))
    return parts.join(" · ")
  }

  // ------------------------------------------------------------ game mode text

  function gb(mb) { return strings.t("gm.gb").arg(Commons.I18n.formatNumber(mb / 1024, 1)) }
  function size(mb) { return mb < 1024 ? strings.t("gm.mb").arg(Commons.I18n.formatNumber(mb, 0)) : gb(mb) }

  readonly property string gmFreeLine: gm && gm.mem ? strings.t("gm.ramFree").arg(gb(gm.mem.availableMB)).arg(gb(gm.mem.totalMB)) : ""
  readonly property string gmVramLine: gm && gm.gpu
    ? strings.t("gm.vramFree").arg(size(Math.max(0, gm.gpu.totalMB - gm.gpu.usedMB))).arg(size(gm.gpu.totalMB)) : ""

  // One line for RAM, one for VRAM (when there's a GPU to read).
  readonly property string gmStateLine: {
    if (!gm || !gm.status) return strings.t("gm.reading")
    if (gm.pending === "on") return strings.t("gm.freeing")
    if (gm.pending === "off") return strings.t("gm.restoring")
    var ram = gmFreeLine, vram = gmVramLine
    if (gm.gameOn) {
      if (gm.status.freedMB) ram += " · " + strings.t("gm.freed").arg(gb(gm.status.freedMB))
      if (vram && gm.status.freedVramMB) vram += " · " + strings.t("gm.freed").arg(size(gm.status.freedVramMB))
      var since = gm.status.since ? new Date(gm.status.since * 1000) : null
      return (since ? strings.t("gm.since").arg(since.toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm")) + "\n" : "")
        + ram + (vram ? "\n" + vram : "")
    }
    if (gm.tickedCount === 0) return ram + (vram ? "\n" + vram : "") + "\n" + strings.t("gm.tickHint")
    return ram + (gm.tickedMB > 0 ? " · " + strings.t("gm.frees").arg(gb(gm.tickedMB)) : "")
      + (vram ? "\n" + vram + (gm.tickedVram > 0 ? " · " + strings.t("gm.frees").arg(size(gm.tickedVram)) : "") : "")
  }

  // Apps (and the indexer) as one flat list, Docker projects in their own
  // folder, each biggest RAM first. Both keep indexes into gmItems so rows and
  // the cursor stay stable.
  readonly property var gmLoose: {
    var idx = []
    for (var i = 0; i < gmItems.length; i++) if (gmItems[i].kind !== "docker") idx.push(i)
    return idx.sort(function(a, b) { return gmItems[b].mb - gmItems[a].mb || a - b })
  }
  readonly property var gmGroups: {
    var idx = []
    for (var i = 0; i < gmItems.length; i++) if (gmItems[i].kind === "docker") idx.push(i)
    idx.sort(function(a, b) { return gmItems[b].mb - gmItems[a].mb || a - b })
    return idx.length ? [{ id: "docker", indexes: idx }] : []
  }
  readonly property var gmAll: ({ id: "all", indexes: gmItems.map(function(_, i) { return i }) })

  // Folded sections, by id. Unset means the default: open, except Docker
  // once it has more than four projects.
  property var gmFolds: ({})
  function gmGroupOpen(group) {
    var v = gmFolds[group.id]
    return v !== undefined ? v : !(group.id === "docker" && group.indexes.length > 4)
  }
  function toggleGmFold(id) {
    var group = gmGroups.find(function(g) { return g.id === id })
    if (!group) return
    var next = Object.assign({}, gmFolds)
    next[id] = !gmGroupOpen(group)
    gmFolds = next
  }

  function gmGroupItems(group) { return group.indexes.map(function(i) { return gmItems[i] }) }
  // On when every item in the section is ticked (or paused, while game mode is on).
  function gmGroupOn(group) {
    if (!gm) return false
    return gmGroupItems(group).every(function(i) { return gameOn ? gm.paused(i) : gm.ticked(i) })
  }
  function toggleGmGroup(id) {
    var group = id === "all" ? gmAll : gmGroups.find(function(g) { return g.id === id })
    if (group && gm) gm.setItems(gmGroupItems(group), !gmGroupOn(group))
  }
  function gmGroupSummary(group) {
    if (!gm) return ""
    var list = gmGroupItems(group)
    var on = list.filter(function(i) { return gameOn ? gm.paused(i) : gm.ticked(i) }).length
    var mb = list.reduce(function(sum, i) { return sum + i.mb }, 0)
    var line = strings.t(gameOn ? "gm.groupPaused" : "gm.groupTicked")
      .arg(Commons.I18n.formatNumber(on)).arg(Commons.I18n.formatNumber(list.length))
    return mb > 0 ? line + " · " + gb(mb) : line
  }

  function gmRowDescription(item) {
    var p = gm ? gm.itemPending[item.key] : undefined
    if (p === "pause") return strings.t(item.kind === "app" ? "gm.closing" : "gm.stopping")
    if (p === "resume") return strings.t(item.kind === "app" ? "gm.reopening" : "gm.starting")
    return item.detail
  }

  readonly property string barTooltip: {
    var lines = [hudOn ? strings.t("bar.tooltipOn") : strings.t("bar.tooltip")]
    if (gm && gm.status) {
      if (gm.working) lines.push(strings.t(gm.gameOn ? "gm.barWorking" : "gm.restoring"))
      else {
        lines.push(strings.t(gm.gameOn ? "gm.barOn" : "gm.barOff"))
        if (gmFreeLine) lines.push(gmFreeLine)
        if (gmVramLine) lines.push(gmVramLine)
      }
      lines.push(strings.t(gm.gameOn ? "gm.middleOff" : "gm.middleOn"))
    }
    return lines.join("\n")
  }

  function positionAt(rowId, col) {
    var row = positionGrid[rowId === "pos-top" ? 0 : 1]
    return row[Math.max(0, Math.min(row.length - 1, col))]
  }

  function setValue(key, value) { if (service) service.setValue(key, value) }

  property bool copied: false
  function copyLaunchOption() {
    if (!service) return
    service.copyLaunchOption()
    copied = true
    copiedTimer.restart()
  }

  Timer {
    id: copiedTimer
    interval: 1600
    onTriggered: root.copied = false
  }

  // ------------------------------------------------------------ cursor
  //
  // One list of rows, top to bottom; each row has `count` targets side by
  // side. j/k walks rows, h/l walks targets (or nudges a slider), Enter
  // activates. Hover moves the same cursor, so mouse and keys share one
  // highlight.

  property string cursorRow: "enabled"
  property int cursorCol: 0
  property bool cursorActive: false

  readonly property var navRows: {
    var list = [{ id: "page", count: 2 }]
    if (page === "gamemode") {
      list.push({ id: "gm-power", count: 1 }, { id: "gm-auto", count: 1 })
      if (gmItems.length) list.push({ id: "gm-all", count: 1 })
      for (var l = 0; l < gmLoose.length; l++) list.push({ id: "gm-item-" + gmLoose[l], count: 1 })
      for (var g = 0; g < gmGroups.length; g++) {
        list.push({ id: "gm-group-" + gmGroups[g].id, count: 2 })
        if (gmGroupOpen(gmGroups[g]))
          for (var n = 0; n < gmGroups[g].indexes.length; n++) list.push({ id: "gm-item-" + gmGroups[g].indexes[n], count: 1 })
      }
      return list
    }
    list.push({ id: "enabled", count: 1 }, { id: "fold-position", count: 1 })
    if (positionOpen) list.push({ id: "pos-top", count: 3 }, { id: "pos-bottom", count: 3 })
    list.push({ id: "fold-stats", count: 1 })
    if (statsOpen) {
      for (var i = 0; i < Metrics.GROUPS.length; i++)
        list.push({ id: "metrics-" + Metrics.GROUPS[i].id, count: Metrics.GROUPS[i].metrics.length })
    }
    list.push({ id: "fold-look", count: 1 })
    if (lookOpen) {
      list.push({ id: "layout", count: Metrics.LAYOUTS.length })
      list.push({ id: "scale", count: 1, slider: true })
      list.push({ id: "opacity", count: 1, slider: true })
    }
    list.push({ id: "fold-behavior", count: 1 })
    if (behaviorOpen) {
      list.push({ id: "fullscreen", count: 1 })
      list.push({ id: "interval", count: Metrics.INTERVALS.length })
      if (gpuChoices.length > 2) list.push({ id: "gpu", count: gpuChoices.length })
      if (screenChoices.length > 2) list.push({ id: "screen", count: screenChoices.length })
    }
    list.push({ id: "fold-fps", count: 1 })
    if (fpsOpen) {
      if (!mango.installed) list.push({ id: "install", count: 1 })
      list.push({ id: "fps", count: 1 })
      if (mango.managed) list.push({ id: "graph", count: 1 })
      list.push({ id: "copy", count: 1 })
    }
    return list
  }

  function rowIndex(id) {
    for (var i = 0; i < navRows.length; i++) if (navRows[i].id === id) return i
    return -1
  }

  function cursorOn(id, col) {
    return cursorActive && cursorRow === id && cursorCol === (col || 0)
  }

  function cursorIndexFor(id) {
    return cursorActive && cursorRow === id ? cursorCol : -1
  }

  // Set when the mouse moved the cursor. Hover never scrolls the panel:
  // scrolling would slide a different row under the pointer.
  property bool cursorByMouse: false

  function point(id, col) {
    cursorByMouse = true
    cursorActive = true
    cursorRow = id
    cursorCol = col || 0
  }

  function moveCursor(dx, dy) {
    var rows = navRows
    var r = rowIndex(cursorRow)
    if (r < 0) { cursorRow = rows[0].id; cursorCol = 0; return }
    if (dy !== 0) {
      var next = Math.max(0, Math.min(rows.length - 1, r + dy))
      cursorRow = rows[next].id
      cursorCol = Math.min(cursorCol, rows[next].count - 1)
      return
    }
    var row = rows[r]
    if (row.slider) {
      if (row.id === "scale") setValue("scale", config.scale + dx * 0.05)
      else setValue("opacity", config.opacity + dx * 0.05)
      return
    }
    cursorCol = Math.max(0, Math.min(row.count - 1, cursorCol + dx))
  }

  function activateCursor() {
    if (!service) return
    var id = cursorRow
    var col = cursorCol
    if (id === "page") setPage(col === 0 ? "stats" : "gamemode")
    else if (id === "gm-power") toggleGameMode()
    else if (id === "gm-auto") { if (gm) gm.setAuto(!gm.autoEnabled) }
    else if (id === "gm-all") toggleGmGroup("all")
    else if (id.indexOf("gm-group-") === 0) { if (col === 0) toggleGmFold(id.slice(9)); else toggleGmGroup(id.slice(9)) }
    else if (id.indexOf("gm-item-") === 0) { if (gm) gm.clickItem(gmItems[Number(id.slice(8))]) }
    else if (id === "enabled") service.setEnabled(!config.enabled)
    else if (id.indexOf("fold-") === 0) toggleFold(id)
    else if (id === "pos-top" || id === "pos-bottom") setValue("position", positionAt(id, col))
    else if (id.indexOf("metrics-") === 0) {
      for (var i = 0; i < Metrics.GROUPS.length; i++)
        if ("metrics-" + Metrics.GROUPS[i].id === id) service.toggleMetric(Metrics.GROUPS[i].metrics[col])
    }
    else if (id === "layout") setValue("layout", Metrics.LAYOUTS[col])
    else if (id === "fullscreen") setValue("fullscreenOnly", !config.fullscreenOnly)
    else if (id === "interval") setValue("interval", Metrics.INTERVALS[col])
    else if (id === "gpu" && gpuChoices[col]) setValue("gpu", gpuChoices[col].value)
    else if (id === "screen" && screenChoices[col]) setValue("screen", screenChoices[col].value)
    else if (id === "install") service.installMango()
    else if (id === "fps") service.setFps(!mango.managed)
    else if (id === "graph") service.setFpsGraph(!mango.graph)
    else if (id === "copy") copyLaunchOption()
  }

  // A row can vanish under the cursor (MangoHud got installed, a GPU went
  // away): land on the FPS switch, which is always there.
  function clampCursor() {
    var r = rowIndex(cursorRow)
    if (r < 0) {
      cursorRow = rowIndex("fps") >= 0 ? "fps" : navRows[navRows.length > 1 ? 1 : 0].id
      cursorCol = 0
      return
    }
    cursorCol = Math.max(0, Math.min(navRows[r].count - 1, cursorCol))
  }

  onNavRowsChanged: clampCursor()

  // Keep the keyboard target inside the viewport when the panel scrolls.
  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (cursorByMouse || !item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var margin = 6
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  // ------------------------------------------------------------ bar icon

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    active: root.hudOn || root.gameOn
    activeColor: Commons.Color.accent
    tooltipText: root.barTooltip
    // Left opens the panel; right flips the HUD; middle flips game mode.
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.service) root.service.setEnabled(!root.config.enabled)
      } else if (b === Qt.MiddleButton) {
        root.toggleGameMode()
      } else if (b === Qt.LeftButton) {
        root.toggle()
      }
    }
  }

  // ------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(660))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        root.cursorByMouse = false
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(10)

          // ---------- Pages ----------
          ButtonGroup {
            id: pageTabs
            options: [{ value: "stats", label: strings.t("page.stats") }, { value: "gamemode", label: strings.t("page.gamemode") }]
            value: root.page
            focusable: false
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            cursorIndex: root.cursorIndexFor("page")
            onChanged: function(v) { root.setPage(v) }
            onHovered: function(index, h) { if (h) root.point("page", index) }
          }

          Column {
            id: statsPage
            visible: root.page === "stats"
            width: parent.width
            spacing: Style.space(10)

            // ---------- Hero: icon · title/status · switch ----------
            Item {
              width: parent.width
              implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroSwitch.implicitHeight)

              Text {
                id: heroIcon
                textFormat: Text.PlainText
                text: ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                id: heroLabels
                anchors.left: heroIcon.right
                anchors.leftMargin: Style.space(14)
                anchors.right: heroSwitch.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("panel.title")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.statusText
                  color: root.service && root.service.statsFailed && root.service.streaming ? Commons.Color.urgent : root.dimFg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              ToggleSwitch {
                id: heroSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.enabled
                busy: !root.service || !root.service.configReady
                hasCursor: root.cursorOn("enabled")
                foreground: root.fg
                onToggled: if (root.service) root.service.setEnabled(!root.config.enabled)
                onHovered: function(h) { if (h) root.point("enabled", 0) }
              }
            }

            // ---------- Position ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-position"
                text: strings.t("section.position")
                hint: strings.t("position.hint")
                summary: root.positionSummary
                open: root.positionOpen
              }

              ScreenPicker {
                width: parent.width
                visible: root.positionOpen
              }
            }

            // ---------- Stats ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-stats"
                text: strings.t("section.stats")
                summary: root.statsSummary
                open: root.statsOpen
              }

              Repeater {
                model: Metrics.GROUPS

                MetricGroupRow {
                  required property var modelData
                  visible: root.statsOpen
                  width: panelColumn.width
                  group: modelData
                }
              }
            }

            // ---------- Look ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-look"
                text: strings.t("section.look")
                summary: root.lookSummary
                open: root.lookOpen
              }

              LabeledRow {
                width: parent.width
                visible: root.lookOpen
                label: strings.t("look.layout")

                ButtonGroup {
                  options: root.layoutOptions
                  value: root.config.layout
                  focusable: false
                  cursorIndex: root.cursorIndexFor("layout")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.spacing.xs
                  onChanged: function(v) { root.setValue("layout", v) }
                  onHovered: function(i, h) { if (h) root.point("layout", i) }
                }
              }

              SliderRow {
                width: parent.width
                visible: root.lookOpen
                rowId: "scale"
                label: strings.t("look.size")
                value: root.config.scale
                minimum: Metrics.SCALE_MIN
                maximum: Metrics.SCALE_MAX
                onCommit: function(v) { root.setValue("scale", v) }
              }

              SliderRow {
                width: parent.width
                visible: root.lookOpen
                rowId: "opacity"
                label: strings.t("look.backdrop")
                value: root.config.opacity
                minimum: 0
                maximum: 1
                onCommit: function(v) { root.setValue("opacity", v) }
              }
            }

            // ---------- Behavior ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-behavior"
                text: strings.t("section.behavior")
                summary: root.behaviorSummary
                open: root.behaviorOpen
              }

              SmallToggle {
                id: fullscreenToggle
                width: parent.width
                visible: root.behaviorOpen
                label: strings.t("behavior.fullscreenOnly")
                description: strings.t("behavior.fullscreenOnlyHint")
                checked: root.config.fullscreenOnly
                hasCursor: root.cursorOn("fullscreen")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(fullscreenToggle)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.setValue("fullscreenOnly", !root.config.fullscreenOnly)
                onHovered: function(h) { if (h) root.point("fullscreen", 0) }
              }

              LabeledRow {
                width: parent.width
                visible: root.behaviorOpen
                label: strings.t("behavior.interval")

                ButtonGroup {
                  options: root.intervalOptions
                  value: String(root.config.interval)
                  focusable: false
                  cursorIndex: root.cursorIndexFor("interval")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.spacing.xs
                  onChanged: function(v) { root.setValue("interval", Number(v)) }
                  onHovered: function(i, h) { if (h) root.point("interval", i) }
                }
              }

              LabeledRow {
                width: parent.width
                visible: root.behaviorOpen && root.gpuChoices.length > 2
                label: strings.t("behavior.gpu")

                ButtonGroup {
                  options: root.gpuChoices
                  value: root.config.gpu
                  focusable: false
                  cursorIndex: root.cursorIndexFor("gpu")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.spacing.xs
                  onChanged: function(v) { root.setValue("gpu", v) }
                  onHovered: function(i, h) { if (h) root.point("gpu", i) }
                }
              }

              LabeledRow {
                width: parent.width
                visible: root.behaviorOpen && root.screenChoices.length > 2
                label: strings.t("behavior.screen")

                ButtonGroup {
                  options: root.screenChoices
                  value: root.config.screen
                  focusable: false
                  cursorIndex: root.cursorIndexFor("screen")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.spacing.xs
                  onChanged: function(v) { root.setValue("screen", v) }
                  onHovered: function(i, h) { if (h) root.point("screen", i) }
                }
              }
            }

            // ---------- FPS through MangoHud ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-fps"
                text: strings.t("section.fps")
                summary: root.fpsSummary
                open: root.fpsOpen
              }

              Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.fpsOpen

              Item {
                width: parent.width
                visible: !root.mango.installed
                implicitHeight: Math.max(missingText.implicitHeight, installButton.implicitHeight)

                Text {
                  id: missingText
                  textFormat: Text.PlainText
                  text: strings.t("fps.missing")
                  color: root.dimFg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  anchors.left: parent.left
                  anchors.right: installButton.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                }

                Button {
                  id: installButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("fps.install")
                  iconText: ""
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  hasCursor: root.cursorOn("install")
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(installButton)
                  onClicked: if (root.service) root.service.installMango()
                  onHovered: function(h) { if (h) root.point("install", 0) }
                }
              }

              SmallToggle {
                id: fpsToggle
                width: parent.width
                label: strings.t("fps.show")
                description: strings.t("fps.showHint")
                checked: root.mango.managed
                hasCursor: root.cursorOn("fps")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(fpsToggle)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.setFps(!root.mango.managed)
                onHovered: function(h) { if (h) root.point("fps", 0) }
              }

              SmallToggle {
                id: graphToggle
                width: parent.width
                visible: root.mango.managed
                label: strings.t("fps.graph")
                description: strings.t("fps.graphHint")
                checked: root.mango.graph
                hasCursor: root.cursorOn("graph")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(graphToggle)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.setFpsGraph(!root.mango.graph)
                onHovered: function(h) { if (h) root.point("graph", 0) }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: strings.t("fps.launchHint")
                color: root.dimFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Button {
                id: copyButton
                text: root.copied ? strings.t("fps.copied") : strings.t("fps.copy")
                iconText: root.copied ? "" : ""
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                hasCursor: root.cursorOn("copy")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(copyButton)
                onClicked: root.copyLaunchOption()
                onHovered: function(h) { if (h) root.point("copy", 0) }
              }

              Text {
                width: parent.width
                visible: !!root.service && root.service.mangoFailed
                textFormat: Text.PlainText
                text: strings.t("fps.failed")
                color: Commons.Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                wrapMode: Text.WordWrap
              }
              }
            }

          }

          // ---------- Game mode ----------
          Column {
            id: gamePage
            visible: root.page === "gamemode"
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(gmGlyph.implicitHeight, gmText.implicitHeight, gmPower.implicitHeight)

              Text {
                id: gmGlyph
                textFormat: Text.PlainText
                text: ""
                color: root.gameOn ? Commons.Color.accent : root.fg
                opacity: root.gameOn ? 1 : 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                id: gmText
                anchors.left: gmGlyph.right
                anchors.leftMargin: Style.space(14)
                anchors.right: gmPower.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: strings.t(root.gameOn ? "gm.titleOn" : "gm.titleOff")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.gmStateLine
                  color: root.dimFg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width
                }
              }

              Button {
                id: gmPower
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t(root.gm && root.gm.working ? "gm.wait" : root.gameOn ? "gm.restoreAll" : "gm.pauseTicked")
                enabled: !!root.gm && !root.gm.working && !!root.gm.status && (root.gameOn || root.gm.tickedCount > 0)
                selected: root.gameOn
                bordered: true
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                hasCursor: root.cursorOn("gm-power")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gmPower)
                onClicked: root.toggleGameMode()
                onHovered: function(h) { if (h) root.point("gm-power", 0) }
              }
            }

            SmallToggle {
              id: gmAuto
              width: parent.width
              label: strings.t("gm.auto")
              description: root.gm && root.gm.autoEnabled && root.gm.game !== ""
                ? strings.t("gm.autoPlaying").arg(root.gm.game) : strings.t("gm.autoHint")
              checked: !!root.gm && root.gm.autoEnabled
              hasCursor: root.cursorOn("gm-auto")
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gmAuto)
              foreground: root.fg
              onClicked: if (root.gm) root.gm.setAuto(!root.gm.autoEnabled)
              onHovered: function(h) { if (h) root.point("gm-auto", 0) }
            }

            PanelSeparator { foreground: root.fg }

            Text {
              visible: root.gmItems.length > 0
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t(root.gameOn ? "gm.headerOn" : "gm.headerOff")
              color: root.dimFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            SmallToggle {
              id: gmAllRow
              visible: root.gmItems.length > 0
              width: gamePage.width
              label: strings.t("gm.all")
              description: root.gmGroupSummary(root.gmAll)
              checked: root.gmGroupOn(root.gmAll)
              hasCursor: root.cursorOn("gm-all")
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gmAllRow)
              foreground: root.fg
              onClicked: root.toggleGmGroup("all")
              onHovered: function(h) { if (h) root.point("gm-all", 0) }
            }

            // Indexed rather than bound to the arrays, so a reading doesn't
            // rebuild the rows under the pointer.
            Repeater {
              model: root.gmLoose.length

              delegate: GmRow {
                required property int index
                itemIndex: root.gmLoose[index]
              }
            }

            // Docker projects, in a folder.
            Repeater {
              model: root.gmGroups.length

              delegate: Column {
                id: gmSection
                required property int index
                readonly property var group: root.gmGroups[index] || ({ id: "", indexes: [] })
                readonly property bool open: root.gmGroupOpen(group)
                width: gamePage.width
                spacing: Style.space(6)

                GroupTitle {
                  rowId: "gm-group-" + gmSection.group.id
                  text: strings.t("gm.group." + (gmSection.group.id || "docker"))
                  summary: root.gmGroupSummary(gmSection.group)
                  open: gmSection.open
                  checked: root.gmGroupOn(gmSection.group)
                }

                Repeater {
                  model: gmSection.open ? gmSection.group.indexes.length : 0

                  delegate: GmRow {
                    required property int index
                    itemIndex: gmSection.group.indexes[index]
                  }
                }
              }
            }

            Text {
              visible: !!root.gm && !!root.gm.status && root.gmItems.length === 0
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("gm.empty")
              color: root.dimFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSeparator { foreground: root.fg }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: strings.t("gm.footer")
              color: root.dimFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ pieces

  // A section header that folds its section: click or Enter flips it. Folded,
  // it shows a one-line summary of the current values.
  component FoldTitle: CursorSurface {
    id: fold
    property string rowId: ""
    property string text: ""
    property string summary: ""
    property string hint: ""
    property bool open: false
    width: parent ? parent.width : 0
    implicitHeight: Math.max(foldHeader.implicitHeight, foldChevron.implicitHeight) + Style.spacing.xs * 2
    hasCursor: root.cursorOn(rowId)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(fold)
    foreground: root.fg

    PanelSectionHeader {
      id: foldHeader
      text: fold.text
      foreground: root.fg
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      visible: text !== ""
      textFormat: Text.PlainText
      text: fold.open ? fold.hint : fold.summary
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignRight
      anchors.left: foldHeader.right
      anchors.leftMargin: Style.space(10)
      anchors.right: foldChevron.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: foldChevron
      textFormat: Text.PlainText
      text: fold.open ? "\uf077" : "\uf078"
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleFold(fold.rowId)
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.point(fold.rowId, 0)
    }
  }

  // One Game mode item: its switch ticks it, or pauses it while game mode is on.
  component GmRow: SmallToggle {
    id: gmRow
    property int itemIndex: -1
    readonly property var item: root.gmItems[itemIndex] || ({ key: "", kind: "app", label: "", detail: "", selected: false, paused: false })
    readonly property string rowId: "gm-item-" + itemIndex
    width: parent ? parent.width : 0
    label: item.label
    description: root.gmRowDescription(item)
    checked: root.gm ? (root.gameOn ? root.gm.paused(item) : root.gm.ticked(item)) : false
    hasCursor: root.cursorOn(rowId)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gmRow)
    foreground: root.fg
    onClicked: if (root.gm) root.gm.clickItem(item)
    onHovered: function(h) { if (h) root.point(rowId, 0) }
  }

  // A Game mode folder's title, drawn like the other rows: the box folds it
  // (target 0), the switch ticks or pauses everything inside (target 1).
  component GroupTitle: CursorSurface {
    id: groupTitle
    property string rowId: ""
    property string text: ""
    property string summary: ""
    property bool open: true
    property bool checked: false
    width: parent ? parent.width : 0
    bordered: true
    hasCursor: root.cursorOn(rowId, 0)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(groupTitle)
    foreground: root.fg
    implicitHeight: Math.max(groupSwitch.implicitHeight, groupText.implicitHeight) + Style.spacing.sm * 2

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleGmFold(groupTitle.rowId.slice(9))
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.point(groupTitle.rowId, 0)
    }

    Text {
      id: groupChevron
      textFormat: Text.PlainText
      text: groupTitle.open ? "\uf078" : "\uf054"
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      width: Style.space(14)
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm + Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: groupText
      anchors.left: groupChevron.right
      anchors.leftMargin: Style.space(4)
      anchors.right: groupSwitch.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: groupTitle.text
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        visible: groupTitle.summary !== ""
        text: groupTitle.summary
        color: root.dimFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }
    }

    ToggleSwitch {
      id: groupSwitch
      checked: groupTitle.checked
      hasCursor: root.cursorOn(groupTitle.rowId, 1)
      trackHeight: Style.space(16)
      foreground: root.fg
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm + Style.space(2) - (cursorRing ? cursorPad : 0)
      anchors.verticalCenter: parent.verticalCenter
      onToggled: root.toggleGmGroup(groupTitle.rowId.slice(9))
      onHovered: function(h) { if (h) root.point(groupTitle.rowId, 1) }
    }
  }


  // A tighter version of the kit's Toggle row: smaller title, smaller switch.
  component SmallToggle: CursorSurface {
    id: small
    property string label: ""
    property string description: ""
    property bool checked: false
    property string fontFamily: root.fontFamily
    signal clicked()
    signal hovered(bool isHovered)

    bordered: true
    implicitHeight: Math.max(smallSwitch.implicitHeight, smallText.implicitHeight) + Style.spacing.sm * 2

    Column {
      id: smallText
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm + Style.space(2)
      anchors.right: smallSwitch.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: small.label
        color: small.foreground
        font.family: small.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        visible: small.description !== ""
        text: small.description
        color: root.dimFg
        font.family: small.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }
    }

    ToggleSwitch {
      id: smallSwitch
      checked: small.checked
      interactive: false
      cursorRing: false
      trackHeight: Style.space(16)
      foreground: small.foreground
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm + Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: small.clicked()
    }

    HoverHandler {
      onHoveredChanged: small.hovered(hovered)
    }
  }

  // A caption on the left, controls after it.
  component LabeledRow: Item {
    id: labeled
    property string label: ""
    default property alias content: holder.data
    implicitHeight: Math.max(labeledText.implicitHeight, holder.childrenRect.height)

    Text {
      id: labeledText
      textFormat: Text.PlainText
      text: labeled.label
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      width: root.labelWidth - Style.space(6)
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Item {
      id: holder
      anchors.left: labeledText.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: childrenRect.height
    }
  }

  component SliderRow: CursorSurface {
    id: sliderRow
    property string rowId: ""
    property string label: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 1
    signal commit(real value)

    implicitHeight: Math.max(sliderLabel.implicitHeight, slider.implicitHeight) + Style.spacing.controlGap
    hasCursor: root.cursorOn(rowId)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sliderRow)
    foreground: root.fg
    outline: true

    Text {
      id: sliderLabel
      textFormat: Text.PlainText
      text: sliderRow.label
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      width: root.labelWidth - Style.space(6)
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    PanelSlider {
      id: slider
      bar: root.bar
      anchors.left: sliderLabel.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: sliderValue.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: 0.05
      value: sliderRow.value
      onMoved: function(v) { sliderRow.commit(v) }
      onReleased: function(v) { sliderRow.commit(v) }
    }

    Text {
      id: sliderValue
      textFormat: Text.PlainText
      text: Commons.I18n.formatNumber(Math.round((slider.dragging ? slider.liveValue : sliderRow.value) * 100)) + "%"
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      width: Math.max(implicitWidth, Math.ceil(widest.advanceWidth))
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter

      TextMetrics {
        id: widest
        font: sliderValue.font
        text: Commons.I18n.formatNumber(160) + "%"
      }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.point(sliderRow.rowId, 0)
    }
  }

  component MetricGroupRow: Item {
    id: groupRow
    property var group: null
    readonly property string rowId: group ? "metrics-" + group.id : ""
    implicitHeight: Math.max(groupLabel.implicitHeight, chips.implicitHeight)

    Text {
      id: groupLabel
      textFormat: Text.PlainText
      text: groupRow.group ? strings.t("group." + groupRow.group.id) : ""
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      width: root.labelWidth - Style.space(6)
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Row {
      id: chips
      anchors.left: groupLabel.right
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      Repeater {
        model: groupRow.group ? groupRow.group.metrics : []

        Button {
          id: chip
          required property string modelData
          required property int index
          text: strings.t("metric." + modelData)
          selected: root.config.metrics.indexOf(modelData) !== -1
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.sm
          hasCursor: root.cursorOn(groupRow.rowId, index)
          onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(chip)
          onClicked: if (root.service) root.service.toggleMetric(modelData)
          onHovered: function(h) { if (h) root.point(groupRow.rowId, chip.index) }
        }
      }
    }
  }

  // A small screen: click a spot to move the HUD there. The live HUD sits
  // in its current spot; the spot under the cursor shows a ghost outline.
  component ScreenPicker: Item {
    id: picker
    implicitHeight: Math.round(width / root.screenRatio)
    readonly property int inset: Style.space(8)
    readonly property bool hasPreview: preview.hasRows
    readonly property real cardWidth: hasPreview ? preview.width : Style.space(92)
    readonly property real cardHeight: hasPreview ? preview.height : Style.space(54)
    // From the mouse, the ghost shows only while the pointer is on the picker.
    readonly property string hotPosition: root.cursorActive && (!root.cursorByMouse || pickerHover.hovered)
      && (root.cursorRow === "pos-top" || root.cursorRow === "pos-bottom")
      ? root.positionAt(root.cursorRow, root.cursorCol) : ""

    onHotPositionChanged: if (hotPosition !== "") root.ensureCursorVisible(picker)

    HoverHandler { id: pickerHover }

    function slotX(position, w) {
      var a = Metrics.anchors(position)
      if (a.left) return inset
      if (a.right) return width - w - inset
      return Math.round((width - w) / 2)
    }

    function slotY(position, h) {
      return Metrics.anchors(position).top ? inset : height - h - inset
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.05)
      border.width: 1
      border.color: Util.alpha(root.fg, 0.22)
    }

    // Placeholder for the HUD until the first sample arrives.
    Rectangle {
      visible: !picker.hasPreview
      width: picker.cardWidth
      height: picker.cardHeight
      x: picker.slotX(root.config.position, width)
      y: picker.slotY(root.config.position, height)
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.12)
    }

    HudCard {
      id: preview
      visible: hasRows
      width: implicitWidth
      height: implicitHeight
      rows: root.service ? root.service.hudRows : []
      layout: root.config.layout
      scaleFactor: root.config.scale * 0.62
      backdrop: root.config.opacity
      x: picker.slotX(root.config.position, width)
      y: picker.slotY(root.config.position, height)
      Behavior on x { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    }

    Rectangle {
      visible: picker.hotPosition !== "" && picker.hotPosition !== root.config.position
      width: picker.cardWidth
      height: picker.cardHeight
      x: picker.slotX(picker.hotPosition, width)
      y: picker.slotY(picker.hotPosition, height)
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.06)
      border.width: 1
      border.color: Util.alpha(root.fg, 0.6)
    }

    Grid {
      anchors.fill: parent
      columns: 3

      Repeater {
        model: 6

        MouseArea {
          required property int index
          readonly property string rowId: index < 3 ? "pos-top" : "pos-bottom"
          width: picker.width / 3
          height: picker.height / 2
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (containsMouse) root.point(rowId, index % 3)
          onClicked: root.setValue("position", root.positionAt(rowId, index % 3))
        }
      }
    }
  }
}
