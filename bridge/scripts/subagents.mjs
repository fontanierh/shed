// Spawn subagents through the bridge and inspect them: node scripts/subagents.mjs <pi|prime> <port> <cwd> [model]
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const [agent, port, cwd, model] = process.argv.slice(2);
const token = JSON.parse(readFileSync(`${homedir()}/.agent-remote/config.json`, "utf8")).token;
const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${token}`);
let n = 0;
const waiting = new Map();
const sessions = new Map();
const items = new Map(); // sessionId -> Map(itemId -> item)
const timeline = [];
ws.onmessage = ({ data }) => {
  const m = JSON.parse(data);
  if (m.type === "reply") { const w = waiting.get(m.id); waiting.delete(m.id); m.ok ? w.resolve(m.data) : w.reject(new Error(m.error)); }
  if (m.type === "sessions") for (const s of m.sessions) sessions.set(s.id, s);
  if (m.type === "session") {
    const prev = sessions.get(m.session.id);
    sessions.set(m.session.id, m.session);
    const s = m.session;
    if (s.kind === "subagent" && (!prev || prev.status !== s.status)) timeline.push(`${s.agent} subagent ${s.name ?? s.id} (parent ${s.parentId}) -> ${s.status}`);
  }
  if (m.type === "session_removed") sessions.delete(m.sessionId);
  if (m.type === "snapshot") items.set(m.sessionId, new Map(m.items.map((i) => [i.id, i])));
  if (m.type === "item_add") (items.get(m.sessionId) ?? items.set(m.sessionId, new Map()).get(m.sessionId)).set(m.item.id, m.item);
  if (m.type === "item_patch") { const it = items.get(m.sessionId)?.get(m.itemId); if (it) { Object.assign(it, m.set ?? {}); if (m.append?.text) it.text += m.append.text; if (m.append?.args) it.args = (it.args ?? "") + m.append.args; } }
};
const call = (op, f = {}) => { const id = `s${++n}`; ws.send(JSON.stringify({ id, op, ...f })); return new Promise((resolve, reject) => waiting.set(id, { resolve, reject })); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const show = (id, label) => {
  console.log(`--- ${label}`);
  for (const it of (items.get(id) ?? new Map()).values()) {
    const body = it.kind === "tool" ? `${it.toolName}(${(it.args ?? "").replace(/\s+/g, " ").slice(0, 70)}) [${it.status}] → ${(it.output ?? "").replace(/\s+/g, " ").slice(0, 70)}` : it.text.replace(/\s+/g, " ").slice(0, 110);
    console.log(`  ${it.kind.padEnd(10)} ${body}`);
  }
};
const prompts = {
  prime: 'Run exactly this in your Python REPL: a = await rlm.spawn("Run ls with bash and report the number of entries to your parent via agent_message.send", name="lister"); b = await rlm.spawn("Count the .txt files here with bash and report the count to your parent via agent_message.send", name="txt-counter"); print(a.name, b.name). Then end your turn. When the children report back, summarize their answers in one line.',
  pi: "Use the subagent tool in parallel mode with two tasks for the scout agent: (1) list the files in the current directory, (2) count the .txt files in the current directory. Then summarize both results in one line.",
};
ws.onopen = async () => {
  try {
    const root = await call("create_session", { agent, cwd, model, thinking: "low" });
    await call("attach", { sessionId: root.id });
    await call("send", { sessionId: root.id, text: prompts[agent] });
    const start = Date.now();
    let seenChildren = false;
    while (Date.now() - start < 150000) {
      await sleep(1000);
      const kids = [...sessions.values()].filter((s) => s.parentId === root.id);
      if (kids.length) seenChildren = true;
      const r = sessions.get(root.id);
      if (seenChildren && kids.every((k) => k.status !== "running") && r?.status === "idle" && !r.runningSubagents && Date.now() - start > 20000) break;
    }
    await sleep(3000);
    const kids = [...sessions.values()].filter((s) => s.parentId === root.id);
    console.log("timeline:\n  " + timeline.join("\n  "));
    console.log(`children of ${root.id}:`, kids.map((k) => `${k.id} name=${k.name} status=${k.status} readOnly=${k.readOnly} model=${k.model?.id} cost=${k.cost.toFixed(4)}`).join("\n  "));
    show(root.id, `parent ${root.id}`);
    for (const k of kids) {
      await call("attach", { sessionId: k.id });
      await sleep(800);
      show(k.id, `child ${k.name} (${k.id})`);
    }
    if (kids[0]?.readOnly) console.log("send to read-only child:", await call("send", { sessionId: kids[0].id, text: "hi" }).then(() => "accepted", (e) => `rejected: ${e.message}`));
    await call("delete_session", { sessionId: root.id }).catch((e) => console.log("delete:", e.message));
  } catch (e) { console.log("FAILED", e.message); }
  process.exit(0);
};
