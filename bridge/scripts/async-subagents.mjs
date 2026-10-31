// Watch an asynchronous Prime run: the parent spawns children, ends its turn, and wakes up when they report.
// Usage: node scripts/async-subagents.mjs <port> <cwd> [model] [seconds]
import fs from "node:fs";
import os from "node:os";

const [port = "7878", cwd = process.cwd(), model = "openai/gpt-6.1-terra", seconds = "120"] = process.argv.slice(2);
const token = JSON.parse(fs.readFileSync(`${os.homedir()}/.agent-remote/config.json`, "utf8")).token;
const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${token}`);
const pending = new Map();
let next = 0;
const call = (op, fields = {}) =>
  new Promise((resolve, reject) => {
    const id = `r${++next}`;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, op, ...fields }));
  });

const start = Date.now();
const tag = Math.random().toString(36).slice(2, 6); // child names must be unique in the daemon
const t = () => `${((Date.now() - start) / 1000).toFixed(1).padStart(5)}s`;
let rootId;
const seen = new Map();
const isOurs = (s) => s.id === rootId || s.parentId === rootId;
const show = (s) => `${s.kind === "subagent" ? `child ${s.name}` : "PARENT"} status=${s.status} jobs=${s.backgroundJobs}`;

ws.onmessage = ({ data }) => {
  const msg = JSON.parse(data);
  if (msg.type === "reply") {
    const p = pending.get(msg.id);
    pending.delete(msg.id);
    msg.ok ? p?.resolve(msg.data) : p?.reject(new Error(msg.error));
  } else if (msg.type === "session" && rootId && isOurs(msg.session)) {
    const line = show(msg.session);
    if (seen.get(msg.session.id) !== line) console.log(t(), line), seen.set(msg.session.id, line);
  } else if (msg.type === "session_removed" && seen.has(msg.sessionId)) {
    console.log(t(), "REMOVED", seen.get(msg.sessionId));
  } else if (msg.type === "item_add" && msg.sessionId === rootId && ["note", "user", "text"].includes(msg.item.kind)) {
    console.log(t(), `  parent ${msg.item.kind}: ${msg.item.text.slice(0, 100).replace(/\n/g, " ")}`);
  }
};

ws.onopen = async () => {
  const root = await call("create_session", { agent: "prime", cwd, model, thinking: "low" });
  rootId = root.id;
  console.log(t(), "created", rootId);
  await call("attach", { sessionId: rootId });
  await call("send", {
    sessionId: rootId,
    text:
      'Run exactly this in your Python REPL: a = await rlm.spawn("Run `sleep 20 && ls | wc -l` with bash, then report the number to your parent via agent_message.send", name="slow-lister-' + tag + '"); b = await rlm.spawn("Run `sleep 30 && ls *.txt | wc -l` with bash, then report the number to your parent via agent_message.send", name="slow-counter-' + tag + '"); print(a.name, b.name). Then end your turn immediately. When each child reports, acknowledge it in one short line.',
  });
  setTimeout(async () => {
    const sessions = await call("list_sessions");
    console.log(t(), "final:", sessions.filter(isOurs).map(show).join(" | "));
    console.log("root", rootId);
    process.exit(0);
  }, Number(seconds) * 1000);
};
