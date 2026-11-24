import QtQuick
import QtQuick.Shapes

// One renderer for the island and its panels. Colors are Hyprland's ARGB
// gradient stops; position determines which screen-attached edges are omitted.
Item {
  id: border
  anchors.fill: parent
  z: 1000
  property real borderWidth: 0
  property real rounding: 0
  property var colors: ["#ff777777"]
  property real angle: 0
  property string position: "top-center"
  property bool attached: true
  property string pathOverride: ""
  visible: borderWidth > 0 && width > 0 && height > 0
  function stopColor(i) { return colors[Math.min(i, Math.max(0, colors.length - 1))] || "#ff777777" }
  function stopPosition(i) { return Math.min(i / Math.max(1, colors.length - 1), 1) }
  readonly property real half: borderWidth / 2
  readonly property real l: half
  readonly property real r: Math.max(l, width - half)
  readonly property real t: half
  readonly property real b: Math.max(t, height - half)
  readonly property real rad: Math.max(0, Math.min(rounding, (r - l) / 2, (b - t) / 2))
  readonly property bool isBottom: position.startsWith("bottom-")
  readonly property bool isLeft: position.endsWith("-left")
  readonly property bool isRight: position.endsWith("-right")
  readonly property real dx: Math.cos(angle * Math.PI / 180)
  readonly property real dy: Math.sin(angle * Math.PI / 180)
  readonly property real span: Math.abs(dx) * width / 2 + Math.abs(dy) * height / 2
  function borderPath() {
    const x0=l, x1=r, y0=t, y1=b, q=rad
    if (!attached) return `M ${x0+q} ${y0} L ${x1-q} ${y0} Q ${x1} ${y0} ${x1} ${y0+q} L ${x1} ${y1-q} Q ${x1} ${y1} ${x1-q} ${y1} L ${x0+q} ${y1} Q ${x0} ${y1} ${x0} ${y1-q} L ${x0} ${y0+q} Q ${x0} ${y0} ${x0+q} ${y0}`
    if (!isBottom && isLeft) return `M ${x1} ${y0} L ${x1} ${y1-q} Q ${x1} ${y1} ${x1-q} ${y1} L ${x0} ${y1}`
    if (!isBottom && isRight) return `M ${x0} ${y0} L ${x0} ${y1-q} Q ${x0} ${y1} ${x0+q} ${y1} L ${x1} ${y1}`
    if (isBottom && isLeft) return `M ${x1} ${y1} L ${x1} ${y0+q} Q ${x1} ${y0} ${x1-q} ${y0} L ${x0} ${y0}`
    if (isBottom && isRight) return `M ${x0} ${y1} L ${x0} ${y0+q} Q ${x0} ${y0} ${x0+q} ${y0} L ${x1} ${y0}`
    if (!isBottom) return `M ${x0} ${y0} L ${x0} ${y1-q} Q ${x0} ${y1} ${x0+q} ${y1} L ${x1-q} ${y1} Q ${x1} ${y1} ${x1} ${y1-q} L ${x1} ${y0}`
    return `M ${x0} ${y1} L ${x0} ${y0+q} Q ${x0} ${y0} ${x0+q} ${y0} L ${x1-q} ${y0} Q ${x1} ${y0} ${x1} ${y0+q} L ${x1} ${y1}`
  }
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeWidth: border.borderWidth; fillColor: "transparent"; capStyle: ShapePath.FlatCap
      strokeGradient: LinearGradient {
        x1: border.width/2 - border.dx * border.span; y1: border.height/2 - border.dy * border.span
        x2: border.width/2 + border.dx * border.span; y2: border.height/2 + border.dy * border.span
        GradientStop { position: border.stopPosition(0); color: border.stopColor(0) }
        GradientStop { position: border.stopPosition(1); color: border.stopColor(1) }
        GradientStop { position: border.stopPosition(2); color: border.stopColor(2) }
        GradientStop { position: border.stopPosition(3); color: border.stopColor(3) }
        GradientStop { position: border.stopPosition(4); color: border.stopColor(4) }
        GradientStop { position: border.stopPosition(5); color: border.stopColor(5) }
        GradientStop { position: border.stopPosition(6); color: border.stopColor(6) }
        GradientStop { position: border.stopPosition(7); color: border.stopColor(7) }
        GradientStop { position: border.stopPosition(8); color: border.stopColor(8) }
        GradientStop { position: border.stopPosition(9); color: border.stopColor(9) }
      }
      PathSvg { path: border.pathOverride || border.borderPath() }
    }
  }
}
