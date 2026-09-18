// Pure parsing and shaping logic for Herd. No QML imports, so the same file
// runs under node for tests (see tests/model.test.js).

var STATUS_ORDER = ["blocked", "working", "done", "idle", "unknown"]

function glyph(codePoint) {
  return String.fromCodePoint(codePoint)
}

var GLYPHS = {
  herd: glyph(0xF0CC6),     // md-sheep
  blocked: glyph(0xF071),   // fa-warning
  working: glyph(0xF013),   // fa-cog
  done: glyph(0xF00C),      // fa-check
  idle: glyph(0xF186),      // fa-moon
  unknown: glyph(0xF128),   // fa-question
  offline: glyph(0xF127),   // fa-chain-broken
  expand: glyph(0xF078),    // fa-chevron-down
  collapse: glyph(0xF077)   // fa-chevron-up
}

function statusGlyph(status) {
  return GLYPHS[status] || GLYPHS.unknown
}

function normalizeStatus(status) {
  var value = String(status || "unknown")
  return STATUS_ORDER.indexOf(value) === -1 ? "unknown" : value
}

// `herdr machine list` prints TSV: id, label, ssh host, session, enabled.
function parseMachineList(raw) {
  var machines = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var cols = lines[i].split("\t")
    if (cols.length < 5) continue
    var label = cols[1].trim()
    if (label === "") continue
    machines.push({
      id: cols[0].trim(),
      label: label,
      host: cols[2].trim(),
      session: cols[3].trim(),
      enabled: cols[4].trim() === "enabled"
    })
  }
  return machines
}

// Which remote machines to poll: the `machines` setting is a comma-separated
// allow-list of labels, empty means every enabled machine, "none" means none.
function selectMachines(machines, setting) {
  var wanted = String(setting || "").trim()
  if (wanted.toLowerCase() === "none") return []
  var labels = []
  if (wanted !== "") {
    var parts = wanted.split(",")
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i].trim()
      if (part !== "") labels.push(part)
    }
  }
  var result = []
  for (var m = 0; m < (machines || []).length; m++) {
    var machine = machines[m]
    if (!machine.enabled) continue
    if (labels.length > 0 && labels.indexOf(machine.label) === -1) continue
    result.push(machine)
  }
  return result
}

function shortenPath(path) {
  var value = String(path || "")
  value = value.replace(/^\/home\/[^\/]+/, "~").replace(/^\/Users\/[^\/]+/, "~")
  return value
}

function agentFromInfo(info, machineLabel, machineName) {
  var name = info.name || info.display_agent || info.agent || "agent"
  var cwd = info.foreground_cwd || info.cwd || ""
  return {
    key: machineLabel + "/" + String(info.terminal_id || info.pane_id || ""),
    machine: machineLabel,
    machineName: String(machineName || machineLabel),
    terminalId: String(info.terminal_id || ""),
    paneId: String(info.pane_id || ""),
    workspaceId: String(info.workspace_id || ""),
    name: String(name),
    kind: String(info.agent || ""),
    status: normalizeStatus(info.agent_status),
    cwd: shortenPath(cwd),
    title: String(info.title || info.terminal_title_stripped || ""),
    focused: info.focused === true
  }
}

// Turns one `herdr agent list` reply into { ok, agents, error, errorCode }.
// herdr answers errors as JSON too ({"error":{"code","message"}}), and a dead
// ssh hop or a missing binary answers with plain stderr text instead.
function parseAgentList(raw, machineLabel, machineName) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, agents: [], errorCode: "empty", error: "No reply" }
  var doc
  try {
    doc = JSON.parse(text)
  } catch (e) {
    return { ok: false, agents: [], errorCode: "not_json", error: firstLine(text) }
  }
  if (doc && doc.error) {
    return {
      ok: false,
      agents: [],
      errorCode: String(doc.error.code || "error"),
      error: friendlyError(String(doc.error.code || ""), String(doc.error.message || "herdr error"))
    }
  }
  var list = doc && doc.result && doc.result.agents
  if (!list || typeof list.length !== "number") {
    return { ok: false, agents: [], errorCode: "shape", error: "Unexpected herdr reply" }
  }
  var agents = []
  for (var i = 0; i < list.length; i++) agents.push(agentFromInfo(list[i] || {}, machineLabel, machineName))
  agents.sort(compareAgents)
  return { ok: true, agents: agents, errorCode: "", error: "" }
}

function friendlyError(code, message) {
  if (code === "protocol_mismatch") return "herdr client is older than the server. Set the herdr binary in this widget's settings."
  return message
}

// What a poll that produced no usable stdout means, from its exit code.
function exitError(exitCode, stderr) {
  if (exitCode === 124) return { errorCode: "timeout", error: "Timed out" }
  if (exitCode === 127) return { errorCode: "missing", error: "herdr not found" }
  var line = firstLine(stderr)
  if (/no such file|connection refused|not running|no server/i.test(line)) {
    return { errorCode: "not_running", error: "herdr server is not running" }
  }
  return { errorCode: "failed", error: line || ("herdr exited " + exitCode) }
}

function firstLine(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line !== "") return line.length > 120 ? line.substring(0, 117) + "…" : line
  }
  return ""
}

function compareAgents(a, b) {
  var byStatus = STATUS_ORDER.indexOf(a.status) - STATUS_ORDER.indexOf(b.status)
  if (byStatus !== 0) return byStatus
  return a.cwd < b.cwd ? -1 : a.cwd > b.cwd ? 1 : 0
}

function countStatuses(machines) {
  var counts = { total: 0, blocked: 0, working: 0, done: 0, idle: 0, unknown: 0, offline: 0 }
  for (var m = 0; m < (machines || []).length; m++) {
    var machine = machines[m]
    if (machine.polled && !machine.ok) counts.offline += 1
    for (var i = 0; i < machine.agents.length; i++) {
      counts.total += 1
      counts[machine.agents[i].status] += 1
    }
  }
  return counts
}

// Bar label: the glyph alone when nothing is active, otherwise the counts
// that matter, most urgent first. Vertical bars only have room for the glyph.
function barLabel(counts, vertical) {
  if (vertical) return GLYPHS.herd
  var parts = []
  if (counts.blocked > 0) parts.push(GLYPHS.blocked + " " + counts.blocked)
  if (counts.working > 0) parts.push(GLYPHS.working + " " + counts.working)
  if (counts.done > 0) parts.push(GLYPHS.done + " " + counts.done)
  return parts.length === 0 ? GLYPHS.herd : parts.join("  ")
}

function summaryText(counts, machineCount) {
  if (counts.total === 0 && counts.offline === 0) return "No agents running"
  var parts = []
  for (var i = 0; i < STATUS_ORDER.length; i++) {
    var status = STATUS_ORDER[i]
    if (counts[status] > 0) parts.push(counts[status] + " " + status)
  }
  if (counts.offline > 0) parts.push(counts.offline + " unreachable")
  var text = parts.join(" · ")
  if (machineCount > 1) text += " · " + machineCount + " machines"
  return text
}

// Statuses that mean "a human is wanted": stuck waiting, or finished and
// ready for review.
var ATTENTION = ["blocked", "done"]

function needsAttention(agent) {
  return ATTENTION.indexOf(agent.status) !== -1
}

// Flat row list for the panel. Agents that need a human are lifted out of
// their machines into a "NEEDS YOU" section on top, blocked before done.
// Below that comes a header per machine with its remaining agents; idle ones
// fold into a single group row unless that machine is in `expanded`.
// `cursorIndex` numbers the rows the keyboard cursor can land on: agents and
// idle groups.
function buildRows(machines, options) {
  var collapseIdle = !options || options.collapseIdle !== false
  var expanded = (options && options.expanded) || {}
  var rows = []
  var cursorIndex = 0

  function pushAgent(agent, showMachine) {
    rows.push({ type: "agent", machine: agent.machine, agent: agent, showMachine: showMachine, cursorIndex: cursorIndex })
    cursorIndex += 1
  }

  var waiting = []
  for (var w = 0; w < (machines || []).length; w++) {
    for (var a = 0; a < machines[w].agents.length; a++) {
      if (needsAttention(machines[w].agents[a])) waiting.push(machines[w].agents[a])
    }
  }
  waiting.sort(compareAgents)
  if (waiting.length > 0) {
    rows.push({ type: "header", machine: "", text: "NEEDS YOU · " + waiting.length, ok: true, attention: true })
    for (var n = 0; n < waiting.length; n++) pushAgent(waiting[n], true)
  }

  for (var m = 0; m < (machines || []).length; m++) {
    var machine = machines[m]
    var active = []
    var idle = []
    for (var i = 0; i < machine.agents.length; i++) {
      var agent = machine.agents[i]
      if (needsAttention(agent)) continue
      if (collapseIdle && agent.status === "idle") idle.push(agent)
      else active.push(agent)
    }

    rows.push({ type: "header", machine: machine.label, text: machineHeader(machine), ok: machine.ok || !machine.polled, attention: false })
    if (machine.polled && !machine.ok) {
      rows.push({ type: "note", machine: machine.label, text: machine.error, urgent: true })
    } else if (machine.agents.length === 0) {
      rows.push({ type: "note", machine: machine.label, text: machine.polled ? "No agents" : "Checking…", urgent: false })
    } else if (active.length === 0 && idle.length === 0) {
      rows.push({ type: "note", machine: machine.label, text: "All listed above", urgent: false })
    }
    for (var k = 0; k < active.length; k++) pushAgent(active[k], false)
    if (idle.length > 0) {
      var open = expanded[machine.label] === true
      rows.push({ type: "group", machine: machine.label, count: idle.length, expanded: open,
        text: idle.length + " idle", cursorIndex: cursorIndex })
      cursorIndex += 1
      if (open) for (var d = 0; d < idle.length; d++) pushAgent(idle[d], false)
    }
  }
  return rows
}

function machineHeader(machine) {
  var label = String(machine.displayName || machine.label).toUpperCase()
  if (machine.polled && !machine.ok) return label + " · UNREACHABLE"
  if (machine.agents.length === 0) return label
  return label + " · " + machine.agents.length
}

// Rows the cursor can land on, in order; index in this list === cursorIndex.
function cursorRows(rows) {
  var result = []
  for (var i = 0; i < (rows || []).length; i++) {
    if (rows[i].type === "agent" || rows[i].type === "group") result.push(rows[i])
  }
  return result
}

// Agents whose status moved into a notify-worthy state since the last poll.
// `previous` maps agent key -> status. An agent seen for the first time never
// notifies, so opening the shell doesn't replay the fleet's current state.
function transitions(previous, agents, notifyOn) {
  var result = []
  for (var i = 0; i < (agents || []).length; i++) {
    var agent = agents[i]
    var before = previous ? previous[agent.key] : undefined
    if (before === undefined || before === agent.status) continue
    if (notifyOn.indexOf(agent.status) === -1) continue
    result.push(agent)
  }
  return result
}

function statusMap(agents) {
  var map = {}
  for (var i = 0; i < (agents || []).length; i++) map[agents[i].key] = agents[i].status
  return map
}

function durationText(sinceMs, nowMs) {
  if (!sinceMs) return ""
  var seconds = Math.max(0, Math.floor((nowMs - sinceMs) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h " + (minutes % 60) + "m"
  return Math.floor(hours / 24) + "d"
}

function agentMeta(agent, sinceMs, nowMs, showMachine) {
  var parts = [agent.status]
  if (showMachine && agent.machineName) parts.push(agent.machineName)
  var duration = durationText(sinceMs, nowMs)
  if (duration !== "") parts.push(duration)
  if (agent.cwd !== "") parts.push(agent.cwd)
  return parts.join(" · ")
}

function notificationText(agent, localLabel) {
  var where = agent.machine === localLabel ? "" : " on " + agent.machine
  var headline = agent.status === "blocked"
    ? agent.name + " needs you" + where
    : agent.name + " finished" + where
  return { headline: headline, body: agent.cwd }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    GLYPHS: GLYPHS,
    statusGlyph: statusGlyph,
    parseMachineList: parseMachineList,
    selectMachines: selectMachines,
    shortenPath: shortenPath,
    parseAgentList: parseAgentList,
    exitError: exitError,
    countStatuses: countStatuses,
    barLabel: barLabel,
    summaryText: summaryText,
    buildRows: buildRows,
    cursorRows: cursorRows,
    needsAttention: needsAttention,
    transitions: transitions,
    statusMap: statusMap,
    durationText: durationText,
    agentMeta: agentMeta,
    notificationText: notificationText
  }
}
