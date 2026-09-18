import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Herd: herdr agent state across machines. The bar button shows what needs
// attention; the panel lists every agent and jumps to the one you pick.
Panel {
  id: root
  moduleName: "cgranier.herd"
  ipcTarget: "cgranier.herd"
  manageIpc: false

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property bool needsAttention: herd.counts.blocked > 0

  // A bar surface exists per monitor, each with its own service. Let only the
  // first instance raise toasts so two screens don't mean two notifications.
  function isNotifier() {
    if (!bar || typeof bar.moduleWidgets !== "function") return true
    var items = bar.moduleWidgets(moduleName)
    return !items || items.length === 0 || items[0] === root
  }

  function refresh() { herd.refresh() }

  function clampCursor() {
    var last = Math.max(0, herd.cursorRows.length - 1)
    cursorIndex = Math.max(0, Math.min(cursorIndex, last))
  }

  function moveCursor(dy) {
    cursorActive = true
    cursorIndex += dy
    clampCursor()
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
  }

  function selectedRow() {
    if (herd.cursorRows.length === 0) return null
    clampCursor()
    return herd.cursorRows[cursorIndex]
  }

  // Enter on an agent jumps to it; on an idle group it folds or unfolds.
  function activateRow(row) {
    if (!row) return
    if (row.type === "group") herd.toggleGroup(row.machine)
    else activate(row.agent)
  }

  function activate(agent) {
    if (!agent) return
    herd.focusAgent(agent)
    root.close()
  }

  function scrollCursorIntoView() {
    Qt.callLater(function() {
      for (var i = 0; i < rowColumn.children.length; i++) {
        var item = rowColumn.children[i]
        if (!item || item.cursorIndex !== root.cursorIndex) continue
        var margin = Style.space(6)
        var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
        var bottom = top + item.height
        var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
        if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
        else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
        return
      }
    })
  }

  visible: !(setting("hideWhenEmpty", false) === true && herd.counts.total === 0 && !herd.herdrMissing)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  onOpenedChanged: if (opened) {
    cursorActive = false
    panelFlick.contentY = 0
    herd.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: herd
    settings: root.settings
    isNotifier: root.isNotifier
  }

  Connections {
    target: herd
    function onCursorRowsChanged() { root.clampCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { herd.refresh(); return "ok" }
    function status(): string { return herd.summary }
    function counts(): string { return JSON.stringify(herd.counts) }
    function debug(): string { return JSON.stringify(herd.debugState()) }
    function testToast(): string { return herd.testToast() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barLabel(herd.counts, root.vertical)
    active: root.needsAttention
    dimmed: herd.counts.total === 0
    tooltipText: root.opened ? "" : herd.summary

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) herd.focusAgent(herd.firstWaiting())
      else if (buttonCode === Qt.MiddleButton) herd.refresh()
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
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; root.clampCursor(); root.scrollCursorIntoView(); return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateRow(root.selectedRow())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") herd.refresh()
        else if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "b" || t === "B") root.activate(herd.firstWaiting())
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Herd"
            meta: herd.summary
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: herd.counts.total > 0 ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.GLYPHS.herd
                color: root.needsAttention ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: herd.herdrMissing
            width: parent.width
            text: "herdr was not found. Install it, or set the herdr binary in this widget's settings."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            id: rowColumn
            visible: !herd.herdrMissing
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: herd.rows

              Loader {
                required property var modelData
                readonly property string rowType: modelData.type
                readonly property int cursorIndex: modelData.cursorIndex === undefined ? -1 : modelData.cursorIndex
                width: rowColumn.width
                sourceComponent: modelData.type === "agent" ? agentRow
                  : modelData.type === "group" ? groupRow
                  : modelData.type === "header" ? headerRow : noteRow
                onLoaded: item.row = modelData
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "enter jump · b next waiting · r refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  Component {
    id: headerRow

    Item {
      property var row: null
      implicitHeight: headerText.implicitHeight + Style.space(4)

      PanelSectionHeader {
        id: headerText
        anchors.bottom: parent.bottom
        text: row ? row.text : ""
        foreground: row && (!row.ok || row.attention) ? root.urgent : root.foreground
        fontFamily: root.fontFamily
      }
    }
  }

  Component {
    id: noteRow

    Text {
      property var row: null
      textFormat: Text.PlainText
      leftPadding: Style.space(10)
      text: row ? row.text : ""
      color: row && row.urgent ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  Component {
    id: groupRow

    CursorSurface {
      id: group
      property var row: null

      hasCursor: root.cursorActive && row && root.cursorIndex === row.cursorIndex
      foreground: root.foreground
      implicitHeight: groupLabel.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: if (group.row) root.setCursor(group.row.cursorIndex)
        onClicked: if (group.row) herd.toggleGroup(group.row.machine)
      }

      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: Model.GLYPHS.idle
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.space(18)
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          id: groupLabel
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: group.row ? group.row.text : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          textFormat: Text.PlainText
          text: group.row && group.row.expanded ? Model.GLYPHS.collapse : Model.GLYPHS.expand
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }
      }
    }
  }

  Component {
    id: agentRow

    CursorSurface {
      id: surface
      property var row: null
      readonly property var agent: row ? row.agent : null
      readonly property bool waiting: agent && agent.status === "blocked"

      hasCursor: root.cursorActive && row && root.cursorIndex === row.cursorIndex
      foreground: root.foreground
      implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: if (surface.row) root.setCursor(surface.row.cursorIndex)
        onClicked: root.activate(surface.agent)
      }

      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: surface.agent ? Model.statusGlyph(surface.agent.status) : ""
          color: surface.waiting ? root.urgent : root.foreground
          opacity: surface.agent && (surface.agent.status === "idle" || surface.agent.status === "unknown") ? 0.5 : 1.0
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.space(18)
          horizontalAlignment: Text.AlignHCenter
        }

        ColumnLayout {
          id: content
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: surface.agent ? (surface.agent.title !== "" ? surface.agent.name + " · " + surface.agent.title : surface.agent.name) : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: surface.agent ? Model.agentMeta(surface.agent, herd.sinceFor(surface.agent), herd.now, surface.row.showMachine === true) : ""
            color: surface.waiting ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }
      }
    }
  }
}
