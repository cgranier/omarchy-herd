import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Polls `herdr agent list` for one machine. Every machine gets its own poller
// so a slow or offline box only ever delays itself.
Item {
  id: root

  // "local" for this machine's server, otherwise a `herdr machine list` label.
  property string label: "local"
  property string displayName: label
  property string sshHost: ""
  property string session: "default"
  property string herdrPath: ""
  property int intervalSec: 20
  property int timeoutSec: 12

  property bool polled: false
  property bool ok: false
  property var agents: []
  property string error: ""
  property string errorCode: ""
  property int failures: 0

  signal updated()

  readonly property bool isLocal: label === "local"
  // Back off while a machine stays unreachable: 1x, 2x, 4x ... capped at 5 min.
  readonly property int effectiveIntervalMs: Math.min(300, intervalSec * Math.pow(2, Math.min(failures, 4))) * 1000

  property bool _again: false

  function poll() {
    if (herdrPath === "") return
    // A nudge that lands mid-poll would otherwise be lost, and the poll in
    // flight may predate the change it was announcing.
    if (pollProcess.running) { _again = true; return }
    // Bounded at the producer: timeout wraps herdr itself (so it is the one
    // killed), and head caps what reaches the shell on each stream. A reply
    // cut at the cap is refused by the parser as too large.
    var args = [herdrPath]
    if (!isLocal) args = args.concat(["--machine", label])
    args = args.concat(["agent", "list"])
    pollProcess.command = ["bash", "-o", "pipefail", "-c",
      'timeout "$1" "${@:2}" 2> >(head -c 65536 >&2) | head -c ' + String(Model.MAX_REPLY_BYTES),
      "bash", String(timeoutSec)].concat(args)
    pollProcess.running = true
  }

  // A manual refresh shouldn't wait out the backoff.
  function pollNow() {
    failures = 0
    poll()
  }

  function apply(exitCode, stdout, stderr) {
    var reply = String(stdout || "").trim() !== "" ? stdout : stderr
    var parsed = Model.parseAgentList(reply, label, displayName)
    if (!parsed.ok && (parsed.errorCode === "empty" || parsed.errorCode === "not_json")) {
      var failure = Model.exitError(exitCode, stderr || stdout)
      parsed.error = failure.error
      parsed.errorCode = failure.errorCode
    }
    polled = true
    ok = parsed.ok
    // Keep the last known agents through a blip so a single timeout doesn't
    // blank a machine and then re-announce everything when it returns.
    if (parsed.ok || failures >= 2) agents = parsed.agents
    error = parsed.error
    errorCode = parsed.errorCode
    failures = parsed.ok ? 0 : failures + 1
    updated()
  }

  onHerdrPathChanged: if (herdrPath !== "") poll()

  Timer {
    interval: root.effectiveIntervalMs
    repeat: true
    running: root.herdrPath !== ""
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Process {
    id: pollProcess
    running: false
    command: []
    stdout: StdioCollector { id: pollStdout; waitForEnd: true }
    stderr: StdioCollector { id: pollStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.apply(exitCode, String(pollStdout.text || ""), String(pollStderr.text || ""))
      if (root._again) { root._again = false; root.poll() }
    }
  }
}
