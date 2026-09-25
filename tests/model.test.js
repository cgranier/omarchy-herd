// Run with: node tests/model.test.js
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const Model = require("../Model.js")

const fixture = (name) => fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")
let passed = 0
function test(name, fn) { fn(); passed += 1; console.log("ok - " + name) }

test("parseMachineList reads the TSV", () => {
  const machines = Model.parseMachineList(fixture("machine-list.tsv"))
  assert.strictEqual(machines.length, 3)
  assert.deepStrictEqual(machines[0], { id: "aaa111", label: "buildbox", host: "buildbox.example.ts.net", session: "default", enabled: true })
  assert.strictEqual(machines[1].enabled, false)
  assert.deepStrictEqual(Model.parseMachineList("garbage\n\n"), [])
})

test("selectMachines honours empty, allow-list, and none", () => {
  const machines = Model.parseMachineList(fixture("machine-list.tsv"))
  assert.deepStrictEqual(Model.selectMachines(machines, "").map((m) => m.label), ["buildbox", "nas"])
  assert.deepStrictEqual(Model.selectMachines(machines, " nas , laptop ").map((m) => m.label), ["nas"])
  assert.deepStrictEqual(Model.selectMachines(machines, "None"), [])
})

test("parseAgentList shapes and sorts agents", () => {
  const parsed = Model.parseAgentList(fixture("agent-list.json"), "buildbox")
  assert.strictEqual(parsed.ok, true)
  assert.deepStrictEqual(parsed.agents.map((a) => a.status), ["blocked", "working", "idle", "unknown"])
  const blocked = parsed.agents[0]
  assert.strictEqual(blocked.key, "buildbox/term_bbb")
  assert.strictEqual(blocked.name, "migrator")
  assert.strictEqual(blocked.cwd, "~/projects/web/src")
  assert.strictEqual(blocked.title, "Fix login")
  assert.strictEqual(parsed.agents[1].cwd, "~")
  assert.strictEqual(parsed.agents[3].name, "agent")
})

test("parseAgentList surfaces herdr and transport errors", () => {
  const mismatch = Model.parseAgentList(fixture("protocol-mismatch.json"), "local")
  assert.strictEqual(mismatch.ok, false)
  assert.strictEqual(mismatch.errorCode, "protocol_mismatch")
  assert.ok(/settings/.test(mismatch.error))
  assert.strictEqual(Model.parseAgentList("", "local").errorCode, "empty")
  assert.strictEqual(Model.parseAgentList("ssh: connect to host nas port 22: timed out", "nas").errorCode, "not_json")
  assert.strictEqual(Model.parseAgentList('{"result":{}}', "local").errorCode, "shape")
})

test("exitError maps exit codes", () => {
  assert.strictEqual(Model.exitError(124, "").errorCode, "timeout")
  assert.strictEqual(Model.exitError(127, "").errorCode, "missing")
  assert.strictEqual(Model.exitError(1, "Error: connection refused (os error 111)").errorCode, "not_running")
  assert.strictEqual(Model.exitError(255, "\nssh: no route to host\nmore").error, "ssh: no route to host")
})

const agents = Model.parseAgentList(fixture("agent-list.json"), "buildbox").agents
const machines = [
  { label: "local", displayName: "desk", polled: true, ok: true, error: "", agents: [] },
  { label: "buildbox", polled: true, ok: true, error: "", agents: agents },
  { label: "nas", polled: true, ok: false, error: "Timed out", agents: [] },
  { label: "later", polled: false, ok: false, error: "", agents: [] }
]

test("countStatuses and labels", () => {
  const counts = Model.countStatuses(machines)
  assert.deepStrictEqual(counts, { total: 4, blocked: 1, working: 1, done: 0, idle: 1, unknown: 1, offline: 1 })
  assert.strictEqual(Model.barLabel(counts, true), Model.GLYPHS.herd)
  assert.strictEqual(Model.barLabel(counts, false), Model.GLYPHS.blocked + " 1  " + Model.GLYPHS.working + " 1")
  assert.strictEqual(Model.barLabel(Model.countStatuses([]), false), Model.GLYPHS.herd)
  assert.strictEqual(Model.summaryText(counts, 4), "1 blocked · 1 working · 1 idle · 1 unknown · 1 unreachable · 4 machines")
  assert.strictEqual(Model.summaryText({ total: 0, blocked: 0, working: 0, done: 0, idle: 0, unknown: 0, offline: 1 }, 1), "1 unreachable")
  assert.strictEqual(Model.summaryText(Model.countStatuses([]), 1), "No agents running")
})

test("buildRows lifts waiting agents on top and folds idle ones", () => {
  const rows = Model.buildRows(machines)
  assert.deepStrictEqual(rows.map((r) => r.type),
    ["header", "agent",                       // NEEDS YOU
     "header", "note",                        // desk: no agents
     "header", "agent", "agent", "group",     // buildbox: working, unknown, idle group
     "header", "note",                        // nas: unreachable
     "header", "note"])                       // later: checking
  assert.strictEqual(rows[0].text, "NEEDS YOU · 1")
  assert.strictEqual(rows[0].attention, true)
  assert.strictEqual(rows[1].agent.status, "blocked")
  assert.strictEqual(rows[1].showMachine, true)
  assert.strictEqual(rows[2].text, "DESK")
  assert.strictEqual(rows[3].text, "No agents")
  assert.strictEqual(rows[4].text, "BUILDBOX · 4")
  assert.deepStrictEqual([rows[5].agent.status, rows[6].agent.status], ["working", "unknown"])
  assert.deepStrictEqual({ text: rows[7].text, expanded: rows[7].expanded, count: rows[7].count }, { text: "1 idle", expanded: false, count: 1 })
  assert.strictEqual(rows[8].text, "NAS · UNREACHABLE")
  assert.strictEqual(rows[9].urgent, true)
  assert.strictEqual(rows[11].text, "Checking…")
  const cursor = Model.cursorRows(rows)
  assert.deepStrictEqual(cursor.map((r) => r.cursorIndex), [0, 1, 2, 3])
  assert.deepStrictEqual(cursor.map((r) => r.type), ["agent", "agent", "agent", "group"])
})

test("buildRows expands a group and can skip collapsing", () => {
  const open = Model.buildRows(machines, { expanded: { buildbox: true } })
  const group = open.findIndex((r) => r.type === "group")
  assert.strictEqual(open[group].expanded, true)
  assert.strictEqual(open[group + 1].agent.status, "idle")
  assert.deepStrictEqual(Model.cursorRows(open).map((r) => r.cursorIndex), [0, 1, 2, 3, 4])

  const flat = Model.buildRows(machines, { collapseIdle: false })
  assert.strictEqual(flat.filter((r) => r.type === "group").length, 0)
  assert.strictEqual(flat.filter((r) => r.type === "agent").length, 4)
})

test("buildRows notes a machine whose agents all moved to the top", () => {
  const blockedOnly = [{ label: "solo", polled: true, ok: true, error: "", agents: [agents[0]] }]
  const rows = Model.buildRows(blockedOnly)
  assert.deepStrictEqual(rows.map((r) => r.type), ["header", "agent", "header", "note"])
  assert.strictEqual(rows[3].text, "All listed above")
})

test("transitions only fire on a change into a watched status", () => {
  const before = { "buildbox/term_bbb": "working", "buildbox/term_ccc": "working", "buildbox/term_aaa": "working" }
  const changed = Model.transitions(before, agents, ["blocked", "done"])
  assert.deepStrictEqual(changed.map((a) => a.key), ["buildbox/term_bbb"])
  assert.deepStrictEqual(Model.transitions({}, agents, ["blocked", "done"]), [])
  assert.deepStrictEqual(Model.transitions(Model.statusMap(agents), agents, ["blocked", "done"]), [])
  assert.deepStrictEqual(Model.transitions(before, agents, []), [])
})

test("durations, meta, and notification text", () => {
  assert.strictEqual(Model.durationText(0, 1000), "")
  assert.strictEqual(Model.durationText(1000, 31000), "just now")
  assert.strictEqual(Model.durationText(0 + 1, 1 + 5 * 60000), "5m")
  assert.strictEqual(Model.durationText(1, 1 + 125 * 60000), "2h 5m")
  assert.strictEqual(Model.durationText(1, 1 + 50 * 3600000), "2d")
  assert.strictEqual(Model.agentMeta(agents[0], 1, 1 + 5 * 60000), "blocked · 5m · ~/projects/web/src")
  assert.strictEqual(Model.agentMeta(agents[0], 0, 1, true), "blocked · buildbox · ~/projects/web/src")
  assert.deepStrictEqual(Model.notificationText(agents[0], "local"), { headline: "migrator needs you on buildbox", body: "~/projects/web/src" })
  const local = Object.assign({}, agents[1], { machine: "local", status: "done" })
  assert.strictEqual(Model.notificationText(local, "local").headline, "claude finished")
})

test("replies are bounded: an oversized reply is refused whole, long lists are cut", () => {
  const huge = JSON.stringify({ result: { agents: [] } }) + " ".repeat(Model.MAX_REPLY_BYTES)
  const refused = Model.parseAgentList(huge, "local", "here")
  assert.deepStrictEqual([refused.ok, refused.errorCode], [false, "too_large"])
  const many = JSON.stringify({ result: { agents: Array.from({ length: Model.MAX_AGENTS + 20 }, (_, i) => ({ agent: "claude", agent_status: "idle", pane_id: "w1:p" + i })) } })
  assert.strictEqual(Model.parseAgentList(many, "local", "here").agents.length, Model.MAX_AGENTS)
  const rows = Array.from({ length: Model.MAX_MACHINES + 5 }, (_, i) => `id${i}\tm${i}\tm${i}\tdefault\tenabled`).join("\n")
  assert.strictEqual(Model.parseMachineList(rows).length, Model.MAX_MACHINES)
})

test("ids from herdr are shape-checked before they can reach argv", () => {
  assert.strictEqual(Model.safeId("term_65bdfdd3b002c1"), "term_65bdfdd3b002c1")
  assert.strictEqual(Model.safeId("w5:p1"), "w5:p1")
  for (const bad of ["-x", "a b", "$(id)", "x;y", "", "a".repeat(200)]) assert.strictEqual(Model.safeId(bad), "", bad)
  const agent = Model.parseAgentList(JSON.stringify({ result: { agents: [{ agent: "claude", agent_status: "idle", terminal_id: "--evil", pane_id: "w1:p1" }] } }), "local", "here").agents[0]
  assert.strictEqual(agent.terminalId, "")
})

console.log("\n" + passed + " tests passed")
