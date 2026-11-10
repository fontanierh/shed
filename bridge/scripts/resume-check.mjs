// Check close + resume restores the transcript: node scripts/resume-check.mjs <pi|deepseek> <port> <cwd> [model]
// (Prime sessions stay live in its daemon and are never resumed.)
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const [agent, port, cwd, model] = process.argv.slice(2);
const token = JSON.parse(readFileSync(`${homedir()}/.agent-remote/config.json`, "utf8")).token;
const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${token}`);
let n = 0;
const waiting = new Map();
let status;
let snapshotSize = -1;
ws.onmessage = ({ data }) => {
  const m = JSON.parse(data);
  if (m.type === "reply") { const w = waiting.get(m.id); waiting.delete(m.id); m.ok ? w.resolve(m.data) : w.reject(new Error(m.error)); }
  if (m.type === "session") status = m.session.status;
  if (m.type === "snapshot") snapshotSize = m.items.length;
};
const call = (op, f = {}) => { const id = `r${++n}`; ws.send(JSON.stringify({ id, op, ...f })); return new Promise((resolve, reject) => waiting.set(id, { resolve, reject })); };
const until = async (pred, ms = 120000) => { const end = Date.now() + ms; while (!pred() && Date.now() < end) await new Promise((r) => setTimeout(r, 200)); };
ws.onopen = async () => {
  try {
    const s = await call("create_session", { agent, cwd, model });
    await call("attach", { sessionId: s.id });
    await call("send", { sessionId: s.id, text: "Reply with the single word: pong" });
    await until(() => status === "running", 20000);
    await until(() => status === "idle");
    await new Promise((r) => setTimeout(r, 500));
    const before = snapshotSize;
    await call("attach", { sessionId: s.id });
    await new Promise((r) => setTimeout(r, 300));
    console.log(`${agent}: items before close = ${snapshotSize}`);
    await call("close_session", { sessionId: s.id });
    await until(() => status === "stopped", 10000);
    console.log(`${agent}: status after close = ${status}`);
    await call("resume_session", { sessionId: s.id });
    await call("attach", { sessionId: s.id });
    await new Promise((r) => setTimeout(r, 300));
    console.log(`${agent}: status after resume = ${status}, items after resume = ${snapshotSize}`);
    await call("delete_session", { sessionId: s.id });
  } catch (e) { console.log(`${agent}: FAILED ${e.message}`); }
  process.exit(0);
};
