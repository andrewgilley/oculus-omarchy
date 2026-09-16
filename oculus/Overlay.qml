import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Oculus overlay: search everything you track, plus the page open in the browser
// or a URL you type or paste, and act on it without opening Neovim first.
//
//   omarchy-shell shell toggle andrewgilley.oculus '{}'
//   omarchy-shell shell summon andrewgilley.oculus '{"query": "neovim"}'
//
// The list is on the left and the selected row's actions on the right: Enter
// runs the first one, Tab moves into the actions. Tracking and moving go
// through a group picker in the same card; untracking asks first. Edits go
// through oculus-track, so they are validated by oculus.nvim itself.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "andrewgilley.oculus"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string binDir: home + "/.local/bin"

  // Settings live on the bar widget's entry in shell.json.
  property string shellConfigText: ""
  readonly property var settings: Model.pluginSettings(shellConfigText, pluginId)
  readonly property string stateDir: settings.stateDir || ((Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/oculus")
  readonly property string trackingPath: settings.trackingFile || (configHome + "/oculus/tracking.json")

  property string trackingText: ""
  property string browserText: ""
  property bool browserAlive: false
  readonly property var tracking: Model.parseTracking(trackingText)
  readonly property var browser: Model.parseBrowser(browserText)
  readonly property var pageItem: browserAlive ? Model.parseUrl(browser.url) : null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  // "browse": tracked entries and pages; "group": choosing where to put one.
  property string mode: "browse"
  // What the group picker is for: { op: add | move, list, provider, identity, label, group }.
  property var groupTarget: null
  property string browseFilter: ""
  // Tab moves the cursor into the selected row's actions.
  property bool inActions: false
  property int actionIndex: 0
  property bool untrackConfirmOpen: false
  property var untrackRow: null
  property string status: ""
  property bool statusError: false

  readonly property var rows: mode === "group" && groupTarget
    ? Model.groupRows(tracking, groupTarget.list, filterText, groupTarget.group || null)
    : Model.paletteRows(tracking, pageItem, filterText)
  readonly property var selectedRow: rows.length > 0 ? rows[Math.max(0, Math.min(selectedIndex, rows.length - 1))] : null
  readonly property var actions: mode === "browse" ? Model.rowActions(selectedRow, tracking) : []
  // The action Enter runs: the first that isn't already done.
  readonly property int primaryIndex: {
    for (var i = 0; i < actions.length; i++) if (!actions[i].done) return i
    return -1
  }

  // Shares the [menu] surface tokens, like Omarchy's own clipboard and emoji
  // pickers, so themes that style the menu style this too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(875), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(50), Style.font.title + Style.font.caption + Style.spacing.rowPaddingX * 2)

  onRowsChanged: {
    if (selectedIndex >= rows.length) selectedIndex = Math.max(0, rows.length - 1)
  }
  onSelectedRowChanged: {
    inActions = false
    actionIndex = 0
  }

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { }
    root.mode = "browse"
    root.groupTarget = null
    root.untrackConfirmOpen = false
    root.status = ""
    root.setFilter(typeof payload.query === "string" ? payload.query : "")
    root.opened = true
    root.checkBrowser()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  // Closing from inside the overlay also tells the shell, so toggle stays in step.
  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function checkBrowser() {
    if (browser.pid <= 0) { browserAlive = false; return }
    if (!browserCheck.running) {
      browserCheck.command = ["test", "-d", "/proc/" + browser.pid]
      browserCheck.running = true
    }
  }

  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    root.inActions = false
    pointerGate.reset()
    Qt.callLater(function() { if (root.rows.length > 0) resultList.positionViewAtIndex(0, ListView.Beginning) })
  }

  function select(delta) {
    if (root.inActions) {
      if (root.actions.length > 0) root.actionIndex = (root.actionIndex + delta + root.actions.length) % root.actions.length
      return
    }
    if (root.rows.length === 0) return
    pointerGate.reset()
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex + delta, root.rows.length - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (root.rows.length === 0) return
    pointerGate.reset()
    root.selectedIndex = Math.max(0, Math.min(index, root.rows.length - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function primaryAction() {
    return root.primaryIndex >= 0 ? root.actions[root.primaryIndex] : null
  }

  function launch(action, target) {
    Quickshell.execDetached([root.binDir + "/oculus-open", action, target])
    root.dismiss()
  }

  function run(action) {
    var row = root.selectedRow
    if (!action || action.done || !row) return
    var item = row.item
    switch (action.id) {
      case "inspect": root.launch("inspect", item.url); break
      case "project": root.launch("project", Model.projectTarget(item)); break
      case "user": root.launch("user", Model.userTarget(item)); break
      case "browser":
        Quickshell.execDetached(["xdg-open", item.url])
        root.dismiss()
        break
      case "trackProject":
        root.pickGroup({ op: "add", list: "projects", provider: item.provider, identity: item.repository, label: item.repository })
        break
      case "trackUser":
        root.pickGroup({ op: "add", list: "users", provider: item.provider, identity: item.owner, label: "@" + item.owner })
        break
      case "move":
        root.pickGroup({ op: "move", list: row.list, provider: item.provider, identity: row.identity, label: row.label, group: row.group })
        break
      case "untrack": root.requestUntrack(row); break
    }
  }

  function pickGroup(target) {
    root.browseFilter = root.filterText
    root.groupTarget = target
    root.mode = "group"
    root.setFilter("")
  }

  function leaveGroupPicker() {
    root.mode = "browse"
    root.groupTarget = null
    root.setFilter(root.browseFilter)
  }

  function chooseGroup(row) {
    var target = root.groupTarget
    if (!row || !target) return
    var flag = target.op === "move" ? "--move" : "--group"
    root.leaveGroupPicker()
    root.track([flag, JSON.stringify(row.path), target.provider, target.identity],
      (target.op === "move" ? "Moving " : "Tracking ") + target.label + "…")
  }

  function requestUntrack(row) {
    if (!row || row.kind !== "tracked") return
    root.untrackRow = row
    untrackConfirm.selectedIndex = 0
    root.untrackConfirmOpen = true
  }

  function confirmUntrack() {
    var row = root.untrackRow
    root.untrackConfirmOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (row) root.track(["--remove", row.item.provider, row.identity], "Untracking " + row.label + "…")
  }

  function cancelUntrack() {
    root.untrackConfirmOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function track(args, pending) {
    if (tracker.running) return
    root.status = pending
    root.statusError = false
    tracker.command = [root.binDir + "/oculus-track", "--file", root.trackingPath].concat(args)
    tracker.running = true
  }

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0

    if (event.key === Qt.Key_Escape) {
      if (root.inActions) root.inActions = false
      else if (root.filterText) root.setFilter("")
      else if (root.mode === "group") root.leaveGroupPicker()
      else root.dismiss()
    } else if (Util.editsFilter(event, root.filterText)) {
      root.setFilter(Util.editedFilter(event, root.filterText))
    } else if (ctrl && event.key === Qt.Key_V) {
      if (!paste.running) paste.running = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      if (root.mode === "browse" && root.actions.length > 0) {
        root.inActions = !root.inActions
        root.actionIndex = 0
      }
    } else if (event.key === Qt.Key_Up) {
      root.select(-1)
    } else if (event.key === Qt.Key_Down) {
      root.select(1)
    } else if (event.key === Qt.Key_PageUp) {
      root.select(-6)
    } else if (event.key === Qt.Key_PageDown) {
      root.select(6)
    } else if (event.key === Qt.Key_Home && !root.inActions) {
      root.selectAbsolute(0)
    } else if (event.key === Qt.Key_End && !root.inActions) {
      root.selectAbsolute(root.rows.length - 1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.mode === "group") root.chooseGroup(root.selectedRow)
      else if (alt && root.selectedRow) root.run({ id: "browser" })
      else if (root.inActions) root.run(root.actions[root.actionIndex])
      else root.run(root.primaryAction())
    } else if (event.key === Qt.Key_Delete && root.mode === "browse") {
      root.requestUntrack(root.selectedRow)
    } else if (!ctrl && !alt && event.text && event.text.length === 1
        && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      root.setFilter(root.filterText + event.text)
    } else {
      return false
    }
    return true
  }

  FileView {
    path: root.configHome + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.shellConfigText = text()
    onLoadFailed: root.shellConfigText = ""
  }

  FileView {
    path: root.trackingPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.trackingText = text()
    onLoadFailed: root.trackingText = ""
  }

  FileView {
    path: root.stateDir + "/browser.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.browserText = text(); root.checkBrowser() }
    onLoadFailed: { root.browserText = ""; root.browserAlive = false }
  }

  Process {
    id: browserCheck
    onExited: function(exitCode) { root.browserAlive = exitCode === 0 }
  }

  Process {
    id: tracker
    stdout: StdioCollector { id: trackOut }
    stderr: StdioCollector { id: trackErr }
    onExited: function(exitCode) {
      root.statusError = exitCode !== 0
      root.status = exitCode === 0 ? trackOut.text.trim()
        : (trackErr.text.trim().split("\n").pop() || ("oculus-track exited " + exitCode))
    }
  }

  Process {
    id: paste
    command: ["wl-paste", "--no-newline", "--type", "text/plain"]
    stdout: StdioCollector { id: pasteOut }
    onExited: function(exitCode) {
      if (exitCode === 0) root.setFilter(root.filterText + pasteOut.text.split("\n")[0].slice(0, 512))
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-oculus"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.untrackConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.untrackConfirmOpen) {
            if (untrackConfirm.handleKey(event)) event.accepted = true
            return
          }
          if (root.handleKey(event)) event.accepted = true
        }

        ConfirmDialog {
          id: untrackConfirm
          anchors.fill: parent
          opened: root.untrackConfirmOpen
          z: 10
          message: root.untrackRow ? "Stop tracking " + root.untrackRow.label + "?" : ""
          confirmText: "Untrack"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelUntrack()
          onConfirmed: root.confirmUntrack()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || (root.mode === "group"
              ? "Choose a group, or type a name for a new one…"
              : "Search tracked projects and users, or paste a URL…")
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }
        }

        Row {
          width: parent.width
          height: parent.height - root.headerHeight - footer.height - root.contentSpacing * 2

          Item {
            width: Math.round(parent.width * 0.55)
            height: parent.height
            clip: true

            ListView {
              id: resultList
              anchors.fill: parent
              anchors.rightMargin: root.contentMargin
              model: root.rows
              clip: true
              spacing: Style.space(2)
              boundsBehavior: Flickable.StopAtBounds

              delegate: Column {
                id: entry
                required property int index
                required property var modelData
                readonly property bool hasCursor: index === root.selectedIndex
                readonly property bool firstOfSection: index === 0 || root.rows[index - 1].section !== modelData.section

                width: ListView.view.width

                Text {
                  visible: entry.firstOfSection
                  width: parent.width
                  leftPadding: Style.space(12)
                  topPadding: entry.index === 0 ? 0 : Style.space(8)
                  bottomPadding: Style.space(4)
                  text: entry.modelData.section
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  id: row
                  width: parent.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: entry.hasCursor && !root.inActions ? root.selectedBackground : "transparent"
                  border.width: entry.hasCursor && root.inActions ? Style.normalBorderWidth : 0
                  border.color: Util.alpha(root.foreground, 0.2)

                  Text {
                    id: rowIcon
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    text: entry.modelData.icon
                    color: entry.hasCursor ? root.selectedText : root.foreground
                    opacity: entry.hasCursor ? 1 : 0.7
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                  }

                  Column {
                    anchors.left: rowIcon.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: entry.modelData.label
                      color: entry.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: text !== ""
                      width: parent.width
                      text: entry.modelData.detail
                      color: root.foreground
                      opacity: 0.58
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: function(mouse) {
                      if (pointerGate.moved(row, mouse)) root.selectedIndex = entry.index
                    }
                    onClicked: {
                      root.selectedIndex = entry.index
                      if (root.mode === "group") root.chooseGroup(entry.modelData)
                      else root.run(root.primaryAction())
                    }
                  }
                }
              }
            }

            Column {
              anchors.centerIn: parent
              width: parent.width - root.contentMargin * 2
              spacing: Style.space(8)
              visible: root.rows.length === 0

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                text: !root.tracking.ok
                  ? "No tracking file at " + root.trackingPath
                  : root.filterText ? "No matches for “" + root.filterText + "”"
                  : "Nothing tracked yet. Paste a GitHub or Codeberg URL to track it."
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }

          // Details and actions for the selected row.
          Item {
            width: parent.width - Math.round(parent.width * 0.55)
            height: parent.height
            clip: true

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.normalBorderWidth
              color: Util.alpha(root.border, 0.28)
            }

            Column {
              anchors.fill: parent
              anchors.leftMargin: root.contentMargin
              spacing: Style.space(6)
              visible: root.mode === "group" && root.groupTarget !== null

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.groupTarget ? (root.groupTarget.op === "move" ? "Move " : "Track ") + root.groupTarget.label : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: (root.groupTarget && root.groupTarget.op === "move"
                  ? "Now in " + Model.groupLabel(root.groupTarget.group) + ". "
                  : "") + "Pick a group, or type a name to create a new one at the top level."
                color: root.foreground
                opacity: 0.58
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Column {
              anchors.fill: parent
              anchors.leftMargin: root.contentMargin
              spacing: Style.space(4)
              visible: root.mode === "browse" && root.selectedRow !== null

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.selectedRow ? root.selectedRow.label : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: !root.selectedRow ? ""
                  : root.selectedRow.kind === "tracked" ? "Tracked · " + Model.groupLabel(root.selectedRow.group)
                  : Model.trackedLabel(root.selectedRow.item, root.tracking)
                color: root.selectedText
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                bottomPadding: Style.space(10)
                text: root.selectedRow ? root.selectedRow.item.url : ""
                color: root.foreground
                opacity: 0.58
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }

              Repeater {
                model: root.actions

                delegate: Rectangle {
                  id: actionRow
                  required property int index
                  required property var modelData
                  readonly property bool hasCursor: root.inActions && index === root.actionIndex

                  width: parent.width
                  height: actionText.implicitHeight + Style.space(12)
                  radius: root.cornerRadius
                  color: hasCursor || (actionMouse.containsMouse && !modelData.done) ? root.selectedBackground : "transparent"

                  Column {
                    id: actionText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.right: badge.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: actionRow.modelData.label
                      color: actionRow.hasCursor ? root.selectedText : root.foreground
                      opacity: actionRow.modelData.done ? 0.5 : 1
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: text !== ""
                      width: parent.width
                      text: actionRow.modelData.hint || ""
                      color: root.foreground
                      opacity: 0.5
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    id: badge
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: actionRow.modelData.done ? "✓"
                      : actionRow.index === root.primaryIndex ? "↵" : ""
                    color: root.foreground
                    opacity: 0.58
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    id: actionMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: actionRow.modelData.done ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onClicked: root.run(actionRow.modelData)
                  }
                }
              }
            }
          }
        }

        Item {
          id: footer
          width: parent.width
          height: Style.font.caption + Style.space(6)

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: hints.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.status
            color: root.statusError ? Color.urgent : root.foreground
            opacity: root.statusError ? 1 : 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: hints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.mode === "group"
              ? "↵ choose · Esc back"
              : "↵ run · Tab actions · Alt+↵ open in browser · Del untrack · Ctrl+V paste · Esc close"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
