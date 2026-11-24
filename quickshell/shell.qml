// Island: replaces the Omarchy bar with a black pill at the top center of the
// screen, halfway between the screen edge and the windows, that changes shape
// depending on what is going on.
//
//   idle          → workspace · clock · and only what is "live": recording,
//                   caffeine, do not disturb, music, notifications, critical battery
//   click         → dashboard: time and date, music, toggles and every panel
//   osd           → volume / brightness / messages (from the island.osd plugin)
//   notification  → the only place notifications appear, with their action buttons
//                   (from the notifications clone, which no longer draws cards)
//
// The Omarchy bar stays alive but hidden (omarchy toggle bar on): its panels
// are opened from here with `omarchy-shell shell toggle <id>`.
//
// IPC:  qs -c island ipc call island osd '<json>'
//       qs -c island ipc call island test notify|volume|brightness
//       qs -c island ipc call island toggle
import QtQuick
import "I18n.js" as I18n
import QtQuick.Shapes
import QtQuick.Effects
import "Brand.js" as Brand
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower

ShellRoot {
  id: root

  // User settings are kept outside the checkout and reload on save.
  property var userSettings: ({})
  FileView {
    id: settingsFile
    path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy-island/settings.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        const data = JSON.parse(text())
        if (data && typeof data === "object" && !Array.isArray(data)) root.userSettings = data
      } catch (e) { console.warn("Island settings: invalid JSON; keeping previous settings") }
    }
  }
  readonly property string clockFormat: typeof userSettings.clockFormat === "string" && userSettings.clockFormat.length > 0 ? userSettings.clockFormat : "h:mm AP"
  readonly property real configuredNotchScale: typeof userSettings.notchScale === "number" && isFinite(userSettings.notchScale) ? Math.max(0.5, Math.min(1, userSettings.notchScale)) : 0.95
  readonly property string position: ["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"].includes(userSettings.position) ? userSettings.position : "top-center"
  readonly property bool bottomEdge: position.startsWith("bottom-")
  readonly property string horizontalPosition: position.split("-")[1]
  readonly property bool atCorner: horizontalPosition !== "center"
  readonly property bool atRight: horizontalPosition === "right"
  function islandCenter(screenWidth, idleWidth) {
    const pad = 0
    return horizontalPosition === "left" ? pad + idleWidth / 2 : horizontalPosition === "right" ? screenWidth - pad - idleWidth / 2 : screenWidth / 2
  }
  readonly property string notchMode: ["all", "browser", "off"].includes(userSettings.notchMode) ? userSettings.notchMode : "all"

  // ── Animations ────────────────────────────────────────────────────────────
  // Same as the Omarchy shell: off when `omarchy toggle animations` has turned
  // off Hyprland's. Re-read on every config reload.
  property bool animate: true
  Process {
    id: animProbe
    running: true
    command: ["hyprctl", "-j", "getoption", "animations:enabled"]
    stdout: StdioCollector {
      onStreamFinished: { try { const o = JSON.parse(text); root.animate = (o.int === undefined ? true : o.int !== 0) } catch (e) {} }
    }
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) { if (event.name === "configreloaded") { animProbe.running = true; inactiveBorderProbe.running = true } }
  }

  // ── Geometry ──────────────────────────────────────────────────────────────
  // Reserved space at the top: windows start at reserve + Hyprland's gaps_out,
  // and the pill sits exactly halfway through that strip.
  readonly property int reserve: 34
  readonly property bool stripByHypr: Quickshell.env("ISLAND_STRIP") === "hypr"
  property int gapsOut: 10
  readonly property int idleHeight: 30
  readonly property int pillTop: Math.max(2, Math.round((reserve + gapsOut - idleHeight) / 2))

  Process {
    running: true
    command: ["hyprctl", "-j", "getoption", "general:gaps_out"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const o = JSON.parse(text)
          const m = String(o.custom || o.css || "").trim().split(/\s+/)
          const top = parseInt(m[0])
          if (!isNaN(top)) root.gapsOut = top
          else if (typeof o.int === "number") root.gapsOut = o.int
        } catch (e) {}
      }
    }
  }

  // ── Omarchy theme ─────────────────────────────────────────────────────────
  // Colors of the active Omarchy theme (colors.toml), updated on theme change.
  property color accent: "#7aa2f7"
  property color pillColor: "#000000"
  property color textColor: "#f5f5f7"
  readonly property color subColor: Qt.alpha(textColor, 0.6)
  property color red: "#ff453a"
  property color green: "#30d158"
  property color borderColor: "#595959"    // Hyprland window border (for the notch)
  property color inactiveBorderColor: "#aa23306e"   // same, unfocused window (read from Hyprland)
  Process {
    id: inactiveBorderProbe
    running: true
    command: ["hyprctl", "-j", "getoption", "general:col.inactive_border"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const m = String(JSON.parse(text).gradient || "").match(/^([0-9a-fA-F]{8})/)
          if (m) root.inactiveBorderColor = "#" + m[1]   // AARRGGBB, like Qt
        } catch (e) {}
      }
    }
  }
  // SF Pro if installed (it can't be shipped), otherwise the system sans.
  readonly property var fontList: Qt.fontFamilies()
  readonly property string textFont: fontList.includes("SF Pro Text") ? "SF Pro Text" : "sans-serif"
  readonly property string displayFont: fontList.includes("SF Pro Display") ? "SF Pro Display" : textFont   // large text (≥ 20 px)
  readonly property string glyphFont: "JetBrainsMono Nerd Font"

  // Omarchy replaces the folder on theme change: besides the file watch, a
  // re-read every few seconds (costs nothing) never misses the switch.
  Timer { running: true; repeat: true; interval: 3000; onTriggered: themeFile.reload() }
  FileView {
    id: themeFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      const pick = key => {
        const m = text().match(new RegExp("^" + key + "\\s*=\\s*\"(#[0-9a-fA-F]{6})\"", "m"))
        return m ? m[1] : ""
      }
      root.accent = pick("accent") || root.accent
      root.pillColor = pick("background") || root.pillColor
      root.textColor = pick("foreground") || root.textColor
      root.red = pick("red") || root.red
      root.green = pick("green") || root.green
      // Same single color as the window border (looknfeel.lua: the theme's muted).
      root.borderColor = Qt.alpha(pick("muted") || pick("selection") || pick("dark_foreground") || "#595959", 0.87)
      if (text() !== root.themeText) { root.themeText = text(); root.wallRev++ }
    }
  }
  property string themeText: ""
  // The background is a symlink with a fixed path: Qt would keep showing the
  // old image. Bumped on every theme load and whenever a notch appears (covers
  // a background picked without a theme switch), it busts the notch's image.
  property int wallRev: 0

  // ── Actions ───────────────────────────────────────────────────────────────
  // From the dashboard: the island first shrinks back to the pill, then the
  // action runs (a screenshot must not capture the dashboard closing).
  property var pendingArgv: []
  Timer {
    id: afterCollapse
    interval: 480
    onTriggered: { const a = root.pendingArgv; root.pendingArgv = []; if (a.length) Quickshell.execDetached(a) }
  }
  function later(argv) {
    const wasOpen = root.pinned || root.playerOpen
    root.pinned = false
    root.playerOpen = false
    if (!wasOpen) { Quickshell.execDetached(argv); return }
    root.pendingArgv = argv
    afterCollapse.restart()
  }
  function openPanel(id) { root.later(["omarchy-shell", "shell", "toggle", id]) }
  function run(argv) { root.later(argv) }
  function toggleCaffeine() {
    root.stayAwake = !root.stayAwake          // immediately; the poll confirms it later
    Quickshell.execDetached(["omarchy", "toggle", "idle"])
    pollSoon.restart()
  }
  function toggleRecording() {
    if (root.recording) Quickshell.execDetached(["omarchy-capture-screenrecording", "--stop-recording"])
    else root.run(["omarchy-menu", "toggle", "trigger.capture.screenrecord"])
    pollSoon.restart()
  }
  function toggleDnd() {
    root.dnd = !root.dnd
    Quickshell.execDetached(["omarchy-shell", "notifications", "toggleDnd"])
  }

  // ── State ─────────────────────────────────────────────────────────────────
  // Priority: osd > notification > dashboard > idle
  property bool pinned: false
  property bool centerOpen: false        // notification center inside the island
  // Compact player: hover the island while something is playing.
  property bool playerOpen: false
  property bool pillHovered: false

  // ── Installed Omarchy plugins (optional extras: Omadrop, omastats…) ──────
  property var plugins: []
  readonly property bool hasOmadrop: plugins.includes("lucas.omadrop")
  Process {
    id: pluginsProbe
    running: true
    command: ["sh", "-c", "ls -1 \"$HOME/.config/omarchy/plugins\" 2>/dev/null"]
    stdout: StdioCollector { onStreamFinished: root.plugins = text.split("\n").filter(x => x) }
  }
  Timer { interval: 60000; running: true; repeat: true; onTriggered: pluginsProbe.running = true }

  // ── Shelf (the same one as Omadrop) ───────────────────────────────────────
  // Drop files on the pill → they go to Omadrop's shelf; from the pill you
  // take them all back at once. See ShelfView.qml.
  property var shelfItems: []
  property bool dropHover: false
  property bool shelfOpen: false
  property bool shelfDragging: false
  property string shelfText: ""
  FileView {
    id: shelfFile
    path: Quickshell.env("HOME") + "/.local/state/omadrop/shelf.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseShelf(text())
  }
  // Omadrop rewrites the file via rename: the watch can miss it, so it is
  // also re-read periodically (tiny file).
  Timer { interval: 3000; running: true; repeat: true; onTriggered: shelfFile.reload() }
  Timer { id: shelfReload; interval: 400; onTriggered: shelfFile.reload() }
  function parseShelf(t) {
    if (t === root.shelfText) return
    root.shelfText = t
    try {
      const st = JSON.parse(t)
      const shelves = st.shelves || []
      let act = shelves.find(x => x.id === st.activeShelfId && x.archivedAt === null)
      if (!act) act = shelves.slice().reverse().find(x => x.archivedAt === null)
      root.shelfItems = act ? (act.items || []) : []
    } catch (e) { root.shelfItems = [] }
  }
  function omadrop(args) {
    Quickshell.execDetached(["omarchy-shell", "omadrop"].concat(args))
    shelfReload.restart()
  }
  function openShelf() { root.shelfOpen = true; shelfIdle.restart() }
  // Closes when the mouse leaves, or on its own if the mouse never comes by.
  Timer { id: shelfIdle; interval: 5000; onTriggered: if (!root.pillHovered && !root.shelfDragging) root.shelfOpen = false }
  Timer { id: shelfLeave; interval: 500; onTriggered: if (!root.pillHovered && !root.shelfDragging) root.shelfOpen = false }
  onShelfItemsChanged: if (!shelfItems.length && !shelfDragging && !dropHover) shelfOpen = false

  // ── Shake: "can't do that" (volume already at max/min, nothing to do) ────
  property real shakeX: 0
  SequentialAnimation {
    id: shakeAnim
    NumberAnimation { target: root; property: "shakeX"; to: -8; duration: 45; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shakeX"; to: 7; duration: 70; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeX"; to: -4; duration: 60; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeX"; to: 2; duration: 50; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeX"; to: 0; duration: 45; easing.type: Easing.OutQuad }
  }
  function shake() { if (root.animate && !shakeAnim.running) shakeAnim.restart() }
  Timer { id: playerHoverTimer; interval: 220; onTriggered: if (root.pillHovered && root.mode === "idle") root.playerOpen = true }
  Timer { id: playerLeaveTimer; interval: 320; onTriggered: root.playerOpen = false }
  // 0 = pill closed, 1 = dashboard: drives the elements that travel between
  // the two shapes (clock, cover art). Smooth curve, no bounce, straight path.
  property real dashT: mode === "dash" ? 1 : 0
  Behavior on dashT { enabled: root.animate; NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
  // The Omarchy menu (the menu clone) asks the island to take on its shape.
  property bool menuOpen: false
  property real menuW: 300
  property real menuH: 200
  onMenuOpenChanged: if (!menuOpen && !notif.active && notifQueue.length) Qt.callLater(nextNotification)
  readonly property string mode: menuOpen ? "menu"
                               : (dropHover || shelfOpen || shelfDragging) ? "shelf"
                               : osd.active ? "osd"
                               : notif.active ? "notify"
                               : liveKind !== "" ? "live"
                               : centerOpen ? "center"
                               : pinned ? "dash"
                               : playerOpen ? (player ? "player" : "quick")
                               : wsFlash ? "ws"
                               : "idle"

  // ── Clock ─────────────────────────────────────────────────────────────────
  SystemClock { id: clock; precision: SystemClock.Seconds }
  readonly property var itLocale: Qt.locale()
  readonly property string timeText: Qt.formatTime(clock.date, root.clockFormat)
  readonly property string dateText: {
    const s = clock.date.toLocaleDateString(itLocale, "dddd d MMMM")
    return s.charAt(0).toUpperCase() + s.slice(1)
  }

  // ── Workspace (Hyprland) ──────────────────────────────────────────────────
  readonly property var workspaces: {
    const list = []
    for (const w of Hyprland.workspaces.values) if (w && w.id > 0) list.push(w)
    list.sort((a, b) => a.id - b.id)
    return list
  }
  readonly property int activeWs: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1

  // On workspace change the island briefly shows the dots (not at startup).
  property bool wsFlash: false
  property bool wsReady: false
  property bool wsHovered: false
  property int lastWs: 0
  Timer { running: true; interval: 3000; onTriggered: root.wsReady = true }
  onActiveWsChanged: {
    if (wsReady && lastWs !== 0 && activeWs !== lastWs) { wsFlash = true; wsTimer.restart() }
    lastWs = activeWs
  }
  Timer { id: wsTimer; interval: 1300; onTriggered: if (root.wsHovered) restart(); else root.wsFlash = false }

  // ── Network ───────────────────────────────────────────────────────────────
  readonly property var wifiNet: {
    const devs = Networking.devices ? Networking.devices.values : []
    for (const d of devs) {
      if (d.type !== DeviceType.Wifi || !d.networks) continue
      for (const n of d.networks.values) if (n.connected) return n
    }
    return null
  }
  readonly property bool wiredUp: {
    const devs = Networking.devices ? Networking.devices.values : []
    for (const d of devs) if (d.type === DeviceType.Wired && d.connected) return true
    return false
  }
  readonly property string netGlyph: {
    if (wifiNet) {
      const s = wifiNet.signalStrength || 0
      return s > 0.75 ? "󰤨" : s > 0.5 ? "󰤥" : s > 0.25 ? "󰤢" : "󰤟"
    }
    if (wiredUp) return "󰈀"
    return Networking.wifiEnabled ? "󰤯" : "󰤮"
  }

  // ── Bluetooth ─────────────────────────────────────────────────────────────
  readonly property var btAdapter: Bluetooth.defaultAdapter
  readonly property bool btConnected: {
    const devs = Bluetooth.devices ? Bluetooth.devices.values : []
    for (const d of devs) if (d.connected) return true
    return false
  }
  readonly property string btDeviceName: {
    const devs = Bluetooth.devices ? Bluetooth.devices.values : []
    for (const d of devs) if (d.connected) return d.name || d.deviceName || ""
    return ""
  }
  readonly property string btGlyph: !btAdapter || !btAdapter.enabled ? "󰂲" : btConnected ? "󰂱" : "󰂯"

  // ── Audio ─────────────────────────────────────────────────────────────────
  readonly property var sink: Pipewire.defaultAudioSink
  PwObjectTracker { objects: [root.sink] }
  readonly property real volume: sink && sink.audio ? sink.audio.volume : 0
  readonly property bool muted: sink && sink.audio ? sink.audio.muted : false
  readonly property string volGlyph: muted || volume <= 0.001 ? "󰖁" : volume < 0.34 ? "󰕿" : volume < 0.67 ? "󰖀" : "󰕾"

  // ── Battery ───────────────────────────────────────────────────────────────
  readonly property var battery: UPower.displayDevice
  readonly property bool hasBattery: !!battery && battery.isPresent
  readonly property real batPct: hasBattery ? Math.max(0, Math.min(1, battery.percentage)) : 0
  readonly property bool charging: hasBattery && !UPower.onBattery
  readonly property bool batLow: hasBattery && !charging && batPct <= 0.2
  readonly property string batGlyph: {
    if (charging) return "󰂄"
    const steps = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    return steps[Math.round(batPct * 10)]
  }
  readonly property color batColor: batLow ? red : charging ? green : textColor

  // ── Live activities: charging and low battery ─────────────────────────────
  property string liveKind: ""          // "charge" | "low" | ""
  Timer { id: liveTimer; onTriggered: root.liveKind = "" }
  function showLive(kind, ms) { liveKind = kind; liveTimer.interval = ms; liveTimer.restart() }
  property bool batReady: false
  Timer { running: true; interval: 4000; onTriggered: root.batReady = true }
  onChargingChanged: if (batReady && charging) showLive("charge", 3200)
  property int lowStage: 0              // 0 ok, 1 warned at 15%, 2 at 5%
  onBatPctChanged: {
    if (!hasBattery || charging) { lowStage = 0; return }
    if (batPct <= 0.05 && lowStage < 2) { lowStage = 2; if (batReady) showLive("low", 5000) }
    else if (batPct <= 0.15 && lowStage < 1) { lowStage = 1; if (batReady) showLive("low", 5000) }
    else if (batPct > 0.16) lowStage = 0
  }

  // ── Reminders and timers (Omarchy's engine: omarchy-reminder) ─────────────
  property var nextReminder: null       // { label, at }
  Process {
    id: reminderPoll
    command: ["omarchy-reminder", "show", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const j = JSON.parse(text)
          let best = null
          for (const r of (j.reminders || [])) if (!best || r.at < best.at) best = r
          root.nextReminder = best ? { label: best.label, at: best.at } : null
        } catch (e) { root.nextReminder = null }
      }
    }
  }
  Timer { running: true; repeat: true; triggeredOnStart: true; interval: 15000; onTriggered: if (!reminderPoll.running) reminderPoll.running = true }
  readonly property string reminderText: {
    if (!nextReminder) return ""
    const left = Math.max(0, Math.round(nextReminder.at - clock.date.getTime() / 1000))
    if (left <= 0) return ""
    const h = Math.floor(left / 3600), m = Math.floor(left % 3600 / 60), sec = left % 60
    return h > 0 ? h + ":" + String(m).padStart(2, "0") + " h" : m + ":" + String(sec).padStart(2, "0")
  }

  // ── Privacy: microphone and webcam in use ─────────────────────────────────
  // Stream properties are only delivered for tracked objects.
  PwObjectTracker { objects: Pipewire.nodes ? Pipewire.nodes.values.filter(n => n && n.isStream) : [] }
  readonly property bool micInUse: {
    const nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (const n of nodes) {
      if (!n || !n.isStream || !n.properties) continue
      // Capture streams only: playback streams (including filters like Dolby)
      // are "sinks" too as far as Quickshell is concerned.
      if (n.properties["media.class"] !== "Stream/Input/Audio") continue
      const app = String(n.properties["application.name"] || n.properties["node.name"] || "").toLowerCase()
      if (app.indexOf("quickshell") !== -1 || app.indexOf("peak") !== -1 || app.indexOf("pavucontrol") !== -1) continue
      return true
    }
    return false
  }
  property bool camInUse: false
  Process {
    id: camPoll
    // Who holds a camera open, excluding wireplumber/pipewire. Processes that
    // feed a virtual camera can be ignored too: ISLAND_CAM_IGNORE="ffmpeg my-cam*"
    // (shell patterns, set it in a drop-in for omarchy-island.service).
    command: ["bash", "-c", "for d in /dev/video*; do fuser \"$d\" 2>/dev/null; done | tr ' ' '\\n' | sed '/^$/d' | sort -u | while read p; do c=$(ps -o comm= -p $p 2>/dev/null); [ -z \"$c\" ] && continue; skip=; for pat in wireplumber pipewire $ISLAND_CAM_IGNORE; do case $c in $pat) skip=1;; esac; done; [ -z \"$skip\" ] && echo $c; done"]
    stdout: StdioCollector { onStreamFinished: root.camInUse = text.trim() !== "" }
  }
  Timer { running: true; repeat: true; triggeredOnStart: true; interval: 4000; onTriggered: if (!camPoll.running) camPoll.running = true }

  // ── Caffeine and screen recording ─────────────────────────────────────────
  property bool stayAwake: false
  property bool recording: false
  property double recStart: 0
  onRecordingChanged: if (recording) recStart = Date.now()
  readonly property string recElapsed: {
    if (!recording) return ""
    const s = Math.max(0, Math.floor((clock.date.getTime() - recStart) / 1000))
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
  }

  Process {
    id: poll
    command: ["bash", "-c",
      'p="${XDG_RUNTIME_DIR:-$HOME/.local/state/omarchy}/omarchy-screenrecord-pid"; '
      + '[ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null && echo rec; '
      + '[ -f "$HOME/.local/state/omarchy/indicators/stay-awake" ] && echo awake; true']
    stdout: StdioCollector {
      onStreamFinished: {
        root.recording = text.indexOf("rec") !== -1
        root.stayAwake = text.indexOf("awake") !== -1
      }
    }
  }
  Timer { running: true; repeat: true; triggeredOnStart: true; interval: 2000; onTriggered: if (!poll.running) poll.running = true }
  Timer { id: pollSoon; interval: 700; onTriggered: if (!poll.running) poll.running = true }

  // ── Do not disturb ────────────────────────────────────────────────────────
  property bool dnd: false
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/quiet.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: { try { root.dnd = !!JSON.parse(text()).dnd } catch (e) {} }
  }

  // ── Music (MPRIS) ─────────────────────────────────────────────────────────
  // Only players whose D-Bus name or identity match this pattern, if set
  // (ISLAND_PLAYERS="spotify|mpv" in the service environment).
  // Screen-recording mode: network and device names are replaced with
  // generic ones (ISLAND_DEMO=1).
  readonly property bool demo: Quickshell.env("ISLAND_DEMO") === "1"
  readonly property string playerFilter: Quickshell.env("ISLAND_PLAYERS") || ""
  function playerAllowed(p) {
    return !root.playerFilter || new RegExp(root.playerFilter, "i").test((p.dbusName || "") + " " + (p.identity || ""))
  }
  readonly property var player: {
    // Read ALL players before choosing: stopping at the first one playing
    // would leave the binding blind to the others (e.g. Spotify starts while
    // YouTube was already listed).
    let playing = null, paused = null
    for (const p of Mpris.players.values) {
      if (!p || !root.playerAllowed(p)) continue
      // Phone players via KDE Connect (YouTube on the phone…): only while they
      // are actually playing; paused on the phone, they have nothing to do with the PC.
      const remote = (p.dbusName || "").includes("kdeconnect") || (p.trackArtUrl || "").includes("/kdeconnect")
      if (remote && !p.isPlaying) continue
      const isPlaying = p.isPlaying
      const isTrack = !!(p.trackTitle && p.trackArtist)
      if (isPlaying && !playing) playing = p
      // When paused it only counts if it's a real track (a browser tab with
      // WhatsApp open is an MPRIS "player" with no artist).
      else if (!isPlaying && isTrack && !paused) paused = p
    }
    return playing || (root.musicStale ? null : paused)
  }
  // Everything paused for over a minute: the island stops showing the music.
  readonly property bool anyPlaying: {
    for (const p of Mpris.players.values) if (p && p.isPlaying && root.playerAllowed(p)) return true
    return false
  }
  property bool musicStale: false
  onAnyPlayingChanged: { if (anyPlaying) { musicStale = false; staleTimer.stop() } else staleTimer.restart() }
  Timer { id: staleTimer; interval: 60000; onTriggered: root.musicStale = true }
  Component.onCompleted: if (!anyPlaying) staleTimer.restart()
  readonly property bool playing: !!player && player.isPlaying

  Timer {
    // MPRIS doesn't push the position: we poll it while visible.
    running: root.playing && (root.mode === "dash" || root.mode === "player")
    interval: 1000
    repeat: true
    onTriggered: if (root.player) root.player.positionChanged()
  }

  // ── OSD ───────────────────────────────────────────────────────────────────
  QtObject {
    id: osd
    property bool active: false
    property string icon: ""
    property string message: ""
    property real value: 0
    property real max: 100
    property bool hasProgress: true
  }
  Timer { id: osdTimer; interval: 1400; onTriggered: osd.active = false }

  function showOsd(json) {
    let p
    try { p = JSON.parse(json || "{}") } catch (e) { return "bad json" }
    const key = String(p.iconKey || "")
    osd.icon = p.icon || (key.startsWith("bright") || key === "display" ? "󰃠"
                       : key.startsWith("volume") ? "󰕾" : "")
    osd.message = p.message || ""
    osd.max = Math.max(1, Number(p.max) || 100)
    osd.value = Number(p.value) || 0
    osd.hasProgress = !!p.hasProgress
    osd.active = true
    const d = Number(p.duration)
    osdTimer.interval = (isNaN(d) || d <= 0) ? 1400 : Math.max(900, d + 200)
    osdTimer.restart()
    return "ok"
  }

  // ── Notifications ─────────────────────────────────────────────────────────
  // The D-Bus server is still Omarchy's (history, do not disturb, notification
  // center): the island reads live.json and drives the cards via the clone's IPC.
  QtObject {
    id: notif
    property bool active: false
    property string key: ""
    property string app: ""
    property string summary: ""
    property string body: ""
    property string iconSource: ""
    property string glyph: ""
    property string image: ""          // image file (screenshot) to drag
    property var deeds: []
    property int count: 1
  }
  property var seenKeys: ({})
  property var liveKeys: ({})
  property bool livePrimed: false
  property var notifQueue: []
  Timer {
    id: notifTimer
    interval: 6000
    // Stays while the mouse is over it.
    // When time runs out the notification is closed in Omarchy too (it stays in
    // the notification center), so nothing is left pending.
    onTriggered: root.notifCall("islandClose")
  }
  property bool notifHovered: false

  // Launcher of the webapp that opens that site (Exec=... --app=https://domain/).
  function webappFor(domain) {
    for (const e of DesktopEntries.applications.values) {
      const exec = String(e.execString || "")
      if (exec.indexOf("://" + domain) >= 0) return { name: e.name, icon: e.icon }
    }
    return null
  }
  function iconOk(name) { return Quickshell.iconPath(name, true) !== "" }
  function brand(n) { return n && !n.test ? Brand.normalize(n, root.webappFor, root.iconOk) : n }

  function iconFor(name) {
    if (!name) return ""
    if (name.startsWith("/")) return "file://" + name
    if (name.startsWith("file://") || name.startsWith("image://")) return name
    return Quickshell.iconPath(name, true)
  }

  // Image attached to the notification (e.g. omasnap: "Open" = xdg-open <file>).
  function imageFor(n) {
    const isImg = p => typeof p === "string" && /^\/.*\.(png|jpe?g|webp|gif)$/i.test(p)
    for (const k of ["image", "imagePath", "image-path"]) if (isImg(n[k])) return n[k]
    if (isImg(n.appIcon)) return n.appIcon
    try {
      const argv = JSON.parse(n.execArgv || "[]")
      for (const a of argv) if (isImg(a)) return a
    } catch (e) {}
    return ""
  }

  function nextNotification() {
    // While the menu is open, notifications wait in the queue.
    if (menuOpen) { notif.active = false; return }
    // Skip those Omarchy has already closed in the meantime.
    while (notifQueue.length > 0 && notifQueue[0].key && !liveKeys[notifQueue[0].key] && !notifQueue[0].test)
      notifQueue = notifQueue.slice(1)
    if (notifQueue.length === 0) { notif.active = false; notif.key = ""; notif.count = 1; return }
    // Queued notifications from the same app collapse into one: the latest, with a count.
    let n = notifQueue[0]
    let count = 1
    let rest = notifQueue.slice(1)
    const sameApp = x => (x.app || x.source || "") === (n.app || n.source || "")
    while (rest.length && sameApp(rest[0])) { n = rest[0]; rest = rest.slice(1); count++ }
    notifQueue = rest
    showNotification(n, count)
  }

  function showNotification(n, count) {
    notif.count = count
    notif.key = n.key || ""
    notif.app = n.app || n.source || ""
    notif.summary = n.summary || ""
    notif.body = (n.body || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim()
    notif.iconSource = iconFor(n.appIcon || "")
    notif.glyph = n.glyph || ""
    notif.image = imageFor(n)
    // Screenshot: flash, and the shot flies into the notification thumbnail.
    if (notif.image && (/omasnap|screenshot/i.test(notif.app) || n.test)) root.flyShot(notif.image)
    notif.deeds = []
    notif.active = true
    notifTimer.interval = 6000
    notifTimer.restart()
    if (notif.key) {
      deedsProc.command = ["omarchy-shell", "notifications", "islandDeeds", notif.key]
      deedsProc.running = true
    }
  }
  // How many others (from other apps) are waiting in the queue.
  readonly property int notifMore: notifQueue.length

  Process {
    id: deedsProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const list = JSON.parse(text)
          if (Array.isArray(list)) notif.deeds = list
        } catch (e) {}
      }
    }
  }

  function notifCall(method, extra) {
    if (notif.key) Quickshell.execDetached(["omarchy-shell", "notifications", method, notif.key].concat(extra || []))
    notifTimer.stop()
    root.nextNotification()
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/live.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      let list
      try { list = JSON.parse(text() || "[]") } catch (e) { return }
      if (!Array.isArray(list)) return
      const seen = Object.assign({}, root.seenKeys)
      const live = {}
      const fresh = []
      for (const n of list) {
        if (!n || !n.key) continue
        live[n.key] = true
        if (seen[n.key]) continue
        seen[n.key] = true
        if (root.livePrimed && !n.quiet) fresh.push(root.brand(n))
      }
      root.seenKeys = seen
      root.liveKeys = live
      root.livePrimed = true
      // Closed elsewhere (notification center, timeout): drop it from the island too.
      if (notif.active && notif.key && !live[notif.key] && !fresh.length) { notifTimer.stop(); root.nextNotification() }
      if (fresh.length === 0) return
      // Same app as the open one: update it in place, with the count.
      while (notif.active && fresh.length && (fresh[0].app || fresh[0].source || "") === notif.app) {
        const older = notif.key
        root.showNotification(fresh[0], notif.count + 1)
        if (older) Quickshell.execDetached(["omarchy-shell", "notifications", "islandClose", older])
        fresh.shift()
      }
      if (fresh.length === 0) return
      root.notifQueue = root.notifQueue.concat(fresh)
      if (!notif.active) root.nextNotification()
    }
  }

  // ── IPC ───────────────────────────────────────────────────────────────────
  IpcHandler {
    target: "island"
    function osd(json: string): string { return root.showOsd(json) }
    function ping(): string { return "ok" }
    function notch(): void { root.forceNotch = !root.forceNotch }
    // Diagnostics: for each workspace, whether the windows go up to the top (no strip).
    function browsers(): string {
      let out = []
      for (const w of Hyprland.workspaces.values) {
        let scr = null
        for (const s of Quickshell.screens) if (w.monitor && s.name === w.monitor.name) scr = s
        out.push(w.id + ":" + root.notchOk(w, scr))
      }
      return out.join(" ")
    }
    function test(what: string): string {
      if (what === "volume") return root.showOsd('{"iconKey":"volume","value":64,"max":100,"hasProgress":true,"message":"64%"}')
      if (what === "brightness") return root.showOsd('{"iconKey":"brightness","value":40,"max":100,"hasProgress":true,"message":"40%"}')
      if (what === "notify") {
        root.notifQueue = root.notifQueue.concat([{ test: true, app: "Island", summary: I18n.t("testTitle"), body: I18n.t("testBody"), appIcon: "dialog-information" }])
        if (!notif.active) root.nextNotification()
        return "ok"
      }
      // notify:{"app":…,"summary":…,"body":…,"appIcon":…} — custom test notification
      if (what.startsWith("notify:")) {
        try { root.notifQueue = root.notifQueue.concat([Object.assign({ test: true }, JSON.parse(what.slice(7)))]) } catch (e) { return "bad json" }
        if (!notif.active) root.nextNotification()
        return "ok"
      }
      if (what === "shelf") { root.openShelf(); return "ok" }
      if (what === "shake") { root.shake(); return "ok" }
      if (what === "ws") { root.wsFlash = true; wsTimer.restart(); return "ok" }
      if (what.startsWith("shot:")) {
        root.notifQueue = root.notifQueue.concat([{ test: true, app: "omasnap", glyph: "\uf030", summary: I18n.t("testShot"), body: I18n.t("testShotBody"), image: what.slice(5) }])
        if (!notif.active) root.nextNotification()
        return "ok"
      }
      if (what === "charge") { root.showLive("charge", 3200); return "ok" }
      if (what === "low") { root.showLive("low", 5000); return "ok" }
      return "volume | brightness | notify | shot:<file> | charge | low | shelf | shake"
    }
    function toggle(): void { root.pinned = !root.pinned }
    function mode(): string { return root.mode }
    function player(): void { root.playerOpen = !root.playerOpen }
    function center(): void { root.pinned = false; root.centerOpen = !root.centerOpen }
    function menu(state: string, w: string, h: string): string {
      root.menuW = Math.max(120, Number(w) || 300)
      root.menuH = Math.max(30, Number(h) || 200)
      root.menuOpen = state === "open"
      if (root.menuOpen) root.pinned = false
      return "ok"
    }
  }

  // In browser mode retain the upstream rule; all also permits terminals.
  readonly property bool notchEnabled: Quickshell.env("ISLAND_NOTCH") !== "off" && root.notchMode !== "off"
  function notchOk(ws, screen) {
    if (!root.notchEnabled || !ws || !ws.toplevels || !screen) return false
    const cx = screen.x + root.islandCenter(screen.width, 100)
    let tiled = 0
    for (const t of ws.toplevels.values) {
      const ipc = t.lastIpcObject || {}
      if (ipc.floating || !ipc.at || !ipc.size) continue
      tiled++
      if (root.notchMode === "browser" && ipc.at[0] <= cx && cx <= ipc.at[0] + ipc.size[0]) {
        const app = (t.wayland && t.wayland.appId) || ipc.class || ""
        if (!root.isBrowser(app)) return false
      }
    }
    return tiled > 0
  }
  // Gap between two windows under the pill (screen-local x of the two window
  // edges), or null. With a gap the notch "bridges" the windows, but each keeps
  // its own border, which turns down along its side.
  function notchGap(ws, screen) {
    if (!ws || !ws.toplevels || !screen) return null
    const cx = screen.x + root.islandCenter(screen.width, 100)
    let l = -1, r = -1
    for (const t of ws.toplevels.values) {
      const ipc = t.lastIpcObject || {}
      if (ipc.floating || !ipc.at || !ipc.size) continue
      const a = ipc.at[0], b = ipc.at[0] + ipc.size[0]
      if (a <= cx && cx <= b) return null
      if (b <= cx && (l < 0 || b > l)) l = b
      if (a >= cx && (r < 0 || a < r)) r = a
    }
    return l >= 0 && r >= 0 ? { l: l - screen.x, r: r - screen.x } : null
  }
  // ISLAND_HIDE=tiled: the island steps aside (and the windows go to the top)
  // with a browser on its own or two or more tiled windows. It still appears for
  // the dashboard (gesture, SUPER+D), notifications, OSD and the menu.
  readonly property bool hideEnabled: Quickshell.env("ISLAND_HIDE") === "tiled"
  function islandHides(ws) {
    if (!root.hideEnabled || !ws || !ws.toplevels) return false
    let n = 0, browser = false
    for (const t of ws.toplevels.values) {
      const ipc = t.lastIpcObject || {}
      if (ipc.floating) continue
      n++
      browser = root.isBrowser((t.wayland && t.wayland.appId) || ipc.class || "")
    }
    return n >= 2 || (n === 1 && browser)
  }
  property bool forceNotch: false   // testing: `ipc call island notch`
  function isBrowser(app) {
    return /^(zen|zen-browser|firefox|librewolf|floorp|chromium|google-chrome.*|brave-browser.*|microsoft-edge.*|vivaldi.*|helium)$/i.test(app || "")
  }
  // Toplevel IPC info (class, floating) has to be queried from Hyprland.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (["openwindow", "closewindow", "movewindow", "movewindowv2", "changefloatingmode", "workspace", "workspacev2", "focusedmon"].includes(event.name))
      {
        Hyprland.refreshToplevels()
        // The layout settles after the event: geometry again a moment later.
        toplevelSettle.restart()
      }
    }
  }
  Timer { id: toplevelSettle; interval: 250; onTriggered: Hyprland.refreshToplevels() }
  // Workspace switch: Hyprland slides the windows sideways (looknfeel.lua,
  // speed 4.5 = 450 ms) while the notch stays put, so its border would hang in
  // mid-air. It vanishes at once and comes back once the windows have stopped.
  property bool wsSliding: false
  Timer { id: wsSlideTimer; interval: 400; onTriggered: root.wsSliding = false }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (root.animate && (event.name === "workspacev2" || event.name === "focusedmonv2")) {
        root.wsSliding = true
        wsSlideTimer.restart()
      }
    }
  }

  // ── Reserved strip: keeps windows below the island ────────────────────────
  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      anchors { top: !root.bottomEdge; bottom: root.bottomEdge; left: true; right: true }
      implicitHeight: 1
      // Browser or gap between windows under the pill: no strip, the windows go
      // all the way to the top and the island sits over them as a notch.
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      readonly property bool notchOk: root.notchOk(hyprMonitor ? hyprMonitor.activeWorkspace : null, modelData)
      // ISLAND_STRIP=hypr: the strip is each workspace's own top gap, written by
      // a Hyprland script with the same rule (a workspace keeps it while you swipe
      // to it). Otherwise one reserved zone for the whole screen, switched here.
      exclusiveZone: root.stripByHypr || notchOk || root.islandHides(hyprMonitor ? hyprMonitor.activeWorkspace : null) ? 0 : root.reserve
      color: "transparent"
      mask: Region {}
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.namespace: "island-reserve"
    }
  }

  // ── Drop sensor: the shelf while the island is hidden ─────────────────────
  // With ISLAND_HIDE (browser / 2+ windows) or a fullscreen app the island is
  // gone, and so is its drop target. A thin invisible strip at the top center
  // (inside the top gap, so it steals no clicks from the windows) wakes the
  // shelf when a file is dragged there; the file can be dropped on the strip or
  // on the shelf that appears. Resting on it (with something on the shelf)
  // opens the shelf too, to pick files up on another workspace.
  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: sensor
      required property var modelData
      screen: modelData
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      readonly property var ws: hyprMonitor ? hyprMonitor.activeWorkspace : null
      anchors.top: !root.bottomEdge
      anchors.bottom: root.bottomEdge
      anchors.left: root.horizontalPosition === "left"
      anchors.right: root.horizontalPosition === "right"
      implicitWidth: 520
      implicitHeight: 18     // room for the glow; the mouse only sees the top 6 px
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"
      visible: root.hasOmadrop && !!ws && (ws.hasFullscreen || root.islandHides(ws))
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "island-drop"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region { item: hitStrip }
      Item { id: hitStrip; width: parent.width; height: 6; y: root.bottomEdge ? parent.height - height : 0 }
      property bool dragOver: false

      // Something on the shelf: a thin glowing bar where the island would be,
      // breathing slowly. It stretches when a file comes near and hands over
      // to the island when the shelf opens.
      Item {
        id: glow
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.bottomEdge ? parent.height - height - 3 : 3
        readonly property bool on: root.shelfItems.length > 0 || sensor.dragOver
        readonly property bool away: root.mode === "shelf"
        width: !on ? 0 : sensor.dragOver ? 150 : 64 + Math.min(4, root.shelfItems.length - 1) * 8
        height: 3
        opacity: on && !away ? 1 : 0
        Behavior on width { enabled: root.animate; SpringAnimation { spring: 3; damping: 0.3; epsilon: 0.3 } }
        Behavior on opacity { id: glowFade; enabled: root.animate; NumberAnimation { duration: glowFade.targetValue > 0.5 ? 320 : 140; easing.type: Easing.OutCubic } }
        property real breath: 1
        SequentialAnimation on breath {
          running: glow.on && !glow.away && root.animate && sensor.visible
          loops: Animation.Infinite
          NumberAnimation { to: 0.45; duration: 1400; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1; duration: 1400; easing.type: Easing.InOutSine }
        }
        RectangularShadow {
          anchors.fill: bar
          radius: bar.radius
          blur: sensor.dragOver ? 12 : 9
          spread: 1
          color: root.accent
          opacity: sensor.dragOver ? 1 : 0.35 + 0.55 * glow.breath
        }
        Rectangle {
          id: bar
          anchors.fill: parent
          radius: height / 2
          color: Qt.lighter(root.accent, sensor.dragOver ? 1.35 : 1.1)
          opacity: sensor.dragOver ? 1 : 0.75 + 0.25 * glow.breath
        }
      }

      DropArea {
        anchors.fill: hitStrip
        enabled: !root.shelfDragging
        onEntered: function(drag) {
          if (!drag.hasUrls) return
          drag.accept(Qt.CopyAction)
          sensor.dragOver = true
          sensorWake.restart()
        }
        onExited: { sensor.dragOver = false; sensorWake.stop() }
        onDropped: function(drop) {
          if (!drop.hasUrls) return
          const uris = []
          for (let i = 0; i < drop.urls.length; i++) uris.push(String(drop.urls[i]))
          if (!uris.length) return
          drop.accept(Qt.CopyAction)
          sensor.dragOver = false
          root.omadrop(["add", uris.join("\n")])
          root.openShelf()
        }
      }
      // The bar stretches first, then the island drops out of it.
      Timer { id: sensorWake; interval: 140; onTriggered: root.openShelf() }
      HoverHandler {
        onHoveredChanged: hovered ? sensorDwell.restart() : sensorDwell.stop()
      }
      Timer {
        id: sensorDwell
        interval: 350
        onTriggered: if (root.shelfItems.length) root.openShelf()
      }
    }
  }

  // ── The island ────────────────────────────────────────────────────────────
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData

      anchors { top: true; left: true; right: true }
      implicitHeight: modelData.height
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "island"
      // Fullscreen app on this screen: the island gets out of the way.
      // Only the OSD (volume/brightness) stays, useful during a video too.
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      readonly property bool fullscreenHere: !!hyprMonitor && !!hyprMonitor.activeWorkspace
                                             && hyprMonitor.activeWorkspace.hasFullscreen
      readonly property bool hiddenHere: root.islandHides(hyprMonitor ? hyprMonitor.activeWorkspace : null)
      readonly property bool shown: fullscreenHere ? (root.mode === "osd" || root.mode === "shelf")
                                                   : (!hiddenHere || (root.mode !== "idle" && root.mode !== "ws"))
      // Coming out of hiding the pill drops from the top edge (from the glow bar)
      // with a little bounce; going back it slips up quickly. The window stays
      // mapped until the way out is over.
      property real reveal: shown ? 1 : 0
      Behavior on reveal {
        id: revealAnim
        enabled: root.animate
        NumberAnimation {
          duration: revealAnim.targetValue > 0.5 ? 460 : 200
          easing.type: revealAnim.targetValue > 0.5 ? Easing.OutBack : Easing.InCubic
          easing.overshoot: 1.25
        }
      }
      visible: shown || reveal > 0.001
      readonly property real revealT: Math.max(0, Math.min(1, reveal))
      // Fully out and staying: only then the resting content (clock, workspaces,
      // satellites) may show. Otherwise, coming out of hiding the clock flashed
      // before the shelf, and going back it reappeared while sliding away.
      readonly property bool calm: shown && reveal >= 0.999
      // Windows up to the top (see notchOk): when idle the pill becomes a notch
      // and the window border wraps around it.
      readonly property bool notchScreen: !fullscreenHere && root.notchOk(hyprMonitor ? hyprMonitor.activeWorkspace : null, modelData)
      readonly property real notchScale: root.configuredNotchScale
      readonly property int notchTop: root.atCorner ? 0 : 3
      // Focused window on this screen's workspace: the notch border takes the same
      // active/inactive color Hyprland gives the window it belongs to.
      readonly property var focusIpc: {
        const a = Hyprland.activeToplevel
        const ws = hyprMonitor ? hyprMonitor.activeWorkspace : null
        return a && ws && a.workspace === ws && a.lastIpcObject && a.lastIpcObject.at ? a.lastIpcObject : null
      }
      function focusedEdge(left) {   // is the focused window the one ending/starting at the gap?
        if (!focusIpc || !notchGap) return false
        const x = focusIpc.at[0] - modelData.x
        return left ? x + focusIpc.size[0] === notchGap.l : x === notchGap.r
      }
      readonly property bool centerFocused: {
        if (!focusIpc || focusIpc.floating) return false
        const cx = modelData.x + win.desiredCenter
        return focusIpc.at[0] <= cx && cx <= focusIpc.at[0] + focusIpc.size[0]
      }
      readonly property var notchGap: notchScreen ? root.notchGap(hyprMonitor ? hyprMonitor.activeWorkspace : null, modelData) : null
      // notch = the pill takes its notch form (smaller, higher, slim) right away,
      // during the workspace slide too: one movement. notchDrawn = the border and
      // the carved background, which wait for the windows to stop.
      readonly property bool notchDrawn: notch && !root.wsSliding
      readonly property bool notch: (notchScreen || root.forceNotch) && (root.mode === "idle" || root.mode === "ws")
      onNotchChanged: if (notch) root.wallRev++
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Only the pill receives the mouse.
      mask: root.shelfDragging ? parkRegion : pillRegion
      Region { id: parkRegion }
      Region {
        id: pillRegion
        item: pill
        Region { item: satCaffeine }
        Region { item: satDnd }
        Region { item: satBattery }
        Region { item: satShelf }
      }

      // Clock only: narrow pill, 14 px per side. A bit more with ears.
      readonly property real idleWidth: idleRow.implicitWidth + 28
      readonly property real desiredCenter: root.islandCenter(win.width, win.idleWidth)
      readonly property real pillCenter: root.atCorner ? (root.atRight ? win.width - pill.width / 2 : pill.width / 2) : win.width / 2
      readonly property real restWidth: root.mode === "ws" ? wsRow.implicitWidth + 36 : idleWidth
      // Notification = a real pill: a single band, taller only if the text wraps to two lines.
      readonly property real notifHeight: !notif.body ? 56 : (notif.body.length > 52 ? 80 : 68)
      readonly property size targetSize: {
        switch (root.mode) {
          case "osd":    return Qt.size(osd.hasProgress ? 300 : Math.min(440, osdMsgMetrics.advanceWidth + 90), 40)
          case "notify": return Qt.size(Math.min(win.width - 40, 410 + notifView.actionsWidth), win.notifHeight)
          case "dash":   return Qt.size(480, dash.implicitHeight + 36)
          case "player": return Qt.size(420 + 112, 76)
          case "live":   return Qt.size(300, 44)
          case "quick":  return Qt.size(quickFull.implicitWidth + 24, 60)
          case "center": return Qt.size(460, Math.min(win.height - 60, centerView.implicitHeight + 36))
          case "shelf":  return Qt.size(410, 84)
          case "menu":   return Qt.size(win.idleWidth, root.idleHeight)   // the menu sizes itself
          case "ws":     return Qt.size(win.restWidth, root.idleHeight)
          default:       return Qt.size(win.idleWidth, root.idleHeight)
        }
      }
      readonly property real targetRadius: root.mode === "idle" || root.mode === "ws" ? root.idleHeight / 2
                                         : root.mode === "osd" ? 20
                                         : root.mode === "notify" ? win.notifHeight / 2
                                         : root.mode === "player" ? 38
                                         : root.mode === "quick" ? 30
                                         : root.mode === "shelf" ? 42
                                         : 32

      TextMetrics {
        id: osdMsgMetrics
        font.family: root.textFont
        font.pixelSize: 13
        font.weight: Font.DemiBold
        text: osd.message
      }

      // Where the screenshot thumbnail sits in the notification (screen coordinates).
      readonly property real thumbH: win.notifHeight - 16
      Binding {
        target: root; property: "shotTarget"
        when: !!win.hyprMonitor && win.hyprMonitor.focused
        value: Qt.rect(win.pillCenter - Math.min(win.width - 40, 410 + notifView.actionsWidth) / 2 + 8,
                       (root.bottomEdge ? win.height - root.pillTop - win.notifHeight : root.pillTop) + 8, Math.round(win.thumbH * 1.45), win.thumbH)
      }
      Binding { target: root; property: "shotTargetRadius"; when: !!win.hyprMonitor && win.hyprMonitor.focused; value: win.thumbH / 2 }

      // Idle pill geometry, for the menu that takes on its shape.
      readonly property string pillGeometry: JSON.stringify({ w: Math.round(win.idleWidth), h: root.idleHeight, x: Math.round(win.desiredCenter - win.idleWidth / 2), y: root.bottomEdge ? win.height - (root.atCorner ? 0 : root.pillTop) - root.idleHeight : (root.atCorner ? 0 : root.pillTop), position: root.position })
      onPillGeometryChanged: pillFile.setText(pillGeometry)
      FileView {
        id: pillFile
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/island-pill.json"
        printErrors: false
        Component.onCompleted: setText(win.pillGeometry)
      }

      RectangularShadow {
        anchors.fill: pill
        transformOrigin: root.bottomEdge ? Item.Bottom : Item.Top
        scale: pill.scale
        transform: [
          Scale { origin.x: pill.width / 2; origin.y: root.bottomEdge ? pill.height : 0; xScale: 0.55 + 0.45 * win.reveal; yScale: 0.25 + 0.75 * win.reveal },
          Translate { y: (root.bottomEdge ? 1 : -1) * (1 - win.reveal) * (root.pillTop + 14) }
        ]
        // No shadow with the notch: it darkened the page around it but not the
        // background redrawn inside the notch, leaving a visible box and line.
        opacity: win.notch ? 0 : pill.opacity * win.revealT
        Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 180 } }
        radius: pill.radius
        blur: root.mode === "idle" || root.mode === "ws" ? 22 : 34
        offset.y: root.mode === "idle" || root.mode === "ws" ? 5 : 9
        color: Qt.rgba(0, 0, 0, root.mode === "idle" || root.mode === "ws" ? 0.42 : 0.5)
        Behavior on blur { enabled: root.animate; NumberAnimation { duration: 250 } }
        Behavior on color { enabled: root.animate; ColorAnimation { duration: 250 } }
      }

      // ── Satellites: circles detached from the island for active modes ───
      // (caffeine, do not disturb). They spring out from under the pill and slide
      // back in when turned off; they hide while the island is open.
      component Satellite: Rectangle {
        id: sat
        property bool on: false
        property int slot: 0
        property string glyph: ""
        property color glyphColor: root.accent
        property real extra: 0            // extra room for wide satellites first
        // Stays with the notch too (the shelf: otherwise unreachable in a browser):
        // shrunk like the pill, next to it, and the notch widens to wrap both.
        property bool inNotch: false
        readonly property bool notched: inNotch && win.notch
        signal clicked()
        readonly property bool shown: on && win.calm && (!win.notch || inNotch) && (root.mode === "idle" || root.mode === "ws")
        // On hover (quick actions) caffeine and do not disturb don't vanish: the
        // same circle moves into the pill and grows to its button's spot,
        // becoming the button (like the clock).
        property real dockX: -1                      // center, window coordinates
        readonly property bool docked: on && dockX >= 0 && root.mode === "quick"
        // While moving in or back out it sits above the pill.
        property bool riding: false
        onDockedChanged: if (docked) riding = true; else rideOff.restart()
        Timer { id: rideOff; interval: 700; onTriggered: sat.riding = false }
        z: riding ? 5 : notched ? 3 : 0
        readonly property real shadowOpacity: docked || notched ? 0 : opacity
        // Final position computed from the idle pill (not the one still
        // animating): so it slides back right away, with the same spring.
        // It follows the real pill: on workspace change the pill widens and the
        // satellites move aside with the same spring instead of touching it.
        readonly property real idleRight: win.pillCenter + win.restWidth / 2
        readonly property real restX: root.horizontalPosition === "right" ? win.pillCenter - win.restWidth / 2 - 6 - width - slot * (root.idleHeight + 6) - extra : idleRight + 6 + slot * (root.idleHeight + 6) + extra
        width: root.idleHeight
        height: root.idleHeight
        radius: height / 2
        // With the notch: same scale as the pill, top-aligned with it (scale is
        // around the center, hence the offsets).
        readonly property real notchRestX: root.horizontalPosition === "right" ? win.pillCenter - win.restWidth * win.notchScale / 2 - 6 * win.notchScale - width * (1 + win.notchScale) / 2 : win.pillCenter + win.restWidth * win.notchScale / 2 + 6 * win.notchScale - width * (1 - win.notchScale) / 2
        readonly property real notchY: win.notchTop - height * (1 - win.notchScale) / 2
        y: root.bottomEdge ? win.height - height - (docked ? root.pillTop + 30 - height / 2 : notched ? notchY : root.pillTop) : (docked ? root.pillTop + 30 - height / 2 : notched ? notchY : root.pillTop)
        // Follow the pill's moving center directly while animating only the
        // satellite's offset. This avoids restarting the animation each frame.
        property real centerOffset: (docked ? dockX - width / 2 : shown ? (notched ? notchRestX : restX) : idleRight - width) - win.pillCenter
        x: win.pillCenter + centerOffset
        scale: docked ? 44 / root.idleHeight : shown ? (notched ? win.notchScale : 1) : 0.4
        opacity: shown || docked ? 1 : 0
        color: docked ? root.accent : root.pillColor
        Behavior on centerOffset { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: root.animate; SpringAnimation { spring: 3.4; damping: 0.3; epsilon: 0.3 } }
        Behavior on scale { enabled: root.animate; SpringAnimation { spring: 3.4; damping: 0.3; epsilon: 0.01 } }
        Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 160 } }
        Behavior on color { enabled: root.animate; ColorAnimation { duration: 260 } }
        Text {
          anchors.centerIn: parent
          text: sat.glyph
          color: sat.docked ? "white" : sat.glyphColor
          Behavior on color { enabled: root.animate; ColorAnimation { duration: 260 } }
          font.family: root.glyphFont
          font.pixelSize: sat.docked ? 12 : 14
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { enabled: sat.shown || sat.docked; gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: sat.clicked() }
      }
      Satellite {
        id: satCaffeine
        on: root.stayAwake
        slot: 0
        dockX: win.pillCenter - quickFull.implicitWidth / 2 + quickFull.caffeineX
        glyph: "󰅶"
        onClicked: root.toggleCaffeine()
      }
      Satellite {
        id: satDnd
        on: root.dnd
        dockX: win.pillCenter - quickFull.implicitWidth / 2 + quickFull.dndX
        slot: root.stayAwake ? 1 : 0
        glyph: "󰂛"
        glyphColor: root.subColor
        onClicked: root.toggleDnd()
      }
      // Low or charging battery: a circle with a drawn battery.
      Satellite {
        id: satBattery
        on: root.batLow && !root.charging
        slot: (root.stayAwake ? 1 : 0) + (root.dnd ? 1 : 0)
        glyph: ""
        onClicked: root.openPanel("omarchy.power")
        // Pill: smaller icon + percentage.
        width: battRow.implicitWidth + 20
        Row {
          id: battRow
          anchors.centerIn: parent
          spacing: 5
          BatteryIcon {
            anchors.verticalCenter: parent.verticalCenter
            scale: 0.82
            level: root.batPct
            charging: root.charging
            tint: root.charging ? root.green : root.batLow ? root.red : root.textColor
            outline: root.textColor
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Math.round(root.batPct * 100) + "%"
            color: root.batLow && !root.charging ? root.red : root.textColor
            font.family: root.textFont
            font.pixelSize: 12
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
          }
        }
      }
      // Shelf with something in it: mini stack (most recent file on top)
      // and a count. Click = open the shelf; you can also drop files on it.
      Satellite {
        id: satShelf
        on: root.shelfItems.length > 0
        inNotch: true
        slot: (root.stayAwake ? 1 : 0) + (root.dnd ? 1 : 0) + (satBattery.on ? 1 : 0)
        extra: satBattery.on ? satBattery.width - root.idleHeight : 0
        // Right edge as drawn (window coordinates), for the notch.
        readonly property real drawnRight: x + width / 2 + width * scale / 2
        onClicked: root.openShelf()
        // Same size and style as caffeine: circle with a filled glyph.
        glyph: "\u{F0687}"
        // Count: small dot on the edge, only if more than one.
        Rectangle {
          visible: root.shelfItems.length > 1
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -3
          anchors.topMargin: -3
          width: Math.max(14, shelfCount.implicitWidth + 7); height: 14
          radius: 7
          color: root.accent
          border.width: 1
          border.color: root.pillColor
          Text {
            id: shelfCount
            anchors.centerIn: parent
            text: root.shelfItems.length
            color: root.pillColor
            font.family: root.textFont
            font.pixelSize: 9
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
          }
        }
        DropArea {
          anchors.fill: parent
          enabled: !root.shelfDragging && root.hasOmadrop
          onEntered: function(drag) { if (drag.hasUrls) { drag.accept(Qt.CopyAction); root.dropHover = true } }
          onExited: root.dropHover = false
          onDropped: function(drop) {
            root.dropHover = false
            const uris = []
            for (let i = 0; i < drop.urls.length; i++) uris.push(String(drop.urls[i]))
            if (!uris.length) return
            drop.accept(Qt.CopyAction)
            root.omadrop(["add", uris.join("\n")])
            root.openShelf()
          }
        }
      }
      RectangularShadow {
        z: -1
        anchors.fill: satShelf
        radius: satShelf.radius
        blur: 20; offset.y: 5
        opacity: satShelf.shadowOpacity
        color: Qt.rgba(0, 0, 0, 0.42)
      }
      RectangularShadow {
        z: -1
        anchors.fill: satCaffeine
        radius: satCaffeine.radius
        blur: 20; offset.y: 5
        opacity: satCaffeine.shadowOpacity
        color: Qt.rgba(0, 0, 0, 0.42)
      }
      RectangularShadow {
        z: -1
        anchors.fill: satBattery
        radius: satBattery.radius
        blur: 20; offset.y: 5
        opacity: satBattery.opacity
        color: Qt.rgba(0, 0, 0, 0.42)
      }
      RectangularShadow {
        z: -1
        anchors.fill: satDnd
        radius: satDnd.radius
        blur: 20; offset.y: 5
        opacity: satDnd.shadowOpacity
        color: Qt.rgba(0, 0, 0, 0.42)
      }

      // ── Notch: the browser border dips down and wraps around the pill ───
      // A window can't have a hole punched in it: the island redraws the desktop
      // background inside the notch shape, so the browser looks carved out.
      Item {
        id: notchLayer
        // Fades in and out while the pill shrinks.
        opacity: win.notchDrawn && !root.atCorner ? 1 : 0
        // During a workspace slide: gone at once (a fade-out would hang in mid-air).
        visible: opacity > 0 && !root.wsSliding
        Behavior on opacity { enabled: root.animate; NumberAnimation { duration: win.notchDrawn ? 260 : 120; easing.type: Easing.OutCubic } }
        // Full-screen coordinates (the island window is centered).
        readonly property real offsetX: 0
        x: 0; y: root.bottomEdge ? win.height - height : 0
        transform: Scale { origin.y: 32; yScale: root.bottomEdge ? -1 : 1 }
        width: win.modelData.width
        height: 64
        // Shape: the border follows the pill at a constant distance (same centers
        // as its corners, radius + m) and joins the browser border with two
        // tangent arcs: no corners, no crooked straight segments.
        readonly property real m: 4                       // pill ↔ border gap
        readonly property real r: 9                       // fillet radius with the top border
        readonly property real edgeY: root.gapsOut        // browser top border
        // Pill as rendered (scaled down from the top).
        readonly property real pw: pill.width * pill.scale
        readonly property real ph: pill.height * pill.scale
        readonly property real pl: offsetX + pill.x + (pill.width - pw) / 2
        readonly property real pr: Math.min(pill.radius * pill.scale, ph / 2)   // pill corner radius
        readonly property real big: pr + m                                       // border radius
        readonly property real cy: (root.bottomEdge ? win.height - (pill.y + pill.height) : pill.y) + ph - pr                              // bottom corner centers
        readonly property real cxL: pl + pr
        // Shelf satellite next to the pill: the notch reaches it too.
        readonly property real cxR: Math.max(pl + pw, satShelf.notched && satShelf.opacity > 0 ? offsetX + satShelf.drawnRight : 0) - pr
        // Fillet centers: r below the border, tangent to the big circle.
        readonly property real fy: edgeY + r
        readonly property real fdx: Math.sqrt(Math.max(0, (big + r) * (big + r) - (fy - cy) * (fy - cy)))
        readonly property real fxL: cxL - fdx
        readonly property real fxR: cxR + fdx
        // Tangent point on the circle of radius big+o (o = stroke offset).
        function tx(side, o) { const cx = side < 0 ? cxL : cxR, fx = side < 0 ? fxL : fxR; return cx + (fx - cx) * (big + o) / (big + r) }
        function ty(o) { return cy + (fy - cy) * (big + o) / (big + r) }
        // Bridge (gap between two windows under the pill): outer edges of the two
        // window borders (Hyprland draws them outside the window, bw wide) and the
        // bottom of the notch. Each window corner is rounded with radius r.
        readonly property real bw: 2
        readonly property real eL: win.notchGap ? win.notchGap.l + bw : 0
        readonly property real eR: win.notchGap ? win.notchGap.r - bw : 0
        readonly property real yb: cy + big
        // The window corners shrink when the pill is narrow (clock only), so the
        // bridge holds for every pill width (no flipping while it animates).
        readonly property real rcL: Math.max(1.5, Math.min(r, eL - cxL))
        readonly property real rcR: Math.max(1.5, Math.min(r, cxR - eR))
        readonly property bool bridge: !!win.notchGap && eL - 1.5 > cxL && eR + 1.5 < cxR && eL < eR

        Item {
          id: wallStrip
          anchors.fill: parent
          clip: true
          visible: false
          layer.enabled: true
          Image {
            width: win.modelData.width
            height: win.modelData.height
            source: "file://" + Quickshell.env("HOME") + "/.local/state/omarchy/current/background?r=" + root.wallRev
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(win.modelData.width * 2, win.modelData.height * 2)
            cache: false
          }
        }
        // Same outline for the mask (o = 0) and the border (o = 1, half the stroke width).
        component NotchPath: ShapePath {
          property real o: 0
          startX: notchLayer.fxL; startY: notchLayer.edgeY + o
          PathArc { x: notchLayer.tx(-1, o); y: notchLayer.ty(o); radiusX: notchLayer.r - o; radiusY: notchLayer.r - o; direction: PathArc.Clockwise }
          PathArc { x: notchLayer.cxL; y: notchLayer.cy + notchLayer.big + o; radiusX: notchLayer.big + o; radiusY: notchLayer.big + o; direction: PathArc.Counterclockwise }
          PathLine { x: notchLayer.cxR; y: notchLayer.cy + notchLayer.big + o }
          PathArc { x: notchLayer.tx(1, o); y: notchLayer.ty(o); radiusX: notchLayer.big + o; radiusY: notchLayer.big + o; direction: PathArc.Counterclockwise }
          PathArc { x: notchLayer.fxR; y: notchLayer.edgeY + o; radiusX: notchLayer.r - o; radiusY: notchLayer.r - o; direction: PathArc.Clockwise }
        }
        Shape {
          id: notchMask
          anchors.fill: parent
          visible: false
          layer.enabled: true
          preferredRendererType: Shape.CurveRenderer
          NotchPath {
            strokeWidth: -1
            fillColor: notchLayer.bridge ? "transparent" : "black"
            PathLine { x: notchLayer.fxR; y: notchLayer.edgeY - 1 }
            PathLine { x: notchLayer.fxL; y: notchLayer.edgeY - 1 }
          }
          // Bridge: same notch plus the two rounded window corners and the gap.
          ShapePath {
            startX: notchLayer.fxL; startY: notchLayer.edgeY
            PathArc { x: notchLayer.tx(-1, 0); y: notchLayer.ty(0); radiusX: notchLayer.r; radiusY: notchLayer.r; direction: PathArc.Clockwise }
            PathArc { x: notchLayer.cxL; y: notchLayer.yb; radiusX: notchLayer.big; radiusY: notchLayer.big; direction: PathArc.Counterclockwise }
            PathLine { x: notchLayer.eL - notchLayer.rcL; y: notchLayer.yb }
            PathArc { x: notchLayer.eL; y: notchLayer.yb + notchLayer.rcL; radiusX: notchLayer.rcL; radiusY: notchLayer.rcL; direction: PathArc.Clockwise }
            strokeWidth: -1
            fillColor: notchLayer.bridge ? "black" : "transparent"
            PathLine { x: notchLayer.eR; y: notchLayer.yb + notchLayer.rcR }
            PathArc { x: notchLayer.eR + notchLayer.rcR; y: notchLayer.yb; radiusX: notchLayer.rcR; radiusY: notchLayer.rcR; direction: PathArc.Clockwise }
            PathLine { x: notchLayer.cxR; y: notchLayer.yb }
            PathArc { x: notchLayer.tx(1, 0); y: notchLayer.ty(0); radiusX: notchLayer.big; radiusY: notchLayer.big; direction: PathArc.Counterclockwise }
            PathArc { x: notchLayer.fxR; y: notchLayer.edgeY; radiusX: notchLayer.r; radiusY: notchLayer.r; direction: PathArc.Clockwise }
            PathLine { x: notchLayer.fxR; y: notchLayer.edgeY - 1 }
            PathLine { x: notchLayer.fxL; y: notchLayer.edgeY - 1 }
          }
        }
        MultiEffect {
          anchors.fill: parent
          source: wallStrip
          maskEnabled: true
          maskSource: notchMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
        }
        // Bridge: two separate borders, one per window.
        Shape {
          anchors.fill: parent
          visible: notchLayer.bridge
          preferredRendererType: Shape.CurveRenderer
          // Left window: around the pill, then down its own side.
          ShapePath {
            strokeWidth: 2; strokeColor: win.focusedEdge(true) ? root.borderColor : root.inactiveBorderColor; fillColor: "transparent"; capStyle: ShapePath.FlatCap
            startX: notchLayer.fxL; startY: notchLayer.edgeY + 1
            PathArc { x: notchLayer.tx(-1, 1); y: notchLayer.ty(1); radiusX: notchLayer.r - 1; radiusY: notchLayer.r - 1; direction: PathArc.Clockwise }
            PathArc { x: notchLayer.cxL; y: notchLayer.yb + 1; radiusX: notchLayer.big + 1; radiusY: notchLayer.big + 1; direction: PathArc.Counterclockwise }
            PathLine { x: notchLayer.eL - notchLayer.rcL; y: notchLayer.yb + 1 }
            PathArc { x: notchLayer.eL - 1; y: notchLayer.yb + notchLayer.rcL; radiusX: Math.max(0.5, notchLayer.rcL - 1); radiusY: Math.max(0.5, notchLayer.rcL - 1); direction: PathArc.Clockwise }
          }
          // Right window: up its own side, around the pill, back to the top border.
          ShapePath {
            strokeWidth: 2; strokeColor: win.focusedEdge(false) ? root.borderColor : root.inactiveBorderColor; fillColor: "transparent"; capStyle: ShapePath.FlatCap
            startX: notchLayer.eR + 1; startY: notchLayer.yb + notchLayer.rcR
            PathArc { x: notchLayer.eR + notchLayer.rcR; y: notchLayer.yb + 1; radiusX: Math.max(0.5, notchLayer.rcR - 1); radiusY: Math.max(0.5, notchLayer.rcR - 1); direction: PathArc.Clockwise }
            PathLine { x: notchLayer.cxR; y: notchLayer.yb + 1 }
            PathArc { x: notchLayer.tx(1, 1); y: notchLayer.ty(1); radiusX: notchLayer.big + 1; radiusY: notchLayer.big + 1; direction: PathArc.Counterclockwise }
            PathArc { x: notchLayer.fxR; y: notchLayer.edgeY + 1; radiusX: notchLayer.r - 1; radiusY: notchLayer.r - 1; direction: PathArc.Clockwise }
          }
        }
        // The Hyprland border continues along the notch.
        Shape {
          anchors.fill: parent
          visible: !notchLayer.bridge
          preferredRendererType: Shape.CurveRenderer
          NotchPath {
            o: 1
            strokeWidth: 2
            strokeColor: win.centerFocused ? root.borderColor : root.inactiveBorderColor
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap
          }
        }
      }

      // At a corner the window border follows only the island's two exposed
      // edges. Mirror the same path for the other three corners.
      Item {
        id: cornerOutline
        x: 0; y: root.bottomEdge ? win.height - height : 0
        width: win.width; height: 90
        visible: root.atCorner && win.notchDrawn
        transform: Scale { origin.x: cornerOutline.width / 2; origin.y: cornerOutline.height / 2; xScale: root.atRight ? -1 : 1; yScale: root.bottomEdge ? -1 : 1 }
        // Put the stroke directly against the visible pill. The opaque fill
        // covers the window's original border beneath the replacement outline.
        readonly property real outerW: pill.width * pill.scale + 0.5
        readonly property real outerH: pill.height * pill.scale + 0.5
        readonly property real edge: root.gapsOut
        readonly property real curve: Math.max(2, Math.min(12, (outerH - edge) / 2))
        readonly property real innerCurve: Math.min(pill.radius * pill.scale, outerH - edge)
        Shape {
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          // Fill the area behind the island and its corner joins, hiding the
          // compositor's original window border before drawing the new one.
          ShapePath {
            strokeWidth: -1
            fillColor: root.pillColor
            startX: cornerOutline.outerW + cornerOutline.curve; startY: cornerOutline.edge
            PathQuad { x: cornerOutline.outerW; y: cornerOutline.edge + cornerOutline.curve; controlX: cornerOutline.outerW; controlY: cornerOutline.edge }
            PathLine { x: cornerOutline.outerW; y: cornerOutline.outerH - cornerOutline.innerCurve }
            PathQuad { x: cornerOutline.outerW - cornerOutline.innerCurve; y: cornerOutline.outerH; controlX: cornerOutline.outerW; controlY: cornerOutline.outerH }
            PathLine { x: cornerOutline.edge + cornerOutline.curve; y: cornerOutline.outerH }
            PathQuad { x: cornerOutline.edge; y: cornerOutline.outerH + cornerOutline.curve; controlX: cornerOutline.edge; controlY: cornerOutline.outerH }
            PathLine { x: 0; y: cornerOutline.outerH + cornerOutline.curve }
            PathLine { x: 0; y: 0 }
            PathLine { x: cornerOutline.outerW + cornerOutline.curve; y: 0 }
          }
          ShapePath {
            strokeWidth: 2
            strokeColor: win.centerFocused ? root.borderColor : root.inactiveBorderColor
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap
            startX: cornerOutline.outerW + cornerOutline.curve; startY: cornerOutline.edge
            PathQuad { x: cornerOutline.outerW; y: cornerOutline.edge + cornerOutline.curve; controlX: cornerOutline.outerW; controlY: cornerOutline.edge }
            PathLine { x: cornerOutline.outerW; y: cornerOutline.outerH - cornerOutline.innerCurve }
            PathQuad { x: cornerOutline.outerW - cornerOutline.innerCurve; y: cornerOutline.outerH; controlX: cornerOutline.outerW; controlY: cornerOutline.outerH }
            PathLine { x: cornerOutline.edge + cornerOutline.curve; y: cornerOutline.outerH }
            PathQuad { x: cornerOutline.edge; y: cornerOutline.outerH + cornerOutline.curve; controlX: cornerOutline.edge; controlY: cornerOutline.outerH }
          }
        }
      }

      Rectangle {
        id: pill
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: win.pillCenter - win.width / 2 + root.shakeX
        // With the notch the pill gets smaller and moves up: it covers less of the page.
        y: root.bottomEdge ? win.height - height - (root.atCorner ? 0 : (win.notch ? win.notchTop : root.pillTop)) : (root.atCorner ? 0 : (win.notch ? win.notchTop : root.pillTop))
        transformOrigin: root.atCorner ? (root.bottomEdge ? (root.atRight ? Item.BottomRight : Item.BottomLeft) : (root.atRight ? Item.TopRight : Item.TopLeft)) : (root.bottomEdge ? Item.Bottom : Item.Top)
        scale: (win.notch ? win.notchScale : 1) * root.gulp
        Behavior on y { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on scale { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        // Reveal from hiding (win.reveal): squeezed against the top edge, then
        // drops and widens into place.
        transform: [
          Scale {
            origin.x: pill.width / 2
            origin.y: root.bottomEdge ? pill.height : 0
            xScale: 0.55 + 0.45 * win.reveal
            yScale: 0.25 + 0.75 * win.reveal
          },
          Translate { y: (root.bottomEdge ? 1 : -1) * (1 - win.reveal) * (root.pillTop + 14) }
        ]
        width: win.targetSize.width
        height: win.targetSize.height
        radius: Math.min(win.targetRadius, height / 2)
        topLeftRadius: root.atCorner && !(root.bottomEdge && root.atRight) ? 0 : radius
        topRightRadius: root.atCorner && !(root.bottomEdge && !root.atRight) ? 0 : radius
        bottomLeftRadius: root.atCorner && !(!root.bottomEdge && root.atRight) ? 0 : radius
        bottomRightRadius: root.atCorner && !(!root.bottomEdge && !root.atRight) ? 0 : radius
        color: root.pillColor
        clip: true
        antialiasing: true
        // With the menu open the pill "lends" itself to the menu, which starts from the same shape.
        opacity: (root.mode === "menu" ? 0 : 1) * Math.min(1, win.revealT * 1.6)
        Behavior on opacity { enabled: root.animate && win.revealT >= 1; NumberAnimation { duration: root.mode === "menu" ? 90 : 0 } }

        Behavior on width  { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on height { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on radius { enabled: root.animate; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        HoverHandler {
          onHoveredChanged: {
            root.wsHovered = hovered
            root.pillHovered = hovered
            if (hovered) { playerLeaveTimer.stop(); playerHoverTimer.restart() }
            else { playerHoverTimer.stop(); if (root.playerOpen) playerLeaveTimer.restart() }
            if (hovered) collapseTimer.stop()
            else if (root.pinned || root.centerOpen) collapseTimer.restart()
            if (hovered) { shelfLeave.stop(); shelfIdle.stop() }
            else if (root.shelfOpen) shelfLeave.restart()
          }
        }
        // The dashboard closes on its own when the mouse leaves.
        Timer { id: collapseTimer; interval: 450; onTriggered: { root.pinned = false; root.centerOpen = false } }

        TapHandler {
          // Click on the idle pill: opens the dashboard. On the OSD: closes it.
          acceptedButtons: Qt.LeftButton
          enabled: root.mode === "idle" || root.mode === "osd" || root.mode === "ws" || root.mode === "player" || root.mode === "quick"
          onTapped: {
            if (root.mode === "osd") { osd.active = false; return }
            root.playerOpen = false
            root.pinned = true
          }
        }
        // Middle click: play/pause (if nothing is playing, the pill says "no").
        TapHandler {
          acceptedButtons: Qt.MiddleButton
          onTapped: {
            const p = root.player
            if (p && p.canTogglePlaying) p.togglePlaying()
            else root.shake()
          }
        }
        // Files dragged onto the pill: open the shelf.
        DropArea {
          anchors.fill: parent
          enabled: !root.shelfDragging && root.hasOmadrop
          onEntered: function(drag) {
            if (!drag.hasUrls) return
            drag.accept(Qt.CopyAction)
            root.dropHover = true
          }
          onExited: root.dropHover = false
          onDropped: function(drop) {
            root.dropHover = false
            if (!drop.hasUrls) return
            const uris = []
            for (let i = 0; i < drop.urls.length; i++) uris.push(String(drop.urls[i]))
            if (!uris.length) return
            drop.accept(Qt.CopyAction)
            root.omadrop(["add", uris.join("\n")])
            root.openShelf()
          }
        }

        // ── Idle: just the clock, perfectly centered ────────────────────────
        // Whatever is active becomes two "ears" on the sides, always equally wide
        // so the clock stays centered: music and recording on the left,
        // equalizer, caffeine, do not disturb, notifications, battery on the right.
        Row {
          id: idleRow
          anchors.centerIn: parent
          spacing: 0
          opacity: root.mode === "idle" ? 1 : 0
          visible: opacity > 0 && win.calm
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn1; enabled: root.animate; NumberAnimation { duration: fadeIn1.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn1.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "idle" ? 1 : 0.92
          Behavior on scale { id: grow1; enabled: root.animate; NumberAnimation { duration: grow1.targetValue > 0.96 ? 420 : 120; easing.type: grow1.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }

          // Ears are never hidden: an invisible container makes its children
          // invisible too, and the Row would measure them as zero forever.
          // Each ear takes only its own space: the pill hugs the content with
          // equal margins (no empty gap on the side with nothing).
          readonly property real sideWidth: Math.max(leftEar.implicitWidth, rightEar.implicitWidth)
          // When the last child disappears the Row keeps its old width: we decide
          // whether the ear is there, so the pill shrinks back and the clock
          // returns to the center (e.g. the charger is unplugged).
          // With the notch (browser only) the pill is small: only the clock and a
          // possible bolt remain, everything else waits until you leave the browser.
          readonly property bool slim: win.notch
          readonly property bool leftOn: !slim && (!!root.player || root.recording || root.reminderText !== "")
          readonly property bool rightOn: (root.charging && root.batPct < 0.99) || (!slim && (!!root.player || root.micInUse || root.camInUse))
          readonly property real leftWidth: leftOn && leftEar.implicitWidth > 0 ? leftEar.implicitWidth + 9 : 0
          readonly property real rightWidth: rightOn && rightEar.implicitWidth > 0 ? rightEar.implicitWidth + 9 : 0

          Item {
            width: idleRow.leftWidth
            height: root.idleHeight
            Row {
              id: leftEar
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: 8
              // Room for the cover art (or the app icon): heroArt draws it.
              Item {
                id: miniArt
                visible: !!root.player && !idleRow.slim
                anchors.verticalCenter: parent.verticalCenter
                width: 18; height: 18
              }
              // Recording: pulsing red dot + elapsed time. Click = stop.
              Row {
                visible: root.recording && !idleRow.slim
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: 8; height: 8; radius: 4
                  color: root.red
                  SequentialAnimation on opacity {
                    running: root.recording
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 700 }
                    NumberAnimation { to: 1; duration: 700 }
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.recElapsed
                  color: root.red
                  font.family: root.textFont
                  font.pixelSize: 12
                  font.weight: Font.DemiBold
                  font.features: { "tnum": 1 }
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: root.toggleRecording() }
              }
              // Next reminder / timer
              Row {
                visible: root.reminderText !== "" && !idleRow.slim
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰔟"
                  color: root.accent
                  font.family: root.glyphFont
                  font.pixelSize: 13
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.reminderText
                  color: root.accent
                  font.family: root.textFont
                  font.pixelSize: 12
                  font.weight: Font.DemiBold
                  font.features: { "tnum": 1 }
                }
              }
            }
          }

          // Placeholder: the real clock is heroClock, which travels to the dashboard.
          Text {
            id: idleTime
            anchors.verticalCenter: parent.verticalCenter
            opacity: 0
            text: root.timeText
            font.family: root.displayFont
            font.pixelSize: 14
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
          }

          Item {
            width: idleRow.rightWidth
            height: root.idleHeight
            Row {
              id: rightEar
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 9
              // Charging: a green bolt next to the clock.
              Text {
                visible: root.charging && root.batPct < 0.99
                anchors.verticalCenter: parent.verticalCenter
                text: "󱐋"
                color: root.green
                font.family: root.glyphFont
                font.pixelSize: 14
              }
              Equalizer {
                visible: !!root.player && !idleRow.slim
                anchors.verticalCenter: parent.verticalCenter
                playing: root.playing
                barColor: root.accent
              }
              // Privacy: orange = microphone, green = webcam
              Row {
                visible: (root.micInUse || root.camInUse) && !idleRow.slim
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Rectangle { visible: root.camInUse; width: 7; height: 7; radius: 3.5; color: "#30d158"; anchors.verticalCenter: parent.verticalCenter }
                Rectangle { visible: root.micInUse; width: 7; height: 7; radius: 3.5; color: "#ff9f0a"; anchors.verticalCenter: parent.verticalCenter }
              }
            }
          }
        }

        // ── Workspace change: the island briefly shows the dots ─────────────
        Row {
          id: wsRow
          anchors.centerIn: parent
          spacing: 7
          opacity: root.mode === "ws" ? 1 : 0
          visible: opacity > 0 && win.calm
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn2; enabled: root.animate; NumberAnimation { duration: fadeIn2.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn2.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "ws" ? 1 : 0.92
          Behavior on scale { id: grow2; enabled: root.animate; NumberAnimation { duration: grow2.targetValue > 0.96 ? 420 : 120; easing.type: grow2.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }
          Repeater {
            model: root.workspaces
            Rectangle {
              required property var modelData
              readonly property bool current: modelData.id === root.activeWs
              anchors.verticalCenter: parent.verticalCenter
              width: current ? 24 : 8
              height: 8
              radius: 4
              color: current ? root.accent : wsHover.hovered ? Qt.alpha(root.textColor, 0.8) : Qt.alpha(root.textColor, 0.35)
              Behavior on width { enabled: root.animate; NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
              Behavior on color { enabled: root.animate; ColorAnimation { duration: 180 } }
              HoverHandler { id: wsHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: Hyprland.dispatch("workspace " + modelData.id) }
            }
          }
        }

        // ── Dashboard ───────────────────────────────────────────────────────
        Column {
          id: dash
          anchors.top: parent.top
          anchors.topMargin: 18
          anchors.horizontalCenter: parent.horizontalCenter
          width: 480 - 36
          spacing: 16
          opacity: root.mode === "dash" ? 1 : 0
          visible: opacity > 0
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn3; enabled: root.animate; NumberAnimation { duration: fadeIn3.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn3.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "dash" ? 1 : 0.92
          Behavior on scale { id: grow3; enabled: root.animate; NumberAnimation { duration: grow3.targetValue > 0.96 ? 420 : 120; easing.type: grow3.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }

          // Time, date and quick status
          Item {
            id: dashHeader
            width: parent.width
            height: 46
            Column {
              id: dashHeaderCol
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              Text {
                // Placeholder: heroClock lands here.
                opacity: 0
                text: root.timeText
                color: root.textColor
                font.family: root.displayFont
                font.pixelSize: 30
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
              }
              Text {
                text: root.dateText
                color: root.subColor
                font.family: root.textFont
                font.pixelSize: 12
                font.weight: Font.Medium
              }
            }
            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 6
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.hasBattery
                text: Math.round(root.batPct * 100) + "%"
                color: root.subColor
                font.family: root.textFont
                font.pixelSize: 12
                font.weight: Font.Medium
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.hasBattery
                text: root.batGlyph
                color: root.batColor
                font.family: root.glyphFont
                font.pixelSize: 16
              }
            }
          }

          // Control Center
          ControlCenter {
            id: cc
            width: parent.width
            plugins: root.plugins
            active: root.mode === "dash"
            player: root.player
            wifiOn: Networking.wifiEnabled && (!!root.wifiNet || root.wiredUp)
            wifiName: root.demo && root.wifiNet ? "Home" : root.wifiNet ? (root.wifiNet.name || "") : (root.wiredUp ? "Ethernet" : "")
            btOn: !!root.btAdapter && root.btAdapter.enabled
            btDevice: root.demo && root.btDeviceName ? "Headphones" : root.btDeviceName
            stayAwake: root.stayAwake
            dnd: root.dnd
            recording: root.recording
            recElapsed: root.recElapsed
            volume: root.volume
            muted: root.muted
            accent: root.accent
            textColor: root.textColor
            subColor: root.subColor
            red: root.red
            textFont: root.textFont
            displayFont: root.displayFont
            glyphFont: root.glyphFont
            onToggleWifi: Networking.wifiEnabled = !Networking.wifiEnabled
            onToggleBt: if (root.btAdapter) Quickshell.execDetached(["omarchy-bluetooth-power", root.btAdapter.enabled ? "off" : "on"])
            onToggleCaffeine: root.toggleCaffeine()
            onToggleDnd: root.toggleDnd()
            onOpenPanel: function(id) { root.openPanel(id) }
            onSetVolume: function(v) { if (root.sink && root.sink.audio) { root.sink.audio.muted = false; root.sink.audio.volume = v } }
            onAction: function(act) {
              if (act === "shot") root.run(["omarchy", "capture", "screenshot"])
              else if (act === "record") root.toggleRecording()
              else if (act === "center") { root.pinned = false; root.centerOpen = true }
              else if (act === "update") root.run(["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"])
              else if (act === "lock") root.run(["omarchy", "system", "lock"])
            }
          }
        }

        // ── Elements that travel between pill and dashboard ─────────────────
        // Positions are computed on screen (start and end) and interpolated
        // with root.dashT: a straight path, independent of how the pill
        // deforms with its spring.
        Text {
          id: heroClock
          readonly property real s0: 14 / 30
          readonly property real sq: 20 / 30
          // Idle, dashboard and quick actions: it's always the same clock moving
          // and growing, never one fading out while another appears.
          readonly property bool shown: root.mode === "idle" || root.mode === "dash" || root.mode === "quick"
          text: root.timeText
          color: root.textColor
          font.family: root.displayFont
          font.pixelSize: 30
          font.weight: Font.Bold
          font.features: { "tnum": 1 }
          transformOrigin: Item.TopLeft
          // Animate offsets from the pill's center. Its center moves on every
          // frame in a corner, so animating screen coordinates chases a moving
          // target and makes the clock lag or jump during the resize.
          readonly property real ax: -idleRow.implicitWidth / 2 + idleTime.x + (idleTime.width - implicitWidth * s0) / 2
          readonly property real ay: (root.idleHeight - implicitHeight * s0) / 2
          readonly property real bx: -480 / 2 + 18 + dashHeaderCol.x
          readonly property real by: 18 + dashHeaderCol.y
          readonly property real qx: -quickFull.implicitWidth / 2 + quickFull.clockX - (implicitWidth * sq - quickFull.clockW) / 2
          readonly property real qy: (60 - implicitHeight * sq) / 2
          readonly property string spot: root.mode === "dash" ? "dash" : root.mode === "quick" ? "quick" : "idle"
          property real wx: spot === "dash" ? bx : spot === "quick" ? qx : ax
          property real wy: spot === "dash" ? by : spot === "quick" ? qy : ay
          property real sc: spot === "dash" ? 1 : spot === "quick" ? sq : s0
          Behavior on wx { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          Behavior on wy { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          Behavior on sc { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          scale: sc
          x: pill.width / 2 + wx
          y: wy
          opacity: shown ? 1 : 0
          visible: opacity > 0 && (win.calm || spot !== "idle")
          // Leaves immediately (must not pass over the incoming text), returns smoothly.
          Behavior on opacity { id: clockFade; enabled: root.animate; NumberAnimation { duration: clockFade.targetValue > 0.5 ? 220 : 60 } }
        }

        // Cover art that travels between the pill (left ear), the compact player
        // (circle on the left) and the dashboard (large square). If the music
        // comes from the web without cover art, the app icon is shown instead.
        Item {
          id: heroArt
          readonly property bool shown: !!root.player
                                        && ((root.mode === "idle" && !win.notch) || root.mode === "dash" || root.mode === "player")
          readonly property bool hasArt: heroArtImg.status === Image.Ready
          readonly property string appIcon: {
            const p = root.player
            if (!p) return ""
            const e = p.desktopEntry ? DesktopEntries.byId(p.desktopEntry) : null
            return Quickshell.iconPath((e && e.icon) || p.desktopEntry || "", true)
          }
          // Offsets from the moving pill center, as with the clock above.
          readonly property real tx: root.mode === "dash" ? -480 / 2 + 18 + cc.x + cc.artX
                                   : root.mode === "player" ? -(420 + 112) / 2 + 8
                                   : -idleRow.implicitWidth / 2
          readonly property real ty: root.mode === "dash" ? 18 + cc.y + cc.artY
                                   : root.mode === "player" ? 8
                                   : (root.idleHeight - 18) / 2
          readonly property real tsize: root.mode === "dash" ? cc.artSize : root.mode === "player" ? 60 : 18
          readonly property real tradius: root.mode === "dash" ? 14 : tsize / 2
          property real wx: tx
          property real wy: ty
          property real size: tsize
          property real rad: tradius
          Behavior on wx { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          Behavior on wy { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          Behavior on size { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          Behavior on rad { enabled: root.animate; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
          x: pill.width / 2 + wx
          y: wy
          width: size; height: size
          opacity: shown ? 1 : 0
          visible: opacity > 0
          Behavior on opacity { enabled: root.animate; NumberAnimation { duration: 150 } }

          Image {
            id: heroArtImg
            anchors.fill: parent
            source: root.player ? (root.player.trackArtUrl || "") : ""
            sourceSize: Qt.size(168, 168)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: false
          }
          Rectangle {
            id: heroArtMask
            anchors.fill: parent
            radius: heroArt.rad
            visible: false
            layer.enabled: true
          }
          MultiEffect {
            anchors.fill: parent
            visible: heroArt.hasArt
            source: heroArtImg
            maskEnabled: true
            maskSource: heroArtMask
          }
          // No cover art (YouTube & co.): the app icon in a circle.
          Rectangle {
            anchors.fill: parent
            visible: !heroArt.hasArt
            radius: heroArt.rad
            color: Qt.alpha(root.textColor, 0.1)
            Image {
              id: heroAppIcon
              anchors.centerIn: parent
              width: parent.width * 0.62; height: width
              source: heroArt.appIcon
              sourceSize: Qt.size(128, 128)
              fillMode: Image.PreserveAspectFit
              visible: status === Image.Ready
            }
            Text {
              anchors.centerIn: parent
              visible: heroAppIcon.status !== Image.Ready
              text: "󰝚"
              color: root.accent
              font.family: root.glyphFont
              font.pixelSize: parent.width * 0.45
            }
          }
        }

        // ── Scroll wheel: volume; with Shift, brightness ───────────────────
        // Sits above all content: otherwise the quick action buttons (which open
        // on hover) would swallow the scroll.
        // Not in views that scroll or have their own sliders.
        Item {
          anchors.fill: parent
          z: 100
          WheelHandler {
            enabled: !["dash", "center", "shelf", "menu"].includes(root.mode)
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            property real acc: 0
            onWheel: function(ev) {
              // Wheel: angleDelta in steps of 120. Trackpad: often only pixelDelta.
              let d = ev.angleDelta.y !== 0 ? ev.angleDelta.y : ev.angleDelta.x
              if (d === 0) d = (ev.pixelDelta.y !== 0 ? ev.pixelDelta.y : ev.pixelDelta.x) * 4
              if (ev.inverted) d = -d
              acc += d
              if (Math.abs(acc) < 60) return
              const up = acc > 0
              acc = 0
              if (ev.modifiers & Qt.ShiftModifier) {
                Quickshell.execDetached(["omarchy-brightness-display", up ? "+5%" : "5%-"])
                return
              }
              if ((up && root.volume >= 0.995 && !root.muted) || (!up && (root.volume <= 0.005 || root.muted))) root.shake()
              Quickshell.execDetached(["omarchy-audio-output-volume", up ? "raise" : "lower"])
            }
          }
        }

        // ── Shelf ───────────────────────────────────────────────────────────
        ShelfView {
          anchors.centerIn: parent
          width: 410; height: 84
          items: root.shelfItems
          hovering: root.dropHover
          accent: root.accent
          textColor: root.textColor
          subColor: root.subColor
          pillColor: root.pillColor
          textFont: root.textFont
          glyphFont: root.glyphFont
          opacity: root.mode === "shelf" ? 1 : 0
          visible: opacity > 0
          enabled: root.mode === "shelf"
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn4; enabled: root.animate; NumberAnimation { duration: fadeIn4.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn4.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "shelf" ? 1 : 0.92
          Behavior on scale { id: grow4; enabled: root.animate; NumberAnimation { duration: grow4.targetValue > 0.96 ? 420 : 120; easing.type: grow4.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }
          onDragBegan: root.shelfDragging = true
          // Delivered: in Omadrop's history, and the shelf is empty.
          onDragEnded: { root.shelfDragging = false; root.shelfOpen = false; root.omadrop(["delivered"]) }
          onOpenOmadrop: { root.shelfOpen = false; root.omadrop(["open"]) }
          onClearAll: root.omadrop(["clear"])
        }

        // ── Compact player ──────────────────────────────────────────────────
        PlayerPill {
          anchors.centerIn: parent
          anchors.horizontalCenterOffset: (8 - 112) / 2
          width: 420 + 112 - 8 - 112
          height: 76
          player: root.player
          accent: root.accent
          textColor: root.textColor
          subColor: root.subColor
          textFont: root.textFont
          glyphFont: root.glyphFont
          opacity: root.mode === "player" ? 1 : 0
          visible: opacity > 0
          enabled: root.mode === "player"
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn5; enabled: root.animate; NumberAnimation { duration: fadeIn5.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn5.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "player" ? 1 : 0.92
          Behavior on scale { id: grow5; enabled: root.animate; NumberAnimation { duration: grow5.targetValue > 0.96 ? 420 : 120; easing.type: grow5.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }
        }

        // Quick actions: next to the player (battery + screenshot) or on their own.
        QuickActions {
          compact: true
          anchors.right: parent.right
          anchors.rightMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          opacity: root.mode === "player" ? 1 : 0
          visible: opacity > 0
          enabled: root.mode === "player"
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn6; enabled: root.animate; NumberAnimation { duration: fadeIn6.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn6.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "player" ? 1 : 0.92
          Behavior on scale { id: grow6; enabled: root.animate; NumberAnimation { duration: grow6.targetValue > 0.96 ? 420 : 120; easing.type: grow6.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }
          pct: root.batPct; charging: root.charging; hasBattery: root.hasBattery
          stayAwake: root.stayAwake; dnd: root.dnd
          accent: root.accent; textColor: root.textColor; red: root.red; green: root.green
          textFont: root.textFont; glyphFont: root.glyphFont
          onScreenshot: root.later(["omarchy", "capture", "screenshot"])
          onBattery: root.openPanel("omarchy.power")
          onExpand: { root.playerOpen = false; root.pinned = true }
        }
        QuickActions {
          id: quickFull
          clockHidden: true
          satellitesDock: true
          timeText: root.timeText
          displayFont: root.displayFont
          anchors.centerIn: parent
          opacity: root.mode === "quick" ? 1 : 0
          visible: opacity > 0
          enabled: root.mode === "quick"
          Behavior on opacity { id: fadeIn7; enabled: root.animate; NumberAnimation { duration: fadeIn7.targetValue > 0.5 ? 180 : 120; easing.type: Easing.OutCubic } }
          pct: root.batPct; charging: root.charging; hasBattery: root.hasBattery
          stayAwake: root.stayAwake; dnd: root.dnd
          accent: root.accent; textColor: root.textColor; red: root.red; green: root.green
          textFont: root.textFont; glyphFont: root.glyphFont
          onScreenshot: root.later(["omarchy", "capture", "screenshot"])
          onCaffeine: root.toggleCaffeine()
          onDndToggle: root.toggleDnd()
          onLock: root.later(["omarchy", "system", "lock"])
          onBattery: root.openPanel("omarchy.power")
          onExpand: { root.playerOpen = false; root.pinned = true }
        }

        // ── Live activities: charging / low battery ─────────────────────────
        Item {
          anchors.centerIn: parent
          anchors.horizontalCenterOffset: (16 - 18) / 2
          width: 300 - 34
          height: 44
          opacity: root.mode === "live" ? 1 : 0
          visible: opacity > 0
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn8; enabled: root.animate; NumberAnimation { duration: fadeIn8.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn8.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "live" ? 1 : 0.92
          Behavior on scale { id: grow8; enabled: root.animate; NumberAnimation { duration: grow8.targetValue > 0.96 ? 420 : 120; easing.type: grow8.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }
          readonly property color tint: root.liveKind === "low" ? root.red : root.green
          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.liveKind === "low" ? "󰂃" : "󰂄"
              color: parent.parent.tint
              font.family: root.glyphFont
              font.pixelSize: 18
              SequentialAnimation on opacity {
                running: root.mode === "live"
                loops: Animation.Infinite
                NumberAnimation { to: 0.45; duration: 650 }
                NumberAnimation { to: 1; duration: 650 }
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.liveKind === "low" ? I18n.t("batteryLow") : I18n.t("charging")
              color: root.textColor
              font.family: root.textFont
              font.pixelSize: 13
              font.weight: Font.DemiBold
            }
          }
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: Math.round(root.batPct * 100) + "%"
            color: parent.tint
            font.family: root.displayFont
            font.pixelSize: 18
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
          }
        }

        // ── Notification center ─────────────────────────────────────────────
        NotificationCenter {
          id: centerView
          anchors.top: parent.top
          anchors.topMargin: 18
          anchors.horizontalCenter: parent.horizontalCenter
          width: 460 - 36
          active: root.mode === "center"
          dnd: root.dnd
          accent: root.accent
          textColor: root.textColor
          subColor: root.subColor
          red: root.red
          textFont: root.textFont
          displayFont: root.displayFont
          glyphFont: root.glyphFont
          opacity: root.mode === "center" ? 1 : 0
          visible: opacity > 0
          enabled: root.mode === "center"
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn9; enabled: root.animate; NumberAnimation { duration: fadeIn9.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn9.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "center" ? 1 : 0.92
          Behavior on scale { id: grow9; enabled: root.animate; NumberAnimation { duration: grow9.targetValue > 0.96 ? 420 : 120; easing.type: grow9.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }
          onToggleDnd: root.toggleDnd()
        }

        // ── OSD ─────────────────────────────────────────────────────────────
        Row {
          anchors.centerIn: parent
          spacing: 12
          opacity: root.mode === "osd" ? 1 : 0
          visible: opacity > 0
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn10; enabled: root.animate; NumberAnimation { duration: fadeIn10.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn10.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "osd" ? 1 : 0.92
          Behavior on scale { id: grow10; enabled: root.animate; NumberAnimation { duration: grow10.targetValue > 0.96 ? 420 : 120; easing.type: grow10.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            horizontalAlignment: Text.AlignHCenter
            text: osd.icon
            color: root.textColor
            font.family: root.glyphFont
            font.pixelSize: 17
          }
          Rectangle {
            visible: osd.hasProgress
            anchors.verticalCenter: parent.verticalCenter
            width: 180; height: 6; radius: 3
            color: Qt.alpha(root.textColor, 0.16)
            Rectangle {
              height: parent.height; radius: parent.radius
              width: parent.width * Math.max(0, Math.min(1, osd.value / osd.max))
              color: root.accent
              Behavior on width { enabled: root.animate; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: osd.hasProgress ? 38 : implicitWidth
            horizontalAlignment: osd.hasProgress ? Text.AlignRight : Text.AlignLeft
            text: osd.message
            textFormat: Text.PlainText
            color: root.textColor
            font.family: root.textFont
            font.pixelSize: 13
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
          }
        }

        // ── Notification ────────────────────────────────────────────────────
        NotificationView {
          id: notifView
          thumbHidden: root.shotFlying
          anchors.fill: parent
          anchors.margins: 8
          anchors.rightMargin: 16
          info: notif
          deeds: notif.deeds
          more: root.notifMore
          accent: root.accent
          textColor: root.textColor
          subColor: root.subColor
          textFont: root.textFont
          glyphFont: root.glyphFont
          opacity: root.mode === "notify" ? 1 : 0
          visible: opacity > 0
          enabled: root.mode === "notify"
          // Transition: outgoing content vanishes and shrinks at once; incoming
          // content waits for the pill to start reshaping, then springs in.
          Behavior on opacity { id: fadeIn11; enabled: root.animate; NumberAnimation { duration: fadeIn11.targetValue > 0.5 ? 300 : 90; easing.type: fadeIn11.targetValue > 0.5 ? Easing.InOutCubic : Easing.OutQuad } }
          scale: root.mode === "notify" ? 1 : 0.92
          Behavior on scale { id: grow11; enabled: root.animate; NumberAnimation { duration: grow11.targetValue > 0.96 ? 420 : 120; easing.type: grow11.targetValue > 0.96 ? Easing.OutBack : Easing.InQuad; easing.overshoot: 1.3 } }
          onHoveredChanged: root.notifHovered = hovered
          // While you hold or drag the screenshot the notification doesn't expire;
          // once released the countdown restarts.
          onHoldingChanged: holding ? notifTimer.stop() : notifTimer.restart()
          onOpened: root.notifCall("islandOpen")
          onClosed: root.notifCall("islandClose")
          onDeedClicked: function(index) { root.notifCall("islandRun", [String(index)]) }
        }
      }
    }
  }

  // ── Screenshot flying into the island ─────────────────────────────────────
  // White flash, then the image (fullscreen for a full screenshot, centered
  // at its own size for an area) shrinks down to the notification
  // thumbnail. The target is computed by the island (thumbRect).
  // Declared after the island: its surface is created later and sits on top.
  property string shotPath: ""
  property bool shotFlying: false     // the real thumbnail waits for the landing
  // "Swallows" the screenshot: the pill swells slightly and springs back.
  property real gulp: 1
  SequentialAnimation {
    id: gulpAnim
    NumberAnimation { target: root; property: "gulp"; to: 1.07; duration: 90; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "gulp"; to: 1; duration: 380; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
  }
  // If the flight doesn't start (unreadable image, no active screen) the
  // thumbnail must not stay hidden.
  Timer { id: shotSafety; interval: 2500; onTriggered: { root.shotFlying = false; root.shotPath = "" } }
  readonly property string shotSound: Qt.resolvedUrl("sounds/shot.wav").toString().replace("file://", "")
  property rect shotTarget: Qt.rect(0, 0, 80, 50)
  property real shotTargetRadius: 25
  function flyShot(path) {
    // The "blop" even without animations.
    Quickshell.execDetached(["pw-play", "--volume=0.55", root.shotSound])
    if (!root.animate) return
    root.shotFlying = true
    shotSafety.restart()
    root.shotPath = ""
    root.shotPath = path
  }
  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: shotWin
      required property var modelData
      screen: modelData
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      readonly property bool here: !!hyprMonitor && hyprMonitor.focused
      visible: root.shotPath !== "" && here
      anchors { top: true; left: true; right: true; bottom: true }
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"
      mask: Region {}
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "island-shot"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Rectangle { id: flash; anchors.fill: parent; color: "white"; opacity: 0 }

      RectangularShadow {
        anchors.fill: fly
        radius: fly.radius
        blur: 30; offset.y: 8
        opacity: fly.opacity * 0.9
        color: Qt.rgba(0, 0, 0, 0.45)
      }
      ClippingRectangle {
        id: fly
        opacity: 0
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.18)
        Image {
          id: flyImg
          anchors.fill: parent
          source: shotWin.visible ? "file://" + root.shotPath : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          onStatusChanged: {
            if (status === Image.Ready && shotWin.visible) shotWin.launch()
            else if (status === Image.Error) { root.shotPath = ""; root.shotFlying = false }
          }
        }
      }
      property real liftX: 0
      property real liftY: 0
      property real liftW: 0
      property real liftH: 0
      function launch() {
        const dpr = shotWin.modelData.devicePixelRatio || 1
        const W = shotWin.width, H = shotWin.height
        let w = flyImg.implicitWidth / dpr, h = flyImg.implicitHeight / dpr
        const k = Math.min(1, W / w, H / h)
        w *= k; h *= k
        fly.x = (W - w) / 2; fly.y = (H - h) / 2
        fly.width = w; fly.height = h
        fly.radius = w >= W - 2 ? 0 : 14
        const k2 = 0.86
        shotWin.liftW = w * k2; shotWin.liftH = h * k2
        shotWin.liftX = fly.x + (w - w * k2) / 2
        shotWin.liftY = fly.y + (h - h * k2) / 2
        flyAnim.restart()
      }
      // 1. soft flash, and the photo "lifts off" the screen (shrinks a
      //    bit, rounded corners, shadow);
      // 2. flies in an arc toward the island: horizontally with InOutCubic,
      //    vertically it starts slow and rises at the end, shrinking before
      //    it arrives (OutCubic) — like the iPhone thumbnail;
      // 3. lands on the notification thumbnail: the pill swallows it.
      SequentialAnimation {
        id: flyAnim
        PropertyAction { target: fly; property: "opacity"; value: 1 }
        ParallelAnimation {
          SequentialAnimation {
            NumberAnimation { target: flash; property: "opacity"; from: 0; to: 0.55; duration: 45; easing.type: Easing.OutQuad }
            NumberAnimation { target: flash; property: "opacity"; to: 0; duration: 380; easing.type: Easing.OutCubic }
          }
          SequentialAnimation {
            ParallelAnimation {
              NumberAnimation { target: fly; property: "x"; to: shotWin.liftX; duration: 260; easing.type: Easing.OutCubic }
              NumberAnimation { target: fly; property: "y"; to: shotWin.liftY; duration: 260; easing.type: Easing.OutCubic }
              NumberAnimation { target: fly; property: "width"; to: shotWin.liftW; duration: 260; easing.type: Easing.OutCubic }
              NumberAnimation { target: fly; property: "height"; to: shotWin.liftH; duration: 260; easing.type: Easing.OutCubic }
              NumberAnimation { target: fly; property: "radius"; to: 18; duration: 260; easing.type: Easing.OutCubic }
            }
            PauseAnimation { duration: 70 }
            ParallelAnimation {
              NumberAnimation { target: fly; property: "x"; to: root.shotTarget.x; duration: 540; easing.type: Easing.InOutCubic }
              NumberAnimation { target: fly; property: "y"; to: root.shotTarget.y; duration: 540; easing.type: Easing.InQuart }
              NumberAnimation { target: fly; property: "width"; to: root.shotTarget.width; duration: 540; easing.type: Easing.InOutQuad }
              NumberAnimation { target: fly; property: "height"; to: root.shotTarget.height; duration: 540; easing.type: Easing.InOutQuad }
              NumberAnimation { target: fly; property: "radius"; to: root.shotTargetRadius; duration: 540; easing.type: Easing.InOutQuad }
            }
          }
        }
        ScriptAction { script: { root.shotFlying = false; gulpAnim.restart() } }
        NumberAnimation { target: fly; property: "opacity"; to: 0; duration: 110 }
        ScriptAction { script: root.shotPath = "" }
      }
    }
  }

}
