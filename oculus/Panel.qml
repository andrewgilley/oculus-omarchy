import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Oculus bar widget + popout: act on the GitHub/Codeberg page you're looking at.
//
// Copy a project, user, pull request, issue or commit URL (Omarchy's Chromium
// copies the current URL with Alt+Shift+L) and open the panel: it recognises
// the page, says whether oculus.nvim already tracks it, and offers to track the
// project and its owner, open their activity feeds, or inspect the item. The
// panel only ever talks about the page you're on — browse the things you
// already track in Oculus itself.
//
//   oculus-open  <inspect|project|user|oculus> [target]   new Ghostty + Neovim
//   oculus-track <github|codeberg> <owner/repo|login>    edits tracking.json
Panel {
  id: root
  moduleName: "andrewgilley.oculus"
  ipcTarget: "andrewgilley.oculus"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: setting("stateDir", "") || ((Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/oculus")
  readonly property string trackingPath: setting("trackingFile", "") || ((Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/oculus/tracking.json")
  readonly property string binDir: home + "/.local/bin"
  readonly property int staleAfterSec: setting("staleAfterSec", 60)

  property string snapshotText: ""
  property string trackingText: ""
  property string clipboardText: ""
  // Set by the `item` IPC call; wins over the clipboard until the panel closes.
  property string pinnedText: ""
  property string lastError: ""

  readonly property var nvim: Model.parseSnapshot(snapshotText, Math.floor(Date.now() / 1000), staleAfterSec)
  readonly property var tracking: Model.parseTracking(trackingText)
  readonly property var item: Model.parseUrl(pinnedText || clipboardText)
  readonly property var actions: Model.actionsFor(item, tracking)
  // "Tracked" / "Not tracked" for the hero pill; "" when there's nothing to act on.
  readonly property string trackedLabel: Model.trackedLabel(item, tracking)
  // A URL is on the clipboard but it isn't a forge page we can do anything with.
  readonly property bool unusable: item === null && (pinnedText || clipboardText).trim() !== ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function launch(action, target) {
    Quickshell.execDetached(target ? [binDir + "/oculus-open", action, target] : [binDir + "/oculus-open", action])
    close()
  }

  function track(provider, identity) {
    if (tracker.running) return
    lastError = ""
    tracker.command = [binDir + "/oculus-track", "--file", trackingPath, provider, identity]
    tracker.running = true
  }

  function run(action) {
    if (!action || action.done || !item) return
    switch (action.id) {
      case "inspect": launch("inspect", item.url); break
      case "project": launch("project", Model.projectTarget(item)); break
      case "user": launch("user", Model.userTarget(item)); break
      case "trackProject": track(item.provider, item.repository); break
      case "trackUser": track(item.provider, item.owner); break
    }
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

  function readClipboard() {
    if (!clipboard.running) clipboard.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      readClipboard()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      pinnedText = ""
      lastError = ""
    }
  }

  FileView {
    path: root.stateDir + "/omarchy.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.snapshotText = text()
    onLoadFailed: root.snapshotText = ""
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
    id: clipboard
    command: ["wl-paste", "--no-newline", "--type", "text/plain"]
    stdout: StdioCollector { id: clipOut }
    onExited: function(exitCode) {
      root.clipboardText = exitCode === 0 ? clipOut.text.slice(0, 2048) : ""
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
    function status(): string { return root.item ? Model.describe(root.item) : "no item on the clipboard" }
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
    signal activated()

    width: parent ? parent.width : 0
    implicitHeight: rowText.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(4)
      color: mouse.containsMouse && !row.dimmed ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"
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
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.run(Model.primaryAction(root.actions))
      onTextKey: function(t) {
        var action = Model.actionForKey(root.actions, t)
        if (action) root.run(action)
        else if (t === "o" || t === "O") root.openOculus()
        else if (t === "p" || t === "P") { root.pinnedText = ""; root.readClipboard() }
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(4)

          PanelHero {
            width: parent.width
            title: root.item ? Model.describe(root.item) : "Oculus"
            detail: root.trackedLabel
            meta: root.item ? root.item.url
              : root.unusable ? "Not a GitHub or Codeberg project or user page"
              : "Copy a GitHub or Codeberg URL (Alt+Shift+L in Chromium), then press p"
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

          Repeater {
            model: root.actions
            delegate: ActionRow {
              required property var modelData
              label: modelData.label
              hint: modelData.hint || ""
              badge: modelData.done === true ? "\u2713" : modelData.key
              dimmed: modelData.done === true || (tracker.running && modelData.id.indexOf("track") === 0)
              onActivated: root.run(modelData)
            }
          }

          Text {
            visible: root.lastError !== "" || (!root.tracking.ok && root.item !== null)
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.85
            text: root.lastError !== "" ? root.lastError
              : "No tracking file at " + root.trackingPath + ". Create it with {\"version\": 1, \"projects\": [], \"users\": []} to track from here."
          }

          Text {
            width: parent.width
            topPadding: Style.space(4)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.8
            readonly property int keyed: root.actions.filter(function(a) { return a.key !== "" }).length
            text: (keyed > 1 ? "1–" + keyed + " act · " : keyed === 1 ? "1 act · " : "")
              + "p re-read clipboard · o open Oculus"
          }
        }
      }
    }
  }
}
