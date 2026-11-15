import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "Metrics.js" as Metrics

// One HUD on one output. Overlay layer so it stays above fullscreen games,
// no keyboard focus and an empty input region so every click goes through.
PanelWindow {
  id: window

  property var service: null

  readonly property var config: service ? service.config : Metrics.sanitize(null)
  readonly property bool fullscreen: service ? service.fullscreenOn(screen) : false
  readonly property var edges: Metrics.anchors(config.position)
  // Over a game, hug the corner; on the desktop, line up with window gaps
  // and stay clear of the bar.
  readonly property int edgeGap: fullscreen ? Style.space(10) : Math.max(Style.gapsOut, Style.space(6))

  visible: card.hasRows && (!config.fullscreenOnly || fullscreen)
  color: "transparent"

  WlrLayershell.namespace: "gamer-center-hud"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: fullscreen ? ExclusionMode.Ignore : ExclusionMode.Normal
  exclusiveZone: 0

  anchors {
    top: window.edges.top
    bottom: window.edges.bottom
    left: window.edges.left
    right: window.edges.right
  }

  margins {
    top: window.edges.top ? window.edgeGap : 0
    bottom: window.edges.bottom ? window.edgeGap : 0
    left: window.edges.left ? window.edgeGap : 0
    right: window.edges.right ? window.edgeGap : 0
  }

  implicitWidth: Math.max(1, Math.ceil(card.implicitWidth))
  implicitHeight: Math.max(1, Math.ceil(card.implicitHeight))

  mask: Region {}

  HudCard {
    id: card
    anchors.fill: parent
    rows: window.service ? window.service.hudRows : []
    layout: window.config.layout
    scaleFactor: window.config.scale
    backdrop: window.config.opacity
  }
}
