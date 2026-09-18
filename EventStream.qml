import QtQuick
import Quickshell
import Quickshell.Io

// Listens on the local herdr socket so state changes show up at once instead
// of on the next poll. herdr only offers status events per pane, so this
// subscribes for each known agent pane plus the global "panes came or went"
// events, and treats every event as a nudge to poll — the poll stays the one
// source of truth, and keeps running (slower) in case the stream drops.
Item {
  id: root

  property string socketPath: ""
  property var paneIds: []
  property bool enabled: true

  readonly property bool connected: socket.connected && _subscribed
  property bool _subscribed: false
  property string _subscribedFor: ""

  signal poke()

  readonly property string paneKey: (paneIds || []).slice().sort().join(",")

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
    var text = String(line || "").trim()
    if (text === "") return
    var message
    try { message = JSON.parse(text) } catch (e) { return }
    if (message.id === "herd-events") {
      // The reply to our subscribe request: a result means we're live, an
      // error (e.g. an older server without events) means stay on polling.
      _subscribed = !!message.result
      if (!message.result) socket.connected = false
      return
    }
    nudge.restart()
  }

  // A pane set change needs a fresh subscription; herdr has no "add one"
  // call, so drop the connection and let the reconnect timer rebuild it.
  onPaneKeyChanged: if (socket.connected && paneKey !== _subscribedFor) socket.connected = false
  onEnabledChanged: if (!enabled) socket.connected = false

  Socket {
    id: socket
    path: root.socketPath
    connected: false
    parser: SplitParser { onRead: function(data) { root.handleLine(data) } }

    onConnectionStateChanged: {
      if (connected) {
        root._subscribedFor = root.paneKey
        write(root.subscribeRequest() + "\n")
        flush()
      } else {
        root._subscribed = false
      }
    }
  }

  // Doubles as the first connect, the reconnect after a drop, and the
  // resubscribe after the pane set changed.
  Timer {
    interval: 2000
    repeat: true
    running: root.enabled && root.socketPath !== "" && !socket.connected
    triggeredOnStart: true
    onTriggered: socket.connected = true
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
