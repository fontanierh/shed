// End-to-end check of a running bridge: node scripts/smoke.mjs <pi|prime> [port] [cwd] [model] [thinking]
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const agent = process.argv[2] ?? "pi";
const port = process.argv[3] ?? "7878";
const cwd = process.argv[4] ?? process.cwd();
const model = process.argv[5];
const thinking = process.argv[6];
const token = JSON.parse(readFileSync(`${homedir()}/.agent-remote/config.json`, "utf8")).token;
const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${token}`);

let nextId = 0;
const waiting = new Map();
const items = new Map();
let summary;
let sessionId;
const seen = new Set();
let settle;

function call(op, fields = {}) {
  const id = `t${++nextId}`;
  ws.send(JSON.stringify({ id, op, ...fields }));
  return new Promise((resolve, reject) => waiting.set(id, { resolve, reject }));
}

const idle = () => new Promise((resolve) => (settle = resolve));

ws.onmessage = ({ data }) => {
  const msg = JSON.parse(data);
  seen.add(msg.type);
  if (msg.type === "reply") {
    const w = waiting.get(msg.id);
    waiting.delete(msg.id);
    msg.ok ? w?.resolve(msg.data) : w?.reject(new Error(msg.error));
  } else if (msg.type === "session" && msg.session.id === sessionId) {
    const wasBusy = summary && ["running", "starting"].includes(summary.status);
    summary = msg.session;
    if (wasBusy && summary.status === "idle" && settle) { settle(); settle = undefined; }
  } else if (msg.type === "snapshot") {
    items.clear();
    for (const item of msg.items) items.set(item.id, item);
  } else if (msg.type === "item_add") {
    items.set(msg.item.id, msg.item);
  } else if (msg.type === "item_patch") {
    const item = items.get(msg.itemId);
    if (!item) return console.log("PATCH FOR UNKNOWN ITEM", msg.itemId);
    Object.assign(item, msg.set ?? {});
    if (msg.append?.text) item.text += msg.append.text;
    if (msg.append?.args) item.args = (item.args ?? "") + msg.append.args;
  }
};

const show = (label) => {
  console.log(`--- ${label}: status=${summary.status} model=${summary.model?.provider}/${summary.model?.id} thinking=${summary.thinkingLevel} levels=[${summary.thinkingLevels}] context=${JSON.stringify(summary.context)} cost=${summary.cost.toFixed(4)} title=${JSON.stringify(summary.title)}`);
  for (const item of items.values()) {
    const body = (item.kind === "tool" ? `${item.toolName}(${(item.args ?? "").replace(/\s+/g, " ").slice(0, 60)}) [${item.status}] → ${(item.output ?? "").replace(/\s+/g, " ").slice(0, 60)}` : item.text.replace(/\s+/g, " ").slice(0, 100));
    console.log(`  ${item.kind.padEnd(10)} ${body}`);
  }
};

ws.onopen = async () => {
  try {
    const created = await call("create_session", { agent, cwd, model, thinking });
    sessionId = created.id;
    summary = created;
    await call("attach", { sessionId });
    console.log(`created ${agent} session ${sessionId} in ${created.cwd}`);

    let done = idle();
    await call("send", { sessionId, text: "Run the shell command `ls` using your tool, then tell me in one short sentence how many entries there are." });
    await new Promise((r) => setTimeout(r, 1500));
    const steer = await call("send", { sessionId, text: "Also mention the first entry alphabetically." }).catch((e) => `ERR ${e.message}`);
    console.log("steer reply while running:", JSON.stringify(steer), "status was", summary.status);
    await done;
    await new Promise((r) => setTimeout(r, 500));
    show("after first run");

    const models = await call("list_models", { sessionId });
    console.log(`list_models: ${models.length} models, e.g. ${models.slice(0, 3).map((m) => `${m.provider}/${m.id}`).join(", ")}`);
    const original = summary.thinkingLevel;
    const level = summary.thinkingLevels.find((l) => l !== summary.thinkingLevel && l !== "off") ?? summary.thinkingLevel;
    await call("set_thinking", { sessionId, level });
    console.log(`set_thinking ${level} -> summary says ${summary.thinkingLevel}`);
    // Prime saves the level as the global default, so put it back.
    await call("set_thinking", { sessionId, level: thinking ?? original });

    const compacted = await call("compact", { sessionId }).catch((e) => `ERR ${e.message}`);
    console.log("compact:", typeof compacted === "string" ? compacted : "ok");
    await new Promise((r) => setTimeout(r, 1000));
    show("after compact");

    await call("new_session", { sessionId });
    await new Promise((r) => setTimeout(r, 500));
    await new Promise((r) => setTimeout(r, 500));
    show("after new_session");
    console.log("message types seen:", [...seen].join(","));
    await call("close_session", { sessionId });
    await call("delete_session", { sessionId });
  } catch (e) {
    console.log("FAILED:", e.message);
    if (summary) show("state at failure");
  }
  ws.close();
  process.exit(0);
};
