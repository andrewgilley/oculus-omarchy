import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Oculus bar widget + popout: act on the GitHub/Codeberg page you're looking at.
//
// The Oculus Page browser extension reports the GitHub/Codeberg page open in
// the browser (browser/oculus-page, via browser/oculus-page-host → browser.json).
// Open the panel and it recognises that page — a project, user, pull request,
// issue or commit — says whether oculus.nvim already tracks it, and offers to
// track the project and its owner, open their activity feeds, or inspect the
// item. The panel only ever talks about the page you're on — browse the things
// you already track in Oculus itself.
//
//   oculus-open  <inspect|project|user|oculus> [target]   new Ghostty + Neovim
//   oculus-track [--group G] [--name N] <github|codeberg> <owner/repo|login>
//   oculus-clone [--check] --dir DIR <github|codeberg> <owner/repo>
//
// Tracking asks, in the panel, which group to put the entry in and what to call it.
Panel {
  id: root
  moduleName: "andrewgilley.oculus"
  ipcTarget: "andrewgilley.oculus"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: setting("stateDir", "") || ((Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/oculus")
  readonly property string trackingPath: setting("trackingFile", "") || ((Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/oculus/tracking.json")
  readonly property string binDir: home + "/.local/bin"
  readonly property string sourceDir: setting("sourceDir", "") || (home + "/Dev/source")
  readonly property int staleAfterSec: setting("staleAfterSec", 60)

  property string snapshotText: ""
  property string trackingText: ""
  property string browserText: ""
  // Whether the browser that wrote browser.json is still running; checked on open.
  property bool browserAlive: true
  // Set by the `item` IPC call; wins over the browser page until the panel closes.
  property string pinnedText: ""
  property string lastError: ""
  // What the source folder holds for a project, from `oculus-clone --check`:
  // { target, state: clone | other | none, path }. Kept keyed to the target it
  // was asked about, so a reply that lands after the page changed is ignored.
  property var cloneState: null
  property string cloneStatus: ""
  // Set while a Track row asks where the entry goes and what to call it:
  // { list, provider, identity, label, step: group | name, path }.
  property var pick: null
  property string pickText: ""
  property int pickIndex: 0
  readonly property var pickRows: !pick ? []
    : pick.step === "group" ? Model.groupRows(tracking, pick.list, pickText, null)
    : Model.nameRows(pick, pickText)

  readonly property var nvim: Model.parseSnapshot(snapshotText, Math.floor(Date.now() / 1000), staleAfterSec)
  readonly property var tracking: Model.parseTracking(trackingText)
  readonly property var browser: Model.parseBrowser(browserText)
  readonly property string pageUrl: pinnedText || (browserAlive ? browser.url : "")
  readonly property var item: Model.parseUrl(pageUrl)
  // The check's answer, but only while it still describes the page's project.
  readonly property var clone: item && item.kind !== "user" && cloneState
    && cloneState.target === Model.projectTarget(item) ? cloneState : null
  readonly property var actions: Model.actionsFor(item, tracking, clone)
  // "Tracked" / "Not tracked" for the hero pill; "" when there's nothing to act on.
  readonly property string trackedLabel: Model.trackedLabel(item, tracking)
  // What's stopping Oculus from reading the page, for the hero; "" otherwise.
  readonly property string emptyReason: item !== null ? ""
    : !browser.ok ? "Run install.sh and restart the browser to load the Oculus Page extension"
    : !browserAlive ? "The browser isn't open"
    : ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function shorten(path) {
    return path.indexOf(home + "/") === 0 ? "~" + path.slice(home.length) : path
  }

  // Ask what the source folder already has for this project, so the clone row
  // can say. Cheap enough to redo whenever the page changes while we're open.
  function checkClone() {
    if (!item || item.kind === "user" || cloneCheck.running) return
    cloneCheck.target = Model.projectTarget(item)
    cloneCheck.command = [binDir + "/oculus-clone", "--check", "--dir", sourceDir, item.provider, item.repository]
    cloneCheck.running = true
  }

  // Clone in the background: git keeps going with the panel closed, and
  // oculus-clone notifies when it lands.
  function startClone() {
    if (cloner.running || !item || item.kind === "user") return
    lastError = ""
    cloneStatus = "Cloning " + item.repository + " into " + shorten(sourceDir) + "\u2026"
    cloner.command = [binDir + "/oculus-clone", "--dir", sourceDir, item.provider, item.repository]
    cloner.running = true
  }

  function launch(action, target) {
    Quickshell.execDetached(target ? [binDir + "/oculus-open", action, target] : [binDir + "/oculus-open", action])
    close()
  }

  function startPick(list, identity, label) {
    if (tracker.running) return
    lastError = ""
    pick = { list: list, provider: item.provider, identity: identity, label: label, step: "group", path: [] }
    pickField.text = ""
    pickIndex = 0
    Qt.callLater(function() { pickField.forceActiveFocus() })
  }

  function endPick() {
    pick = null
    pickField.text = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Esc clears what's typed, then steps back from the name to the group, then out.
  function backPick() {
    if (pickField.text !== "") pickField.text = ""
    else if (pick.step === "name") { pick = Object.assign({}, pick, { step: "group" }); pickIndex = 0 }
    else endPick()
  }

  function movePick(delta) {
    pickIndex = Math.max(0, Math.min(pickIndex + delta, pickRows.length - 1))
  }

  function choosePick(row) {
    if (!pick || !row) return
    if (pick.step === "group") {
      pick = Object.assign({}, pick, { step: "name", path: row.path })
      pickField.text = ""
      pickIndex = 0
      return
    }
    var target = pick
    endPick()
    tracker.command = [binDir + "/oculus-track", "--file", trackingPath, "--group", JSON.stringify(target.path)]
      .concat(row.name ? ["--name", row.name] : [], target.directoryPath ? ["--path", target.directoryPath] : [], [target.provider, target.identity])
    tracker.running = true
  }

  // Keep the cursor row on screen when the group list scrolls.
  function reveal(row) {
    var y = row.mapToItem(column, 0, 0).y
    if (y < flick.contentY) flick.contentY = y
    else if (y + row.height > flick.contentY + flick.height) flick.contentY = y + row.height - flick.height
  }

  function run(action) {
    if (!action || action.done || !item) return
    switch (action.id) {
      case "inspect": launch("inspect", item.url); break
      case "project": launch("project", Model.projectTarget(item)); break
      case "user": launch("user", Model.userTarget(item)); break
      case "clone": startClone(); break
      case "trackProject": startPick("projects", item.repository, item.repository); break
      case "trackDirectory":
        startPick("projects", item.repository, item.repository + "/" + item.path)
        pick = Object.assign({}, pick, { directoryPath: item.path })
        break
      case "trackUser": startPick("users", item.owner, "@" + item.owner); break
    }
  }

  // The overlay: search everything you track, not just this page.
  function browseTracked() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", root.moduleName, "{}"])
    close()
  }

  // Oculus in the Neovim you already have, else a fresh one.
  function openOculus() {
    var cmd = nvim.live ? Model.remoteCommand(nvim.server, "OculusOpen") : ""
    if (cmd !== "" && root.bar) {
      root.bar.run(cmd)
      close()
      // TODO: focus the terminal hosting that Neovim; needs the terminal's pid.
    } else {
      launch("oculus", "")
    }
  }

  function checkBrowser() {
    if (browser.pid <= 0) { browserAlive = true; return }
    if (!browserCheck.running) {
      browserCheck.command = ["test", "-d", "/proc/" + browser.pid]
      browserCheck.running = true
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      checkBrowser()
      checkClone()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      if (pick) endPick()
      pinnedText = ""
      lastError = ""
      if (!cloner.running) cloneStatus = ""
    }
  }

  onItemChanged: if (opened) checkClone()

  FileView {
    path: root.stateDir + "/omarchy.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.snapshotText = text()
    onLoadFailed: root.snapshotText = ""
  }

  FileView {
    path: root.stateDir + "/browser.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.browserText = text(); root.checkBrowser() }
    onLoadFailed: root.browserText = ""
  }

  FileView {
    path: root.trackingPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.trackingText = text()
    onLoadFailed: root.trackingText = ""
  }

  Process {
    id: browserCheck
    onExited: function(exitCode) { root.browserAlive = exitCode === 0 }
  }

  Process {
    id: cloneCheck
    property string target: ""
    stdout: StdioCollector { id: cloneCheckOut }
    onExited: function(exitCode) {
      var parts = cloneCheckOut.text.trim().split("\t")
      root.cloneState = exitCode === 0 && parts.length === 2
        ? { target: cloneCheck.target, state: parts[0], path: root.shorten(parts[1]) } : null
      // The page can change while the check runs; ask again for the new one.
      if (root.opened && root.item && root.item.kind !== "user"
        && Model.projectTarget(root.item) !== cloneCheck.target) root.checkClone()
    }
  }

  Process {
    id: cloner
    stdout: StdioCollector { id: cloneOut }
    stderr: StdioCollector { id: cloneErr }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.cloneStatus = "Cloned to " + root.shorten(cloneOut.text.trim())
      } else {
        root.cloneStatus = ""
        root.lastError = cloneErr.text.trim().split("\n").pop() || ("oculus-clone exited " + exitCode)
      }
      root.checkClone()
    }
  }

  Process {
    id: tracker
    stderr: StdioCollector { id: trackErr }
    onExited: function(exitCode) {
      root.lastError = exitCode === 0 ? "" : (trackErr.text.trim().split("\n").pop() || ("oculus-track exited " + exitCode))
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // omarchy-shell andrewgilley.oculus item https://github.com/owner/repo
    function item(url: string): string {
      if (!Model.parseUrl(url)) return "not a GitHub/Codeberg project, user or item: " + url
      root.pinnedText = url
      root.open()
      return "ok"
    }
    function status(): string { return root.item ? Model.describe(root.item) : root.emptyReason }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Oculus"
    iconComponent: Component {
      OculusMark {
        size: Style.space(12)
        color: root.barForeground
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.openOculus()
      else if (buttonCode === Qt.RightButton) root.opened ? root.close() : root.browseTracked()
      else root.toggle()
    }
  }

  // The plugin mark (assets/omarchy-plugin-icon.svg): nested squares, drawn as
  // a shape rather than a glyph so it takes the bar or panel foreground colour
  // at any size without needing an icon font.
  //
  // The shape is centred rather than filling the item: BarIconButton loads the
  // icon with anchors.fill into its icon canvas (Style.bar.iconCanvas), so the
  // item is the canvas's size, not `size`. Drawing the scaled path from the
  // item's top-left would hang the mark off-centre from the button — and from
  // the active underline, which is centred on the whole slot.
  component OculusMark: Item {
    id: mark
    property real size: Style.font.icon
    property color color: root.foreground

    implicitWidth: size
    implicitHeight: size

    Shape {
      anchors.centerIn: parent
      width: mark.size
      height: mark.size
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: mark.color
        fillRule: ShapePath.OddEvenFill
        strokeWidth: 0
        strokeColor: "transparent"
        scale: Qt.size(mark.size / 1000, mark.size / 1000)
        PathSvg { path: "M64 64H960V960H64ZM108 108V916H916V108ZM228 228H796V796H228ZM272 272V752H752V272ZM392 392H632V632H392Z" }
      }
    }
  }

  // One clickable line: label, dim hint, optional key badge on the right.
  component ActionRow: Item {
    id: row
    property string label: ""
    property string hint: ""
    property string badge: ""
    property bool dimmed: false
    property bool highlighted: false
    signal activated()

    width: parent ? parent.width : 0
    implicitHeight: rowText.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(4)
      color: (mouse.containsMouse || row.highlighted) && !row.dimmed ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"
    }

    Text {
      id: badgeText
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: row.badge
      font.family: root.fontFamily
      color: root.dim
    }

    Column {
      id: rowText
      anchors.verticalCenter: parent.verticalCenter
      x: Style.space(6)
      width: badgeText.x - x - Style.space(8)

      Text {
        width: parent.width
        text: row.label
        color: row.dimmed ? root.dim : root.foreground
        font.family: root.fontFamily
        elide: Text.ElideRight
      }
      Text {
        visible: row.hint !== ""
        width: parent.width
        text: row.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body * 0.85
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.dimmed ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!row.dimmed) row.activated()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Narrow with no page to act on: just the mark and what a click does.
    contentWidth: panel.fittedContentWidth(Style.space(root.item ? 380 : 340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.pick !== null
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.run(Model.primaryAction(root.actions))
      onTextKey: function(t) {
        var action = Model.actionForKey(root.actions, t)
        if (action) root.run(action)
        else if (t === "o" || t === "O") root.openOculus()
        else if (t === "q" || t === "Q") root.close()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        // With no page to act on, a click anywhere in the panel opens Oculus
        // and a right-click closes it.
        MouseArea {
          visible: root.item === null
          width: parent.width
          height: Math.max(column.implicitHeight, flick.height)
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function(mouse) { mouse.button === Qt.RightButton ? root.close() : root.openOculus() }
        }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(4)

          PanelHero {
            width: parent.width
            title: root.item ? Model.describe(root.item) : "Oculus"
            detail: root.trackedLabel
            meta: root.item ? root.item.url : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.item ? 1.0 : 0.5
            iconComponent: Component {
              OculusMark {
                size: Style.font.display
                color: root.foreground
              }
            }
          }

          Text {
            visible: root.item === null
            width: parent.width
            topPadding: Style.space(14)
            bottomPadding: Style.space(10)
            lineHeight: 1.3
            wrapMode: Text.Wrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.85
            text: (root.emptyReason !== "" ? root.emptyReason + "\n\n" : "") + "Click to open Oculus in Neovim\nRight-click to close"
          }

          Repeater {
            model: root.pick ? [] : root.actions
            delegate: ActionRow {
              required property var modelData
              label: modelData.label
              hint: modelData.hint || ""
              badge: modelData.badge || (modelData.done === true ? "\u2713" : modelData.key)
              dimmed: modelData.done === true || (tracker.running && modelData.id.indexOf("track") === 0)
                || (cloner.running && modelData.id === "clone")
              onActivated: root.run(modelData)
            }
          }

          Text {
            visible: root.pick !== null
            width: parent.width
            topPadding: Style.space(4)
            text: !root.pick ? ""
              : root.pick.step === "group" ? "Track " + root.pick.label + " in which group?"
              : "Name " + root.pick.label + " in " + Model.groupLabel(root.pick.path)
            color: root.foreground
            font.family: root.fontFamily
            wrapMode: Text.Wrap
          }

          TextField {
            id: pickField
            visible: root.pick !== null
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            placeholderText: root.pick && root.pick.step === "name"
              ? "Display name, or empty to show " + root.pick.label
              : "Filter, or type a new group name"
            onTextChanged: { root.pickText = text; root.pickIndex = 0 }

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) root.backPick()
              else if (event.key === Qt.Key_Up) root.movePick(-1)
              else if (event.key === Qt.Key_Down) root.movePick(1)
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.choosePick(root.pickRows[root.pickIndex])
              else if (event.key !== Qt.Key_Tab && event.key !== Qt.Key_Backtab) return
              event.accepted = true
            }
          }

          Repeater {
            model: root.pickRows
            delegate: ActionRow {
              required property var modelData
              required property int index
              label: modelData.label
              hint: modelData.detail || ""
              highlighted: index === root.pickIndex
              onHighlightedChanged: if (highlighted) root.reveal(this)
              onActivated: root.choosePick(modelData)
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.85
            text: root.lastError !== "" ? root.lastError
              : root.cloneStatus !== "" ? root.cloneStatus
              : !root.tracking.ok && root.item !== null
              ? "No tracking file at " + root.trackingPath + ". Create it with {\"version\": 1, \"projects\": [], \"users\": []} to track from here."
              : ""
          }

          Text {
            visible: root.item !== null
            width: parent.width
            topPadding: Style.space(4)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.8
            readonly property int keyed: root.actions.filter(function(a) { return a.key !== "" }).length
            text: root.pick ? "↑↓ select · ↵ choose · Esc back"
              : (keyed > 1 ? "1–" + keyed + " act · " : keyed === 1 ? "1 act · " : "")
              + "o open Oculus · q quit"
          }
        }
      }
    }
  }
}
