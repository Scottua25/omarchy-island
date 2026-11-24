import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ImagePickerModel.js" as ImagePickerModel

Item {
  id: root

  // Injected by omarchy-shell; defaults to the session OMARCHY_PATH.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string stateHome: Quickshell.env("HOME") + "/.local/state"
  property string userThemesPath: Quickshell.env("HOME") + "/.config/omarchy/themes"
  property string imageDirs: Quickshell.env("OMARCHY_IMAGE_SELECTOR_DIRS") || Quickshell.env("OMARCHY_IMAGE_SELECTOR_DIR") || Quickshell.env("OMARCHY_STOCK_BACKGROUNDS_DIR") || (stateHome + "/omarchy/current/theme/backgrounds")
  property string imageRows: ""
  property string loadedImageRows: ""
  property string selectionFile: Quickshell.env("OMARCHY_IMAGE_SELECTOR_SELECTION_FILE") || Quickshell.env("OMARCHY_BACKGROUND_SELECTION_FILE")
  property string selectedImage: Quickshell.env("OMARCHY_IMAGE_SELECTOR_SELECTED")
  property int selectedIndex: 0
  property bool imagesLoaded: false
  property bool opened: false
  property bool showLabels: false
  property bool filterable: false
  property bool layoutSettled: false
  property bool neighborImagesEnabled: false
  property int renderedFrames: 0
  property bool requestActive: false
  property int requestSerial: 0
  property int applySerial: 0
  property string doneFile: ""
  property string filterText: ""
  property var doneFilesToRelease: []
  // Themes open from rows the shell already holds, so the picker shows without
  // waiting on omarchy-theme-switcher; each open refreshes them behind it.
  property string themeRows: ""
  property bool themeMode: false
  property bool themeOpenPending: false
  property var extraThemeNames: []
  property var stockThemeNames: []
  property bool stockThemesKnown: false
  property bool awaitingDeleteRefresh: false
  property string pendingDeleteTheme: ""
  property string deleteSelectionPath: ""
  property bool deleteConfirmOpen: false
  // Bound to the central [image-picker] section in shell.toml via Commons.Color.qml.
  // `dimColor` tints unselected slices and text outlines against the desktop
  // behind the picker; it intentionally tracks the foundational background,
  // not a surface role.
  property color dimColor: Commons.Color.background
  property color foreground: Commons.Color.imagePicker.text
  property color selectedBorder: Commons.Color.imagePicker.selectedBorder
  property color unselectedBorder: Commons.Color.imagePicker.unselectedBorder
  // ── omarchy-island: island-style picker ───────────────────────────────
  // Same engine as Omarchy's picker; only the look changes: a strip of
  // rounded previews inside the island, which grows out of the pill and back.
  property int expandedWidth: 300
  property int expandedHeight: 178
  property int sliceWidth: 150
  property int sliceHeight: 104
  property int sliceSpacing: 12
  property int skewOffset: 0
  readonly property int thumbRadius: 18
  readonly property string islandFont: "SF Pro Display"
  readonly property int islandTop: 7
  readonly property int islandRadius: 34
  readonly property int islandWidth: Math.min(panel.width - 120, 1060)
  readonly property int islandPad: 20
  property int bottomChromeHeight: showLabels ? (filterable ? 66 : 40) : (filterable ? 30 : 0)
  // Render only what fits in the island, plus one prefetch slice per side.
  readonly property int previewRadius: Math.max(1, Math.min(16, Math.ceil((islandWidth - expandedWidth) / (2 * (sliceWidth + sliceSpacing))) + 1))

  // Animation: grows out of the island pill ($XDG_RUNTIME_DIR/island-pill.json).
  property bool closing: false
  property real morph: 0
  property real pillW: 200
  property real pillH: 30
  property real pillY: 7
  property real pillX: -1
  property bool islandBottom: false
  readonly property bool wantOpen: root.opened && root.layoutSettled
  FileView {
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/island-pill.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var g = JSON.parse(text())
        root.pillW = Number(g.w) || root.pillW
        root.pillH = Number(g.h) || root.pillH
        root.pillY = isNaN(Number(g.y)) ? root.pillY : Number(g.y)
        root.pillX = typeof g.x === "number" ? g.x : -1
        root.islandBottom = typeof g.position === "string" && g.position.startsWith("bottom-")
      } catch (e) {}
    }
  }
  Process { id: islandProc }
  function islandSync(open) {
    islandProc.command = ["qs", "-c", "island", "ipc", "call", "island", "menu", open ? "open" : "close", "0", "0"]
    islandProc.running = true
  }
  onWantOpenChanged: {
    if (wantOpen) {
      closeAnim.stop()
      closing = false
      islandSync(true)
      morph = 0
      openAnim.restart()
    }
  }
  // Closing: the shape shrinks back into the pill before the window disappears.
  property bool wasOpen: false
  Connections {
    target: root
    function onOpenedChanged() {
      if (root.opened) { root.wasOpen = true; return }
      if (!root.wasOpen) return
      root.wasOpen = false
      root.islandSync(false)
      if (root.morph > 0) {
        openAnim.stop()
        root.closing = true
        closeAnim.from = root.morph
        closeAnim.restart()
      }
    }
  }
  NumberAnimation {
    id: openAnim
    target: root; property: "morph"
    from: 0; to: 1
    duration: Style.duration(480)
    easing.type: Easing.OutBack; easing.overshoot: 1.1
  }
  NumberAnimation {
    id: closeAnim
    target: root; property: "morph"
    to: 0
    duration: Style.duration(230)
    easing.type: Easing.InOutCubic
    onFinished: root.closing = false
  }
  onPreviewRadiusChanged: updateVisibleItems()

  onOpenedChanged: if (!opened) { layoutSettled = false; renderedFrames = 0; deleteConfirmOpen = false; pendingDeleteTheme = ""; deleteSelectionPath = ""; awaitingDeleteRefresh = false }

  PreviewHold {
    id: previewHold
    active: root.opened
    // The selected preview decodes first again on the next open.
    onHeldChanged: if (!held) root.neighborImagesEnabled = false
  }

  function scriptPath(name) {
    return omarchyPath + "/shell/plugins/image-picker/" + name
  }

  function focusPicker() {
    if (root.opened && root.imagesLoaded && root.layoutSettled)
      carousel.forceActiveFocus()
  }

  function revealWhenSettled(serial) {
    Qt.callLater(function() {
      if (serial === root.requestSerial) root.maybeReveal()
    })
  }

  // The card renders at opacity 0 until every visible preview has decoded
  // and its masked layers have presented, so the picker lands in one
  // complete frame instead of flashing its images in as each asynchronous
  // decode and layer upload finishes.
  function allPreviewsSettled() {
    if (!opened || !imagesLoaded || layoutSettled || imageArray.length === 0 || imageCards.count === 0) return false
    for (var i = 0; i < imageCards.count; i++) {
      var item = imageCards.itemAt(i)
      if (!item || !item.previewSettled) return false
    }
    return true
  }

  function settleReveal() {
    if (!opened || !imagesLoaded || layoutSettled || imageArray.length === 0) return
    layoutSettled = true
    focusPicker()
  }

  function maybeReveal() {
    if (!allPreviewsSettled() || renderedFrames < 2) return
    // Confirm on the next tick: delegates inserted later in the same window
    // sync must not pop in after an early all-ready reading.
    Qt.callLater(function() {
      if (root.allPreviewsSettled() && root.renderedFrames >= 2) root.settleReveal()
    })
  }

  function currentPath() {
    if (imageArray.length === 0 || !itemMatches(selectedIndex)) return ""
    return imageArray[selectedIndex].filePath
  }

  function nameForPath(path) {
    return ImagePickerModel.nameForPath(path)
  }

  function labelForPath(path) {
    return ImagePickerModel.labelForPath(path)
  }

  function currentLabel() {
    var path = currentPath()
    if (!path) return filterText ? Commons.I18n.t("common.noMatches") : ""

    return labelForPath(path)
  }

  function itemMatches(index) {
    return ImagePickerModel.itemMatches(imageArray, index, filterText)
  }

  function firstMatchingIndex() {
    return ImagePickerModel.firstMatchingIndex(imageArray, filterText)
  }

  function select(index, immediate) {
    if (imageArray.length === 0) return
    if (index < 0) index = 0
    else if (index >= imageArray.length) index = imageArray.length - 1
    if (!itemMatches(index)) return
    if (index === selectedIndex && immediate !== true) return

    selectedIndex = index
  }

  function selectAdjacent(direction) {
    var count = imageArray.length
    if (count === 0) return

    var index = selectedIndex
    for (var i = 0; i < count; i++) {
      index = (index + direction + count) % count
      if (itemMatches(index)) {
        select(index)
        return
      }
    }
  }

  function updateFilter(nextFilterText) {
    filterText = nextFilterText

    if (!itemMatches(selectedIndex)) {
      var first = ImagePickerModel.nextSelectedIndexForFilter(imageArray, selectedIndex, filterText)
      if (first >= 0) selectedIndex = first
    }
  }

  function releaseNextDoneFile() {
    if (releaseProc.running || doneFilesToRelease.length === 0) return

    var path = doneFilesToRelease.shift()
    releaseProc.command = ["bash", "-c", ": > " + Util.shellQuote(path)]
    releaseProc.running = true
  }

  function finishDoneFile(path) {
    if (!path) return
    doneFilesToRelease.push(path)
    releaseNextDoneFile()
  }

  function applySelected() {
    if (themeMode && (deleteThemeProc.running || awaitingDeleteRefresh)) return
    var path = currentPath()

    if (themeMode) {
      themeMode = false
      root.opened = false
      if (path) Util.execArgv(["omarchy-theme-set", nameForPath(path)])
      return
    }

    if (!path || !selectionFile) {
      cancel()
      return
    }

    var activeSelectionFile = selectionFile
    var activeDoneFile = doneFile
    applySerial = requestSerial
    requestActive = false
    selectionFile = ""
    doneFile = ""

    applyProc.command = ["bash", "-c", "printf '%s\\n' " + Util.shellQuote(path) + " > " + Util.shellQuote(activeSelectionFile) + "; : > " + Util.shellQuote(activeDoneFile)]
    applyProc.running = true
  }

  function cancel() {
    themeOpenPending = false

    if (requestActive)
      finishDoneFile(doneFile)

    requestActive = false
    selectionFile = ""
    doneFile = ""
    root.opened = false
  }

  function closeSelector(nextDoneFile) {
    requestSerial += 1
    themeOpenPending = false

    if (requestActive)
      finishDoneFile(doneFile)

    if (nextDoneFile && nextDoneFile !== doneFile)
      finishDoneFile(nextDoneFile)

    requestActive = false
    selectionFile = ""
    doneFile = ""
    filterText = ""
    root.opened = false
  }

  function loadRows(rows, reveal) {
    var newImages = ImagePickerModel.loadRows(rows)

    root.loadedImageRows = rows
    var nextIndex = root.indexForSelectedImage(newImages)
    root.selectedIndex = ImagePickerModel.nextSelectedIndexForFilter(newImages, nextIndex, root.filterText)
    root.neighborImagesEnabled = false
    root.imageArray = newImages
    root.imagesLoaded = true
    Qt.callLater(root.enableNeighborsWhenReady)

    if (reveal !== false) {
      root.opened = true
      root.revealWhenSettled(root.requestSerial)
    }
  }

  function openSelector(nextImageDirs, nextImageRows, nextSelectedImage, nextSelectionFile, nextDoneFile, nextShowLabels, nextFilterable) {
    deleteConfirmOpen = false
    pendingDeleteTheme = ""
    deleteSelectionPath = ""
    awaitingDeleteRefresh = false
    if (requestActive && doneFile && doneFile !== nextDoneFile)
      finishDoneFile(doneFile)

    requestSerial += 1
    themeMode = false
    themeOpenPending = false

    imageDirs = nextImageDirs
    imageRows = nextImageRows
    selectedImage = nextSelectedImage
    selectionFile = nextSelectionFile
    doneFile = nextDoneFile
    requestActive = !!doneFile
    showLabels = nextShowLabels === true || nextShowLabels === "true"
    filterable = nextFilterable === true || nextFilterable === "true"
    filterText = ""
    layoutSettled = false

    if (imageRows && imageRows === loadedImageRows && imageArray.length > 0) {
      root.select(root.selectedImageIndex(), true)
      imagesLoaded = true
      opened = true
      root.revealWhenSettled(requestSerial)
      return
    }

    if (imageRows) {
      var rowsToLoad = imageRows
      var rowsSerial = requestSerial
      imageArray = []
      selectedIndex = 0
      imagesLoaded = true
      opened = true
      Qt.callLater(function() {
        if (rowsSerial === root.requestSerial)
          root.loadRows(rowsToLoad, true)
      })
      return
    }

    imageArray = []
    selectedIndex = 0
    imagesLoaded = false
    opened = false
    startImageScan(requestSerial, imageDirs)
  }

  property var imageArray: []
  readonly property var matchingImageIndices: ImagePickerModel.matchingIndices(imageArray, filterText)
  onMatchingImageIndicesChanged: updateVisibleItems()
  onSelectedIndexChanged: {
    updateVisibleItems()
    introPrepareTimer.restart()
  }
  onThemeModeChanged: if (themeMode) introPrepareTimer.restart()

  Timer {
    id: introPrepareTimer
    interval: 75
    onTriggered: {
      if (root.opened && root.themeMode && !introPrepare.running) {
        introPrepare.theme = root.nameForPath(root.currentPath())
        introPrepare.command = ["omarchy-theme-bg-boot-intro", "--prepare-theme", root.nameForPath(root.currentPath())]
        introPrepare.running = true
      }
    }
  }

  Process {
    id: introPrepare
    property string theme: ""
    onExited: if (root.opened && root.themeMode && theme !== root.nameForPath(root.currentPath())) introPrepareTimer.restart()
  }

  function updateVisibleItems() {
    ImagePickerModel.syncWindow(visibleImages, ImagePickerModel.visibleWindow(matchingImageIndices, selectedIndex, previewRadius))
  }

  function enableNeighborsWhenReady() {
    for (var i = 0; i < imageCards.count; i++) {
      var item = imageCards.itemAt(i)
      if (item && item.selected && item.previewReady) neighborImagesEnabled = true
    }
  }

  ListModel { id: visibleImages }


  function currentThemePreview() {
    var name = String(themeNameFile.text() || "").trim()
    var images = ImagePickerModel.loadRows(themeRows)
    for (var i = 0; i < images.length; i++) {
      if (nameForPath(images[i].filePath) === name) return images[i].filePath
    }
    return ""
  }

  function openThemes() {
    if (themeRows) {
      openThemeRows()
    } else {
      // First open before the startup refresh has landed.
      themeOpenPending = true
    }
    refreshThemeRows()
    refreshExtraThemes()
    refreshStockThemes()
  }

  function openThemeRows() {
    openSelector("", themeRows, currentThemePreview(), "", "", true, true)
    themeMode = true
  }

  // A refresh asked mid-refresh (a deletion finishing behind the open-time
  // one) queues a second pass instead of leaving the list stale.
  function refreshThemeRows() {
    if (themeRowsProc.running) { themeRowsProc.queued = true; return }
    themeRowsProc.running = true
  }

  function refreshExtraThemes() {
    if (extraThemesProc.running) { extraThemesProc.queued = true; return }
    extraThemesProc.running = true
  }

  function refreshStockThemes() {
    if (!stockThemesProc.running) stockThemesProc.running = true
  }

  function selectedThemeName() {
    return nameForPath(currentPath())
  }

  function canDeleteSelectedTheme() {
    return themeMode && !deleteThemeProc.running && !awaitingDeleteRefresh && stockThemesKnown && ImagePickerModel.canDeleteTheme(selectedThemeName(), extraThemeNames, stockThemeNames)
  }

  function requestDeleteSelectedTheme() {
    if (!canDeleteSelectedTheme()) return
    pendingDeleteTheme = selectedThemeName()
    deleteConfirm.selectedIndex = 1
    deleteConfirmOpen = true
  }

  function cancelDeleteTheme() {
    deleteConfirmOpen = false
    pendingDeleteTheme = ""
  }

  // Removal itself is omarchy-theme-remove's job (including its guards and
  // notification); the picker only refreshes its rows once it finishes.
  function confirmDeleteTheme() {
    var name = pendingDeleteTheme
    deleteConfirmOpen = false
    pendingDeleteTheme = ""
    if (!name || deleteThemeProc.running) return
    // Keep the user's place in the list once the deleted theme is gone.
    if (name === selectedThemeName()) deleteSelectionPath = ImagePickerModel.replacementSelectionPath(imageArray, selectedIndex, filterText)
    deleteThemeProc.command = ["omarchy-theme-remove", name]
    deleteThemeProc.running = true
  }

  function updateThemeRows(rows) {
    var changed = rows !== themeRows
    themeRows = rows

    if (themeOpenPending) {
      themeOpenPending = false
      if (rows) openThemeRows()
    } else if (changed && rows && themeMode && opened) {
      // A theme was added or removed since the rows were last read. Keep the
      // user's place in the carousel rather than jumping back to the current;
      // a just-deleted selection lands on the theme before it.
      selectedImage = deleteSelectionPath || currentPath() || currentThemePreview()
      deleteSelectionPath = ""
      awaitingDeleteRefresh = false
      imageRows = rows
      loadRows(rows, false)
    }
  }

  FileView {
    id: themeNameFile
    path: root.stateHome + "/omarchy/current/theme.name"
    watchChanges: true
    onFileChanged: reload()
  }

  Process {
    id: themeRowsProc
    property bool queued: false
    command: [root.omarchyPath + "/bin/omarchy-theme-switcher", "--print-rows"]
    stdout: StdioCollector {
      onStreamFinished: root.updateThemeRows(String(text || "").trim())
    }
    onExited: {
      if (queued) {
        queued = false
        running = true
      }
    }
  }

  // The same listing omarchy-theme-remove offers interactively: real
  // directories under the user themes path, never symlinked working copies.
  Process {
    id: extraThemesProc
    property bool queued: false
    command: ["find", root.userThemesPath, "-mindepth", "1", "-maxdepth", "1", "-type", "d", "!", "-xtype", "l", "-printf", "%f\n"]
    stdout: StdioCollector {
      onStreamFinished: root.extraThemeNames = ImagePickerModel.parseThemeNames(String(text || ""))
    }
    onExited: {
      if (queued) {
        queued = false
        running = true
      }
    }
  }

  Process {
    id: stockThemesProc
    command: ["find", root.omarchyPath + "/themes", "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-printf", "%f\n"]
    stdout: StdioCollector {
      onStreamFinished: root.stockThemeNames = ImagePickerModel.parseThemeNames(String(text || ""))
    }
    // Until this lands, stockThemeNames is empty and an override would look
    // deletable: deletion stays disabled unless the listing succeeded.
    onExited: function(exitCode) { if (exitCode === 0) root.stockThemesKnown = true }
  }

  Process {
    id: deleteThemeProc
    onExited: function(exitCode) {
      if (exitCode === 0) root.awaitingDeleteRefresh = true
      else root.deleteSelectionPath = ""
      root.refreshExtraThemes()
      root.refreshThemeRows()
    }
  }

  Component.onCompleted: {
    refreshThemeRows()
    refreshExtraThemes()
    refreshStockThemes()
  }

  function startImageScan(serial, dirs) {
    if (loadImagesProc.running) {
      loadImagesProc.queuedSerial = serial
      loadImagesProc.queuedDirs = dirs
      return
    }

    loadImagesProc.activeSerial = serial
    loadImagesProc.queuedSerial = 0
    loadImagesProc.queuedDirs = ""
    loadImagesProc.command = [root.scriptPath("list.sh"), dirs]
    loadImagesProc.running = true
  }

  function indexForSelectedImage(images) {
    return ImagePickerModel.indexForSelectedImage(images, selectedImage)
  }

  function selectedImageIndex() {
    return indexForSelectedImage(imageArray)
  }

  Process {
    id: loadImagesProc
    property int activeSerial: 0
    property int queuedSerial: 0
    property string queuedDirs: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (loadImagesProc.activeSerial === root.requestSerial)
          root.loadRows(String(text || ""), true)
      }
    }
    onExited: {
      var serial = queuedSerial
      var dirs = queuedDirs
      activeSerial = 0
      queuedSerial = 0
      queuedDirs = ""
      if (serial > 0 && serial === root.requestSerial)
        root.startImageScan(serial, dirs)
    }
  }

  // Lifecycle hooks invoked by omarchy-shell summon/hide. shell.summon(id,
  // payloadJson) hands the JSON to open() here; shell.hide(id) calls close().
  // The shell host owns the stable `image-selector` IPC target and forwards
  // those lower-level positional calls here.
  function open(payload) {
    var args = {}
    if (payload) {
      try { args = JSON.parse(payload) || {} } catch (e) { args = {} }
    }
    if (args.source === "themes") {
      openThemes()
      return
    }
    var dirs = String(args.imageDirs || imageDirs)
    var rows = String(args.imageRows || "")
    var sel = String(args.selectedImage || selectedImage)
    var selFile = String(args.selectionFile || "")
    var doneF = String(args.doneFile || "")
    var labels = args.showLabels === true || args.showLabels === "true"
    var filter = args.filterable === true || args.filterable === "true"
    openSelector(dirs, rows, sel, selFile, doneF, labels, filter)
  }

  function close() {
    cancel()
  }

  function preloadRows(nextImageRows, nextSelectedImage, nextShowLabels, nextFilterable) {
    // Theme/background set hooks can warm selector rows after a picker was
    // dismissed. Ignore those preloads while a user-visible request is open;
    // otherwise the preload resets layoutSettled without revealing again,
    // leaving the picker invisible behind its own open overlay.
    if (opened || requestActive) return

    previewHold.warm()
    requestSerial += 1
    imageRows = nextImageRows
    selectedImage = nextSelectedImage
    showLabels = nextShowLabels === true || nextShowLabels === "true"
    filterable = nextFilterable === true || nextFilterable === "true"
    filterText = ""
    layoutSettled = false

    if (imageRows && imageRows === loadedImageRows && imageArray.length > 0) {
      selectedIndex = selectedImageIndex()
      imagesLoaded = true
    } else if (imageRows) {
      loadRows(imageRows, false)
    }
  }

  Process {
    id: applyProc
    onExited: {
      if (root.applySerial === root.requestSerial)
        root.opened = false
    }
  }

  Process {
    id: releaseProc
    onExited: root.releaseNextDoneFile()
  }

  OverlayWindow {
    id: panel
    shown: root.opened || root.closing
    shownKeyboardFocus: root.imagesLoaded ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: "omarchy-image-selector"

    MouseArea {
      anchors.fill: parent
      enabled: root.opened && root.imagesLoaded
      onClicked: root.cancel()
    }

    // Count presented frames while the card pre-renders below; two frames
    // prove its masked layers uploaded on this fresh surface.
    FrameAnimation {
      running: root.opened && !root.layoutSettled && root.renderedFrames < 2
      onTriggered: {
        root.renderedFrames += 1
        root.maybeReveal()
      }
    }

    // A preview stuck decoding (slow disk, huge original) must not hold an
    // invisible picker with the keyboard grabbed: reveal anyway shortly.
    Timer {
      interval: 400
      running: root.opened && root.imagesLoaded && !root.layoutSettled && root.imageArray.length > 0
      onTriggered: root.settleReveal()
    }

    // ── omarchy-island: island shape ───────────────────────────────────
    Item {
      id: morphBox
      readonly property real fullW: root.islandWidth
      readonly property real fullH: root.islandPad + root.expandedHeight + (root.showLabels ? 38 : 0) + (root.filterable && root.filterText.trim().length > 0 ? 24 : 0) + 18
      width: Math.max(1, root.pillW + (fullW - root.pillW) * root.morph)
      height: Math.max(1, root.pillH + (fullH - root.pillH) * root.morph)
      x: root.pillX < 0 ? (parent.width - width) / 2 : Math.max(7, Math.min(root.pillX + root.pillW / 2 - width / 2, parent.width - width - 7))
      y: root.pillY + ((root.islandBottom ? Math.max(7, parent.height - root.islandTop - fullH) : root.islandTop) - root.pillY) * Math.min(1, root.morph)

      RectangularShadow {
        anchors.fill: islandShape
        radius: islandShape.radius
        blur: 30
        offset.y: 8
        color: Qt.rgba(0, 0, 0, 0.5 * Math.min(1, root.morph))
      }
      Rectangle {
        id: islandShape
        anchors.fill: parent
        color: Commons.Color.background
        radius: Math.min(height / 2, root.pillH / 2 + (root.islandRadius - root.pillH / 2) * Math.min(1, Math.max(0, root.morph)))
      }
      Rectangle {
        id: islandMask
        anchors.fill: parent
        radius: islandShape.radius
        visible: false
        layer.enabled: true
      }
      // The content is clipped by the shape while it expands.
      Item {
        id: clipBox
        anchors.fill: parent
        layer.enabled: root.morph > 0 && root.morph < 1
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: islandMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
        }
      }
    }

    Item {
      id: card
      // Before the reveal it stays down here (transparent), preloading the previews.
      visible: (root.opened || root.closing) && root.imagesLoaded && root.imageArray.length > 0
      opacity: root.layoutSettled ? Math.max(0, Math.min(1, (root.morph - 0.35) / 0.45)) : 0
      parent: clipBox
      width: morphBox.fullW
      height: morphBox.fullH
      x: Math.round((clipBox.width - width) / 2)
      y: 0

        MouseArea { anchors.fill: parent; enabled: root.layoutSettled; onClicked: {} }

        Item {
          id: carousel
          anchors.top: parent.top
          anchors.topMargin: root.islandPad
          height: root.expandedHeight
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width - 2 * root.islandPad
          clip: true
          focus: true

          readonly property real itemStep: root.sliceWidth + root.sliceSpacing
          readonly property real previewX: (width - root.expandedWidth) / 2
          readonly property bool mirrored: LayoutMirroring.enabled

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (root.deleteConfirmOpen) {
              if (deleteConfirm.handleKey(event)) event.accepted = true
              return
            }
            // Nothing is visible before the reveal: only let the user back
            // out, never filter into a dead end or apply an unseen pick.
            if (!root.layoutSettled) {
              if (event.key === Qt.Key_Escape) {
                root.cancel()
                event.accepted = true
              }
              return
            }
            if (event.key === Qt.Key_Escape) {
              if (root.filterText) {
                root.updateFilter("")
              } else {
                root.cancel()
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.applySelected()
              event.accepted = true
            } else if (event.key === Qt.Key_Delete && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
              root.requestDeleteSelectedTheme()
              event.accepted = true
            } else if (root.filterable && Util.editsFilter(event, root.filterText)) {
              root.updateFilter(Util.editedFilter(event, root.filterText))
              event.accepted = true
            } else if (Util.readingKey(event) === Qt.Key_Left || (event.key === Qt.Key_Tab && event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab) {
              root.selectAdjacent(-1)
              event.accepted = true
            } else if (Util.readingKey(event) === Qt.Key_Right || event.key === Qt.Key_Tab) {
              root.selectAdjacent(1)
              event.accepted = true
            } else if (root.filterable && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
              root.updateFilter(root.filterText + event.text)
              event.accepted = true
            }
          }

          Component.onCompleted: forceActiveFocus()

          Repeater {
            id: imageCards
            model: visibleImages
            onCountChanged: root.maybeReveal()

            delegate: Item {
              id: item
              required property int imageIndex
              required property int relativeIndex

              readonly property var imageData: root.imageArray[imageIndex]
              readonly property string filePath: imageData ? imageData.filePath : ""
              readonly property string fileName: imageData ? imageData.fileName : ""
              readonly property string thumbnailPath: imageData ? imageData.thumbnailPath : ""

              readonly property bool selected: imageIndex === root.selectedIndex
              readonly property bool previewReady: image.status === Image.Ready || image.status === Image.Error
              readonly property bool previewSettled: !thumbnailPath || previewReady
              onPreviewSettledChanged: if (previewSettled) root.maybeReveal()
              onSelectedChanged: if (selected && previewReady) root.neighborImagesEnabled = true

              readonly property real readingX: selected ? carousel.previewX : (relativeIndex < 0 ? carousel.previewX + relativeIndex * carousel.itemStep : carousel.previewX + root.expandedWidth + root.sliceSpacing + (relativeIndex - 1) * carousel.itemStep)
              // A mirrored (right-to-left) layout runs the carousel from the
              // right, so the next image sits where the reading continues.
              x: carousel.mirrored ? carousel.width - readingX - width : readingX
              width: selected ? root.expandedWidth : root.sliceWidth
              height: selected ? root.expandedHeight : root.sliceHeight
              y: selected ? 0 : (root.expandedHeight - root.sliceHeight) / 2
              z: selected ? 100 : 50 - Math.min(Math.abs(relativeIndex), 40)
              // omarchy-island: smooth scrolling.
              Behavior on x { enabled: root.layoutSettled; NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
              Behavior on width { enabled: root.layoutSettled; NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
              Behavior on height { enabled: root.layoutSettled; NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
              Behavior on y { enabled: root.layoutSettled; NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }

              readonly property real skAbs: Math.abs(root.skewOffset)
              readonly property real topLeft: root.skewOffset >= 0 ? skAbs : 0
              readonly property real topRight: root.skewOffset >= 0 ? width : width - skAbs
              readonly property real bottomRight: root.skewOffset >= 0 ? width - skAbs : width
              readonly property real bottomLeft: root.skewOffset >= 0 ? 0 : skAbs

              Rectangle {
                id: maskShape
                anchors.fill: parent
                radius: root.thumbRadius
                visible: false
                layer.enabled: true
              }

              Item {
                anchors.fill: parent
                layer.enabled: true
                layer.smooth: true
                layer.effect: MultiEffect {
                  maskEnabled: true
                  maskSource: maskShape
                  maskThresholdMin: 0.3
                  maskSpreadAtMin: 0.3
                }

                Rectangle { anchors.fill: parent; color: Qt.darker(Commons.Color.background, 1.25) }

                Image {
                  id: image
                  anchors.fill: parent
                  // Decode at the expanded card's physical size, off the GUI
                  // thread. Keep that size during navigation to avoid reloads.
                  // Departing cards release their images instead of retaining
                  // every preview visited in a large collection.
                  // Queue the selected preview first; neighbors must not delay
                  // the image the user opened the picker to see.
                  source: previewHold.held && (item.selected || root.neighborImagesEnabled) && item.thumbnailPath ? Util.fileUrl(item.thumbnailPath) : ""
                  sourceSize.width: Math.ceil(root.expandedWidth * Screen.devicePixelRatio)
                  sourceSize.height: Math.ceil(root.expandedHeight * Screen.devicePixelRatio)
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: false
                  smooth: true
                  opacity: status === Image.Ready ? 1 : 0
                  onStatusChanged: if (item.selected && (status === Image.Ready || status === Image.Error)) root.neighborImagesEnabled = true
                }

                Rectangle {
                  anchors.fill: parent
                  color: Util.alpha(Commons.Color.background, item.selected ? 0 : 0.5)
                  Behavior on color { ColorAnimation { duration: Style.duration(200) } }
                }
              }

              Rectangle {
                anchors.fill: parent
                radius: root.thumbRadius
                color: "transparent"
                border.width: item.selected ? 3 : 0
                border.color: root.selectedBorder
              }

              MouseArea {
                anchors.fill: parent
                enabled: root.layoutSettled
                cursorShape: Qt.PointingHandCursor
                onClicked: item.selected ? root.applySelected() : root.select(item.imageIndex)
              }
            }
          }
        }

        Text {
          id: selectedLabel
          textFormat: Text.PlainText
          visible: root.showLabels
          anchors.top: carousel.bottom
          anchors.topMargin: 10
          anchors.horizontalCenter: carousel.horizontalCenter
          width: root.expandedWidth * 2
          text: root.currentLabel()
          color: Commons.Color.foreground
          font.family: root.islandFont
          font.pixelSize: 17
          font.weight: Font.DemiBold
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: root.filterable && root.filterText.trim().length > 0
          anchors.top: selectedLabel.bottom
          anchors.topMargin: Style.space(8)
          anchors.horizontalCenter: carousel.horizontalCenter
          width: root.expandedWidth
          text: "󰍉  " + root.filterText
          color: Util.alpha(Commons.Color.foreground, 0.6)
          font.family: root.islandFont
          font.pixelSize: 13
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
    }

    // Unlike the picker itself, the confirmation keeps the faded backdrop:
    // a destructive choice should take over the screen.
    ConfirmDialog {
      id: deleteConfirm
      anchors.fill: parent
      opened: root.deleteConfirmOpen
      z: 10
      message: Commons.I18n.t("imagePicker.deleteTheme").arg(root.pendingDeleteTheme ? root.labelForPath(root.pendingDeleteTheme) : "")
      confirmText: Commons.I18n.t("common.delete")
      background: root.dimColor
      foreground: root.foreground
      onCanceled: root.cancelDeleteTheme()
      onConfirmed: root.confirmDeleteTheme()
    }
  }
}
