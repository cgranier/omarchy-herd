import QtQuick
import Quickshell
import Quickshell.Io

// Listens on the local herdr socket so state changes show up at once instead
// of on the next poll. herdr only offers status events per pane, so this
// subscribes for each known agent pane plus the global "panes came or went"
// events, and treats every event as a nudge to poll — the poll stays the one
// source of truth, and keeps running (slower) in case the stream drops.
//
// The socket is read by bin/herd-events, not by the shell: that bridge caps
// every frame and the connection's total bytes, and ends itself on overflow,
// so a misbehaving server can never grow a buffer inside the shell. Here a
// frame is a line on the bridge's stdout, already known to be short.
Item {
  id: root

  property string socketPath: ""
  property var paneIds: []
  property bool enabled: true

  readonly property bool connected: bridge.running && _subscribed
  property bool _subscribed: false
  property string _subscribedFor: ""

  signal poke()

  readonly property string paneKey: (paneIds || []).slice().sort().join(",")
  readonly property string bridgeScript: String(Qt.resolvedUrl("bin/herd-events")).replace(/^file:\/\//, "")

  // Lines longer than the bridge's frame cap cannot happen; this is the
  // shell-side belt to that suspender.
  readonly property int maxLine: 65536

  function subscribeRequest() {
    var subscriptions = [
      { type: "pane.agent_detected" },
      { type: "pane.created" },
      { type: "pane.closed" },
      { type: "pane.exited" }
    ]
    for (var i = 0; i < (paneIds || []).length; i++) {
      subscriptions.push({ type: "pane.agent_status_changed", pane_id: paneIds[i] })
    }
    return JSON.stringify({ id: "herd-events", method: "events.subscribe", params: { subscriptions: subscriptions } })
  }

  function handleLine(line) {
    var text = String(line || "")
    if (text.length > maxLine) { bridge.running = false; return }
    text = text.trim()
    if (text === "") return
    var message
    try { message = JSON.parse(text) } catch (e) { return }
    if (message.id === "herd-events") {
      // The reply to our subscribe request: a result means we're live, an
      // error (e.g. an older server without events) means stay on polling.
      _subscribed = !!message.result
      if (!message.result) bridge.running = false
      return
    }
    nudge.restart()
  }

  function connect() {
    if (bridge.running || socketPath === "" || !enabled) return
    _subscribedFor = paneKey
    bridge.command = ["python3", bridgeScript, socketPath, subscribeRequest()]
    bridge.running = true
  }

  // A pane set change needs a fresh subscription; herdr has no "add one"
  // call, so drop the bridge and let the reconnect timer rebuild it.
  onPaneKeyChanged: if (bridge.running && paneKey !== _subscribedFor) bridge.running = false
  onEnabledChanged: if (!enabled) bridge.running = false

  Process {
    id: bridge
    running: false
    command: []
    stdout: SplitParser { onRead: function(data) { root.handleLine(data) } }
    onRunningChanged: if (!running) root._subscribed = false
    // Exit 3 (oversized frame) and 4 (budget spent) are the bridge protecting
    // the shell; the reconnect timer brings it back with a fresh budget.
    onExited: function(exitCode) { root._subscribed = false }
  }

  // Doubles as the first connect, the reconnect after a drop, and the
  // resubscribe after the pane set changed.
  Timer {
    interval: 2000
    repeat: true
    running: root.enabled && root.socketPath !== "" && !bridge.running
    triggeredOnStart: true
    onTriggered: root.connect()
  }

  // Events arrive in bursts (a status flip often comes with a title change);
  // fold a burst into one poll.
  Timer {
    id: nudge
    interval: 150
    repeat: false
    onTriggered: root.poke()
  }
}
