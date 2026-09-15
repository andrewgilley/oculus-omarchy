import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Oculus bar widget + popout: tracked projects with the most new activity
// since you last opened them.
//
// Data flow:
//   oculus-activity (headless nvim, oculus's forge clients) ──▶ activity.json
//   oculus_omarchy bridge (inside your Neovim)              ──▶ omarchy.json, seen.json
//   this widget watches both files, runs the fetcher on a schedule, and drives
//   Neovim back over its RPC socket.
Panel {
  id: root
  moduleName: "andrewgilley.oculus"
  ipcTarget: "andrewgilley.oculus"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: setting("stateDir", "") || ((Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/oculus")
  readonly property string fetchCommand: setting("fetchCommand", "") || (home + "/.local/bin/oculus-activity")
  readonly property int refreshIntervalSec: setting("refreshIntervalSec", 900)
  readonly property int refreshOnOpenAfterSec: setting("refreshOnOpenAfterSec", 300)
  readonly property int topCount: setting("topProjects", 5)
  readonly property int staleAfterSec: setting("staleAfterSec", 60)

  property string snapshotText: ""
  property string activityText: ""
  property int now: nowSec()
  readonly property var nvim: Model.parseSnapshot(snapshotText, now, staleAfterSec)
  readonly property var activity: Model.parseActivity(activityText)
  // Not `top`: that name is a FINAL property on the base item.
  readonly property var topList: Model.topProjects(activity, topCount)
  readonly property bool fetching: fetcher.running
  property string lastError: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function nowSec() { return Math.floor(Date.now() / 1000) }

  function ageSec() { return activity.ok ? now - activity.fetchedAt : Number.MAX_SAFE_INTEGER }

  function refresh(force) {
    if (fetcher.running) return
    fetcher.command = force ? [fetchCommand, "--force"] : [fetchCommand]
    fetcher.running = true
  }

  function refreshIfOlderThan(seconds) {
    now = nowSec()
    if (ageSec() >= seconds) refresh(false)
  }

  function markSeen(project) {
    Quickshell.execDetached(project ? [fetchCommand, "--seen", project.key] : [fetchCommand, "--seen-all"])
  }

  function sendToNvim(exCommand) {
    var cmd = Model.remoteCommand(nvim.server, exCommand)
    if (cmd !== "" && root.bar) root.bar.run(cmd)
    // TODO: focus the terminal hosting that Neovim; needs the terminal's pid.
  }

  // Fresh Ghostty + Neovim on an empty workspace, opened on this project's
  // activity feed (oculus-open-project → require("oculus").open_project).
  function openProject(project) {
    if (!project) return
    Quickshell.execDetached([home + "/.local/bin/oculus-open-project", project.key])
    markSeen(project)
    close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    refreshIfOlderThan(refreshOnOpenAfterSec)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
    id: activityFile
    path: root.stateDir + "/activity.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.activityText = text()
    onLoadFailed: root.activityText = ""
  }

  Process {
    id: fetcher
    stderr: StdioCollector { id: fetchErr }
    onExited: function(exitCode) {
      root.lastError = exitCode === 0 ? "" : (fetchErr.text.trim().split("\n").pop() || ("fetcher exited " + exitCode))
      activityFile.reload()
    }
  }

  // One cheap tick drives everything: clocks in labels, Neovim liveness, and
  // the refresh schedule (so a suspended laptop catches up on wake).
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshIfOlderThan(root.refreshIntervalSec)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(true); return "ok" }
    function markAllSeen(): string { root.markSeen(null); return "ok" }
    function status(): string { return Model.summary(root.activity, root.fetching, root.nowSec()) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: Model.summary(root.activity, root.fetching, root.now)
    iconComponent: Component {
      Item {
        Text {
          id: eye
          anchors.centerIn: parent
          text: "" // nf-fa-eye
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
          color: root.activity.totalNew > 0 ? root.barForeground : Qt.darker(root.barForeground, 1.55)
        }
        Text {
          visible: root.activity.totalNew > 0
          anchors.left: eye.right
          anchors.bottom: eye.bottom
          anchors.leftMargin: 1
          text: Model.countLabel(root.activity.totalNew)
          font.family: root.fontFamily
          font.pixelSize: Style.space(8)
          font.bold: true
          color: root.barForeground
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh(true)
      else if (buttonCode === Qt.MiddleButton) root.sendToNvim("OculusOpen")
      else root.toggle()
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
      onActivateRequested: if (root.topList.length > 0) root.openProject(root.topList[0])
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh(true)
        else if (t === "a" || t === "A") root.markSeen(null)
        else if (t === "o" || t === "O") root.sendToNvim("OculusOpen")
      }
      // TODO: arrow-key cursor over the project list (see omarchy.dropbox Panel).

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
          spacing: Style.space(8)

          PanelHero {
            width: parent.width
            title: "Oculus"
            meta: Model.summary(root.activity, root.fetching, root.now)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.activity.totalNew > 0 ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                color: root.foreground
              }
            }
          }

          Repeater {
            model: root.topList

            delegate: Item {
              required property var modelData
              width: column.width
              implicitHeight: rowText.implicitHeight + Style.space(10)

              Rectangle {
                anchors.fill: parent
                radius: Style.space(4)
                color: mouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"
              }

              Text {
                id: count
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.error ? "!" : Model.countLabel(modelData.new)
                font.family: root.fontFamily
                font.bold: modelData.new > 0
                color: modelData.new > 0 || modelData.error ? root.foreground : root.dim
              }

              Column {
                id: rowText
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(6)
                width: count.x - x - Style.space(8)

                Text {
                  width: parent.width
                  text: modelData.name || modelData.repository
                  color: modelData.new > 0 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: modelData.error ? String(modelData.error)
                    : [modelData.latest_title, Model.ago(modelData.latest_at, root.now)].filter(Boolean).join(" · ")
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
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openProject(modelData)
              }
            }
          }

          Text {
            visible: root.lastError !== "" || !root.activity.authenticated
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.85
            text: root.lastError !== "" ? root.lastError
              : "GitHub is unauthenticated (60 requests/hour): refreshes are limited to hourly. Run `gh auth login` or set GITHUB_TOKEN."
          }

          Text {
            width: parent.width
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body * 0.8
            text: "r refresh · a mark all seen · o open Oculus"
          }
        }
      }
    }
  }
}
