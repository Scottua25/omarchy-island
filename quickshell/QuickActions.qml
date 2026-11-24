// Quick actions on hover: battery ring with the percentage and a few
// circles (screenshot, caffeine, do not disturb, lock). `compact` = battery
// and screenshot only, next to the player.
import QtQuick
import QtQuick.Shapes

Item {
  id: quick
  property bool compact: false
  property real pct: 0               // 0..1
  property bool charging: false
  property bool hasBattery: true
  property bool stayAwake: false
  property bool dnd: false
  property color accent: "white"
  property color textColor: "white"
  property color red: "red"
  property color green: "green"
  property string textFont: "sans"
  property string glyphFont: "monospace"
  signal screenshot()
  signal caffeine()
  signal dndToggle()
  signal lock()
  signal battery()
  signal expand()          // opens the full dashboard (click on the time)
  property string timeText: ""
  property string displayFont: "sans"
  // Full corner layouts start at the screen edge; center and compact layouts
  // retain the original order.
  property string cornerPosition: ""
  readonly property var controlOrder: compact ? ["battery", "shot"]
    : cornerPosition.endsWith("-left") ? ["clock", "caffeine", "dnd", "shot", "battery"]
    : cornerPosition.endsWith("-right") ? ["battery", "shot", "dnd", "caffeine", "clock"]
    : ["battery", "shot", "clock", "caffeine", "dnd"]
  property real spacing: 8
  implicitWidth: 44 + (hasBattery ? 44 : 0) + (compact ? 0 : clockBox.width + 88)
                 + (compact ? (hasBattery ? 1 : 0) : (hasBattery ? 4 : 3)) * spacing
  implicitHeight: 44
  width: implicitWidth
  height: implicitHeight

  function controlX(id) {
    let x = 0
    for (const item of controlOrder) {
      if (item === "battery" && !hasBattery) continue
      if (item === id) return x
      x += (item === "clock" ? clockBox.width : 44) + spacing
    }
    return x
  }

  // Battery ring
  Item {
    id: batt
    x: quick.controlX("battery")
    visible: quick.hasBattery
    width: 44; height: 44
    anchors.verticalCenter: parent.verticalCenter
    readonly property color ring: quick.charging ? quick.green : quick.pct <= 0.2 ? quick.red : quick.textColor
    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeColor: Qt.alpha(quick.textColor, 0.14)
        strokeWidth: 4
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc { centerX: 22; centerY: 22; radiusX: 19; radiusY: 19; startAngle: 0; sweepAngle: 360 }
      }
      ShapePath {
        strokeColor: batt.ring
        strokeWidth: 4
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc { centerX: 22; centerY: 22; radiusX: 19; radiusY: 19; startAngle: -90; sweepAngle: 360 * quick.pct }
      }
    }
    Text {
      anchors.centerIn: parent
      text: Math.round(quick.pct * 100)
      color: quick.textColor
      font.family: quick.textFont
      font.pixelSize: 13
      font.weight: Font.DemiBold
      font.features: { "tnum": 1 }
    }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
    TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: quick.battery() }
  }

  Repeater {
    model: quick.compact
      ? [{ glyph: "󰹑", act: "shot" }]
      : [{ glyph: "󰹑", act: "shot" }]
    Rectangle {
      required property var modelData
      x: quick.controlX(modelData.act)
      anchors.verticalCenter: parent.verticalCenter
      width: 44; height: 44; radius: 22
      color: modelData.on ? quick.accent : Qt.alpha(quick.textColor, hov.hovered ? 0.18 : 0.1)
      Behavior on color { ColorAnimation { duration: 120 } }
      scale: tap.pressed ? 0.9 : 1
      Behavior on scale { NumberAnimation { duration: 90 } }
      Text {
        anchors.centerIn: parent
        text: modelData.glyph
        color: modelData.on ? "white" : quick.textColor
        font.family: quick.glyphFont
        font.pixelSize: 17
      }
      HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
      TapHandler {
        id: tap
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: {
          if (modelData.act === "shot") quick.screenshot()
          else if (modelData.act === "caffeine") quick.caffeine()
          else if (modelData.act === "dnd") quick.dndToggle()
          else if (modelData.act === "lock") quick.lock()
          else if (modelData.act === "expand") quick.expand()
        }
      }
    }
  }

  // Where the time sits (for the island's clock flying over it) and whether
  // to hide it here: the island draws it, carrying it over from the pill.
  readonly property real clockX: clockBox.x + (clockBox.width - clockLabel.implicitWidth) / 2
  readonly property real clockW: clockLabel.implicitWidth
  property bool clockHidden: false
  // Caffeine / do not disturb on: the button is the island's satellite,
  // which enters the pill and grows up to here. Centers in x (within the Row).
  property bool satellitesDock: false
  readonly property real caffeineX: controlX("caffeine") + 22
  readonly property real dndX: controlX("dnd") + 22

  // The time in the middle: it's where the pointer lands; a click opens the dashboard.
  Item {
    id: clockBox
    x: quick.controlX("clock")
    visible: !quick.compact
    anchors.verticalCenter: parent.verticalCenter
    width: clockLabel.implicitWidth + 28
    height: 44
    Rectangle {
      anchors.fill: parent
      radius: 22
      color: Qt.alpha(quick.textColor, clockHover.hovered ? 0.12 : 0)
      Behavior on color { ColorAnimation { duration: 120 } }
    }
    Text {
      id: clockLabel
      anchors.centerIn: parent
      opacity: quick.clockHidden ? 0 : 1
      text: quick.timeText
      color: quick.textColor
      font.family: quick.displayFont
      font.pixelSize: 20
      font.weight: Font.Bold
      font.features: { "tnum": 1 }
    }
    HoverHandler { id: clockHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: quick.expand() }
  }

  Repeater {
    model: quick.compact ? [] : [{ glyph: "󰅶", act: "caffeine", on: quick.stayAwake }, { glyph: "󰂛", act: "dnd", on: quick.dnd }]
    Rectangle {
      required property var modelData
      x: quick.controlX(modelData.act)
      anchors.verticalCenter: parent.verticalCenter
      width: 44; height: 44; radius: 22
      opacity: quick.satellitesDock && modelData.on ? 0 : 1
      color: modelData.on ? quick.accent : Qt.alpha(quick.textColor, hov2.hovered ? 0.18 : 0.1)
      Behavior on color { ColorAnimation { duration: 120 } }
      scale: tap2.pressed ? 0.9 : 1
      Behavior on scale { NumberAnimation { duration: 90 } }
      Text {
        anchors.centerIn: parent
        text: modelData.glyph
        color: modelData.on ? "white" : quick.textColor
        font.family: quick.glyphFont
        font.pixelSize: 17
      }
      HoverHandler { id: hov2; cursorShape: Qt.PointingHandCursor }
      TapHandler {
        id: tap2
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: modelData.act === "dnd" ? quick.dndToggle() : quick.caffeine()
      }
    }
  }
}
