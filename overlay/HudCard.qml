import QtQuick
import qs.Commons
import qs.Commons as Commons

// The HUD itself: lines from Metrics.rows(), either stacked (label column +
// values) or run together on one line. Delegates are keyed by position, not
// rebuilt from scratch, so a new sample only changes text.
Item {
  id: card

  property var rows: []
  property string layout: "stack"
  property real scaleFactor: 1
  property real backdrop: 0.7

  readonly property bool hasRows: !!rows && rows.length > 0
  readonly property bool singleLine: layout === "row"
  readonly property int fontSize: Math.max(8, Math.round(Style.font.subtitle * scaleFactor))
  readonly property int padX: Math.round(Style.space(10) * scaleFactor)
  readonly property int padY: Math.round(Style.space(7) * scaleFactor)
  readonly property int labelGap: Math.round(Style.space(12) * scaleFactor)
  readonly property int cellGap: Math.round(Style.space(9) * scaleFactor)
  readonly property int lineGap: Math.round(Style.space(2) * scaleFactor)
  readonly property color textColor: Commons.Color.popups.text
  readonly property color labelColor: Commons.Color.accent
  readonly property color hotColor: Commons.Color.urgent
  readonly property color shadeColor: Commons.Color.popups.background
  // With little or no backdrop, outline the text so it still reads over a
  // bright scene.
  readonly property bool outlined: backdrop < 0.35

  implicitWidth: (singleLine ? lineView.implicitWidth : stackView.implicitWidth) + padX * 2
  implicitHeight: (singleLine ? lineView.implicitHeight : stackView.implicitHeight) + padY * 2

  property bool shown: false
  opacity: shown ? 1 : 0
  scale: shown ? 1 : 0.97
  Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
  Behavior on scale {
    NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
  }
  Component.onCompleted: Qt.callLater(function() { card.shown = true })

  Rectangle {
    anchors.fill: parent
    visible: card.backdrop > 0
    radius: Style.cornerRadius
    color: Util.alpha(card.shadeColor, card.backdrop)
    border.width: 1
    border.color: Util.alpha(Commons.Color.popups.border, 0.35 * card.backdrop)
  }

  Grid {
    id: stackView
    visible: !card.singleLine
    x: card.padX
    y: card.padY
    columns: 2
    columnSpacing: card.labelGap
    rowSpacing: card.lineGap
    verticalItemAlignment: Grid.AlignVCenter

    Repeater {
      model: card.singleLine ? 0 : card.rows.length * 2

      delegate: Item {
        id: slot
        required property int index
        readonly property bool isLabel: index % 2 === 0
        readonly property var line: card.rows[Math.floor(index / 2)] || null

        width: isLabel ? slotLabel.implicitWidth : slotCells.implicitWidth
        height: Math.max(slotLabel.implicitHeight, slotCells.implicitHeight)

        HudText {
          id: slotLabel
          visible: slot.isLabel
          label: true
          text: slot.line ? slot.line.label : ""
          anchors.verticalCenter: parent.verticalCenter
        }

        HudCells {
          id: slotCells
          visible: !slot.isLabel
          line: slot.isLabel ? null : slot.line
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  Row {
    id: lineView
    visible: card.singleLine
    x: card.padX
    y: card.padY
    spacing: card.cellGap

    Repeater {
      model: card.singleLine ? card.rows.length : 0

      delegate: Row {
        id: segment
        required property int index
        readonly property var line: card.rows[index] || null
        spacing: card.cellGap

        Item {
          visible: segment.index > 0
          width: Math.max(1, Math.round(card.cellGap / 2))
          height: segmentLabel.implicitHeight

          Rectangle {
            anchors.centerIn: parent
            width: 1
            height: Math.round(card.fontSize * 0.9)
            color: Util.alpha(card.textColor, 0.3)
          }
        }

        HudText {
          id: segmentLabel
          label: true
          text: segment.line ? segment.line.label : ""
        }

        HudCells {
          line: segment.line
        }
      }
    }
  }

  component HudText: Text {
    property bool label: false
    textFormat: Text.PlainText
    color: label ? card.labelColor : card.textColor
    font.family: Style.font.family
    font.pixelSize: card.fontSize
    font.bold: label
    font.features: ({ "tnum": 1 })
    style: card.outlined ? Text.Outline : Text.Normal
    styleColor: Util.alpha(card.shadeColor, 0.85)
  }

  // Each value is at least as wide as its widest likely text ("100%"), so
  // the HUD does not twitch as numbers change.
  component HudCells: Row {
    id: cells
    property var line: null
    spacing: card.cellGap

    Repeater {
      model: cells.line && cells.line.cells ? cells.line.cells.length : 0

      delegate: HudText {
        id: value
        required property int index
        readonly property var cellData: cells.line && cells.line.cells ? cells.line.cells[index] || null : null
        text: cellData ? cellData.text : ""
        color: cellData && cellData.hot ? card.hotColor : card.textColor
        horizontalAlignment: Text.AlignRight
        width: Math.max(implicitWidth, Math.ceil(fit.advanceWidth))

        TextMetrics {
          id: fit
          font: value.font
          text: value.cellData ? value.cellData.template : ""
        }
      }
    }
  }
}
