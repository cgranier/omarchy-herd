import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Fleet state: finds herdr, discovers saved machines, runs one MachinePoller
// per target, and folds their results into counts, panel rows, and toasts.
Item {
  id: root

  property var settings: ({})
  // Asked at toast time: only one widget instance (there is one per monitor)
  // should send notifications.
  property var isNotifier: function() { return true }

  property string herdrPath: ""
  property string hostName: "local"
  property bool herdrMissing: false
  property var targets: []
  property var machines: []
  property var rows: []
  property var cursorRows: []
  // Machines whose idle group the user has opened in the panel.
  property var expandedMachines: ({})
  property var counts: Model.countStatuses([])
  property string summary: "Checking…"
  property double now: Date.now()

  property var localPaneIds: []
  readonly property bool liveEvents: stream.connected
  readonly property string socketPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/herdr/herdr.sock"

  property var _statuses: ({})
  property var _since: ({})
  property bool _baselined: false
  property string _lastAnnounced: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 20, 5, 3600)
  readonly property bool includeLocal: setting("includeLocal", true) !== false
  readonly property string focusScript: String(Qt.resolvedUrl("bin/herd-focus")).replace(/^file:\/\//, "")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function notifyStatuses() {
    var list = []
    if (setting("notifyBlocked", true) !== false) list.push("blocked")
    if (setting("notifyDone", true) !== false) list.push("done")
    return list
  }

  // Resolve the herdr binary, this host's name, and the saved machines in one
  // shot. A configured path wins; otherwise prefer ~/.local/bin, because a
  // self-updated herdr there is newer than a packaged one and an older client
  // is refused by the server with protocol_mismatch.
  function discover() {
    if (discoverProcess.running) return
    // Deadline: a stalled herdr must not hold discovery open forever.
    discoverProcess.command = ["timeout", "10", "sh", "-c",
      'p="$1"; if [ -z "$p" ]; then for c in "$HOME/.local/bin/herdr" "$(command -v herdr 2>/dev/null)"; do ' +
      'if [ -n "$c" ] && [ -x "$c" ]; then p="$c"; break; fi; done; fi; ' +
      '[ -n "$p" ] && [ -x "$p" ] || exit 127; echo "$p"; uname -n; "$p" machine list 2>/dev/null | head -c 262144; exit 0',
      "sh", String(setting("herdrPath", "") || "")]
    discoverProcess.running = true
  }

  function applyDiscovery(exitCode, stdout) {
    if (exitCode !== 0) {
      herdrMissing = true
      herdrPath = ""
      summary = "herdr not found"
      return
    }
    var lines = String(stdout || "").split("\n")
    herdrMissing = false
    hostName = (lines[1] || "local").trim() || "local"
    var remotes = Model.selectMachines(Model.parseMachineList(lines.slice(2).join("\n")), setting("machines", ""))
    var next = []
    if (includeLocal) next.push({ label: "local", displayName: hostName, host: "", session: "default" })
    for (var i = 0; i < remotes.length; i++) {
      next.push({ label: remotes[i].label, displayName: remotes[i].label, host: remotes[i].host, session: remotes[i].session })
    }
    // Reassigning the model rebuilds every poller and drops its state, so only
    // do it when the set of targets really changed.
    if (JSON.stringify(next) !== JSON.stringify(targets)) targets = next
    herdrPath = String(lines[0] || "").trim()
  }

  function refresh() {
    discover()
    for (var i = 0; i < pollers.count; i++) {
      var poller = pollers.itemAt(i)
      if (poller) poller.pollNow()
    }
  }

  function recompute() {
    var list = []
    var agents = []
    for (var i = 0; i < pollers.count; i++) {
      var poller = pollers.itemAt(i)
      if (!poller) continue
      list.push({
        label: poller.label, displayName: poller.displayName, host: poller.sshHost, session: poller.session,
        polled: poller.polled, ok: poller.ok, error: poller.error, errorCode: poller.errorCode, agents: poller.agents
      })
      agents = agents.concat(poller.agents)
      if (poller.isLocal) {
        var panes = []
        for (var p = 0; p < poller.agents.length; p++) if (poller.agents[p].paneId !== "") panes.push(poller.agents[p].paneId)
        if (panes.slice().sort().join(",") !== localPaneIds.slice().sort().join(",")) localPaneIds = panes
      }
    }

    var stamp = Date.now()
    var since = {}
    for (var a = 0; a < agents.length; a++) {
      var agent = agents[a]
      var changed = _statuses[agent.key] !== undefined && _statuses[agent.key] !== agent.status
      since[agent.key] = changed ? stamp : (_since[agent.key] || 0)
    }

    if (_baselined && isNotifier()) announce(Model.transitions(_statuses, agents, notifyStatuses()), list)

    // Merge rather than replace: a machine that blips keeps its agents' last
    // status, so they don't look brand new (and stay silent) when it returns.
    var statuses = Model.statusMap(agents)
    for (var key in _statuses) if (statuses[key] === undefined && machineDown(list, key)) statuses[key] = _statuses[key]
    _statuses = statuses
    _since = since
    if (allPolled(list)) _baselined = true

    now = stamp
    machines = list
    counts = Model.countStatuses(list)
    rebuildRows()
    summary = herdrMissing ? "herdr not found" : Model.summaryText(counts, list.length)
  }

  function rebuildRows() {
    rows = Model.buildRows(machines, { collapseIdle: setting("collapseIdle", true) !== false, expanded: expandedMachines })
    cursorRows = Model.cursorRows(rows)
  }

  function toggleGroup(label) {
    var next = {}
    for (var key in expandedMachines) next[key] = expandedMachines[key]
    next[label] = !next[label]
    expandedMachines = next
    rebuildRows()
  }

  function pollLocal() {
    for (var i = 0; i < pollers.count; i++) {
      var poller = pollers.itemAt(i)
      if (poller && poller.isLocal) poller.poll()
    }
  }

  function machineDown(list, agentKey) {
    var label = String(agentKey).split("/")[0]
    for (var i = 0; i < list.length; i++) if (list[i].label === label) return list[i].polled && !list[i].ok
    return false
  }

  function allPolled(list) {
    for (var i = 0; i < list.length; i++) if (!list[i].polled) return false
    return list.length > 0
  }

  function machineFor(label) {
    for (var i = 0; i < machines.length; i++) if (machines[i].label === label) return machines[i]
    return null
  }

  // Null when any of the pieces is not a plainly shaped id, in which case
  // there is nothing safe to run.
  function focusCommand(agent) {
    var machine = machineFor(agent.machine)
    var label = Model.safeId(agent.machine)
    var host = machine ? Model.safeId(machine.host || "") : ""
    var session = machine ? Model.safeId(machine.session || "default") : "default"
    if (label === "" || agent.terminalId === "" || (machine && machine.host && host === "") || session === "") return null
    return ["bash", focusScript, herdrPath, label, host, agent.terminalId, session]
  }

  function focusAgent(agent) {
    if (!agent || herdrPath === "") return
    var command = focusCommand(agent)
    if (command) Quickshell.execDetached(command)
  }

  function announce(changed, list) {
    for (var i = 0; i < changed.length; i++) {
      var agent = changed[i]
      _lastAnnounced = agent.key + " -> " + agent.status
      var text = Model.notificationText(agent, "local")
      // Do Not Disturb only lets through critical alerts sent under the bare
      // "notify-send" identity, so opting in means borrowing that identity
      // (and its trade-off: such toasts are not kept in history).
      var urgent = agent.status === "blocked" && setting("blockedBypassesDnd", false) === true
      var command = ["omarchy-notification-send", "--app-name", urgent ? "notify-send" : "Herd",
        "-g", Model.statusGlyph(agent.status),
        "-u", urgent ? "critical" : agent.status === "blocked" ? "normal" : "low",
        text.headline]
      if (text.body !== "") command.push(text.body)
      var focus = focusCommand(agent)
      Quickshell.execDetached(focus ? command.concat(["--exec"], focus) : command)
    }
  }

  function debugState() {
    var notifier = false
    var notifierError = ""
    try { notifier = isNotifier() === true } catch (e) { notifierError = String(e) }
    return { baselined: _baselined, notifier: notifier, notifierError: notifierError, herdrPath: herdrPath,
      liveEvents: liveEvents, localPanes: localPaneIds.length, tracked: Object.keys(_statuses).length, notifyOn: notifyStatuses(), lastAnnounced: _lastAnnounced }
  }

  // Sends a sample toast through the real path, for checking notifications.
  function testToast() {
    var agent = firstAgent()
    if (!agent) return "no agents to test with"
    var sample = JSON.parse(JSON.stringify(agent))
    sample.status = "blocked"
    announce([sample], machines)
    return "sent for " + sample.key
  }

  // The agent most in need of a human: first blocked, else first done. They
  // sort to the top of the panel, so that is simply the first agent row.
  function firstWaiting() {
    for (var i = 0; i < cursorRows.length; i++) {
      var row = cursorRows[i]
      if (row.type === "agent" && Model.needsAttention(row.agent)) return row.agent
    }
    return null
  }

  function firstAgent() {
    for (var m = 0; m < machines.length; m++) if (machines[m].agents.length > 0) return machines[m].agents[0]
    return null
  }

  function sinceFor(agent) {
    return agent ? (_since[agent.key] || 0) : 0
  }

  onSettingsChanged: { discover(); rebuildRows() }
  Component.onCompleted: discover()

  // Machines come and go rarely; rediscover on a slow clock.
  Timer {
    interval: 300000
    repeat: true
    running: true
    onTriggered: root.discover()
  }

  // Keeps "for 3m" labels moving between polls.
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.now = Date.now()
  }

  Repeater {
    id: pollers
    model: root.targets

    MachinePoller {
      required property var modelData
      label: modelData.label
      displayName: modelData.displayName
      sshHost: modelData.host
      session: modelData.session
      herdrPath: root.herdrPath
      // The local socket answers in milliseconds; remotes cost an ssh hop.
      // With the event stream up, the local poll is only a safety net.
      intervalSec: modelData.label === "local" ? (root.liveEvents ? 30 : 5) : root.refreshIntervalSec
      timeoutSec: modelData.label === "local" ? 5 : 12
      onUpdated: root.recompute()
    }
  }

  EventStream {
    id: stream
    socketPath: root.socketPath
    paneIds: root.localPaneIds
    enabled: root.includeLocal && root.herdrPath !== ""
    onPoke: root.pollLocal()
  }

  Process {
    id: discoverProcess
    running: false
    command: []
    stdout: StdioCollector { id: discoverStdout; waitForEnd: true }
    onExited: function(exitCode) { root.applyDiscovery(exitCode, String(discoverStdout.text || "")) }
  }
}
