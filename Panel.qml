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
    var want = opened && service ? service : null
    if (want === heldService) return
    if (heldService) heldService.releasePreview()
    heldService = want
    if (want) want.retainPreview()
  }

  onBarChanged: resolveService()
  onServiceChanged: { syncPreview(); refreshGpuChoices() }
  Component.onCompleted: resolveService()
  Component.onDestruction: if (heldService) heldService.releasePreview()

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
    cursorRow = "enabled"
    cursorCol = 0
    cursorActive = false
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

  // Look and Behavior start folded; the choice lasts until the shell restarts.
  property bool lookOpen: false
  property bool behaviorOpen: false

  function toggleFold(id) {
    if (id === "fold-look") lookOpen = !lookOpen
    else if (id === "fold-behavior") behaviorOpen = !behaviorOpen
  }

  readonly property string lookSummary: {
    var layout = root.layoutOptions.filter(function(o) { return o.value === config.layout })
    return (layout.length ? layout[0].label : "") + " · " + Commons.I18n.formatNumber(Math.round(config.scale * 100)) + "%"
  }

  readonly property string behaviorSummary: {
    var parts = [strings.t("interval.seconds").arg(Commons.I18n.formatNumber(config.interval, config.interval < 1 ? 1 : 0))]
    if (config.fullscreenOnly) parts.unshift(strings.t("fold.fullscreen"))
    return parts.join(" · ")
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
    var list = [{ id: "enabled", count: 1 }, { id: "pos-top", count: 3 }, { id: "pos-bottom", count: 3 }]
    for (var i = 0; i < Metrics.GROUPS.length; i++)
      list.push({ id: "metrics-" + Metrics.GROUPS[i].id, count: Metrics.GROUPS[i].metrics.length })
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
    if (!mango.installed) list.push({ id: "install", count: 1 })
    list.push({ id: "fps", count: 1 })
    if (mango.managed) list.push({ id: "graph", count: 1 })
    list.push({ id: "copy", count: 1 })
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

  function point(id, col) {
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
    if (id === "enabled") service.setEnabled(!config.enabled)
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
      cursorRow = rowIndex("fps") >= 0 ? "fps" : navRows[0].id
      cursorCol = 0
      return
    }
    cursorCol = Math.max(0, Math.min(navRows[r].count - 1, cursorCol))
  }

  onNavRowsChanged: clampCursor()

  // Keep the keyboard target inside the viewport when the panel scrolls.
  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
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
    active: root.hudOn
    activeColor: Commons.Color.accent
    tooltipText: root.hudOn ? strings.t("bar.tooltipOn") : strings.t("bar.tooltip")
    // Left opens the panel; right flips the HUD without opening anything.
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.service) root.service.setEnabled(!root.config.enabled)
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

            SectionTitle {
              text: strings.t("section.position")
              hint: strings.t("position.hint")
            }

            ScreenPicker {
              width: parent.width
            }
          }

          // ---------- Stats ----------
          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.space(6)

            SectionTitle { text: strings.t("section.stats") }

            Repeater {
              model: Metrics.GROUPS

              MetricGroupRow {
                required property var modelData
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

            Toggle {
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

            SectionTitle { text: strings.t("section.fps") }

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

            Toggle {
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

            Toggle {
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

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ pieces

  component SectionTitle: Item {
    id: title
    property string text: ""
    property string hint: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(titleHeader.implicitHeight, titleHint.implicitHeight)

    PanelSectionHeader {
      id: titleHeader
      text: title.text
      foreground: root.fg
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: titleHint
      visible: title.hint !== ""
      textFormat: Text.PlainText
      text: title.hint
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // A section header that folds its section: click or Enter flips it. Folded,
  // it shows a one-line summary of the current values.
  component FoldTitle: CursorSurface {
    id: fold
    property string rowId: ""
    property string text: ""
    property string summary: ""
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
      visible: !fold.open
      textFormat: Text.PlainText
      text: fold.summary
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
    readonly property string hotPosition: root.cursorActive && (root.cursorRow === "pos-top" || root.cursorRow === "pos-bottom")
      ? root.positionAt(root.cursorRow, root.cursorCol) : ""

    onHotPositionChanged: if (hotPosition !== "") root.ensureCursorVisible(picker)

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
