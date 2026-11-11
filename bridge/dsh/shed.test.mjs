import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import test from "node:test";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith("@deepseek-ai/")) {
      return {
        url: `data:text/javascript,${encodeURIComponent(stubModule(specifier))}`,
        shortCircuit: true,
      };
    }
    return nextResolve(specifier, context);
  },
});

function stubModule(specifier) {
  switch (specifier) {
    case "@deepseek-ai/dsh-attachment":
      return `export async function admitEncodedImages(_store, images) { return images.map((_, i) => "att-" + i); }`;
    case "@deepseek-ai/dsh-agent":
      return `export function installModelSelection(ctx, sel) { ctx.selection = sel; }`;
    case "@deepseek-ai/dsh-brand":
      return `export function brandString(s) { return s; }`;
    case "@deepseek-ai/dsh-llm":
      return `
        export function ReasoningEffortId(s) { return s; }
        let n = 0;
        export function createUserMessage({ content, source }) { return { id: "msg-" + (++n), content, source }; }
        export function errorChain(err) { return err?.message ?? String(err); }
      `;
    case "@deepseek-ai/dsh-web":
      return `export class WebError extends Error { constructor(m, code) { super(m); this.code = code; } }`;
    default:
      throw new Error(`unexpected @deepseek-ai import: ${specifier}`);
  }
}

const shedPlugin = await import("./shed.mjs");
const shedWebPlugin = await import("./shed-web.mjs");

function makeHarness() {
  const listeners = new Map();
  const written = [];
  const fakeStdin = new EventEmitter();
  fakeStdin.setEncoding = () => {};
  fakeStdin.off = fakeStdin.removeListener.bind(fakeStdin);

  const origStdin = Object.getOwnPropertyDescriptor(process, "stdin");
  const origStdoutWrite = process.stdout.write;
  const origStderrWrite = process.stderr.write;
  const origExit = process.exit;

  Object.defineProperty(process, "stdin", { value: fakeStdin, configurable: true });
  process.stdout.write = (chunk, ...rest) => {
    if (typeof chunk === "string") {
      for (const line of chunk.split("\n").filter(Boolean)) {
        written.push(JSON.parse(line));
      }
      return true;
    }
    return origStdoutWrite.call(process.stdout, chunk, ...rest);
  };
  process.stderr.write = () => true;
  let exitedWith = null;
  process.exit = (code) => {
    exitedWith = code;
  };

  let activeQuestions = [];
  const steered = [];
  const followedUp = [];
  const cancelled = [];
  let disposed = false;

  const sessionObj = {
    id: "sess-root",
    header: { title: "Root Session", parentSession: undefined },
    seq: 1,
    eventAt: (i) => (i === 0 ? { type: "user/message", data: { content: [{ type: "text", text: "hello" }] } } : undefined),
    requestHeader: () => ({ config: { provider: "deepseek", model: "deepseek-chat" } }),
  };

  const agentObj = {
    session: sessionObj,
    status: "idle",
    steer: (m) => steered.push(m),
    followup: (m) => followedUp.push(m),
    cancel: (reason, opts) => cancelled.push({ reason, opts }),
  };

  const services = {
    sessionProjections: {
      stateOf: () => ({ questions: { active: activeQuestions } }),
    },
    userQuestions: {
      answer: (_agent, callId, batch) => {
        const idx = activeQuestions.findIndex((q) => q.callId === callId);
        if (idx < 0) return false;
        activeQuestions.splice(idx, 1);
        return Boolean(batch);
      },
    },
    commands: {
      execute: async (_agent, line) =>
        line === "/compact" ? { result: { kind: "success", text: "Compacted" } } : undefined,
    },
    jobs: {
      list: () => [{ id: "j1", command: "sleep 5", status: "running" }],
      get: (jobId) => ({ id: jobId, output: { earliest: 0, total: 12 } }),
      readAt: () => ({ chunks: ["line1\n", { text: "line2" }] }),
      kill: async () => {},
    },
    subagents: {
      drainDescendants: async () => {},
    },
  };

  let cleanupEffect;
  const ctx = {
    on(event, fn) {
      const list = listeners.get(event) ?? [];
      list.push(fn);
      listeners.set(event, list);
    },
    emit(event, ...args) {
      for (const fn of listeners.get(event) ?? []) fn(...args);
    },
    get(name) {
      return services[name];
    },
    effect(fn) {
      cleanupEffect = fn();
    },
    llm: {
      async resolveCallConfig(cfg) {
        return cfg;
      },
      async resolveModelInfo(_provider, model) {
        return {
          contextWindow: 128000,
          reasoning: { efforts: [{ id: "low" }, { id: "high" }] },
          name: model,
        };
      },
      listProviders() {
        return [{ id: "opencodex" }];
      },
      async listModels() {
        return [{ id: "deepseek/deepseek-flash", name: "DeepSeek Flash" }];
      },
    },
    agents: {
      async create({ setup }) {
        await setup({});
        return {
          agent: agentObj,
          dispose: async () => {
            disposed = true;
          },
        };
      },
      async resume({ setup }) {
        await setup({}, agentObj);
        return {
          agent: agentObj,
          dispose: async () => {
            disposed = true;
          },
        };
      },
    },
  };

  shedPlugin.apply(ctx);

  const sendLine = async (rawLine) => {
    fakeStdin.emit("data", rawLine + "\n");
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
  };

  const restore = () => {
    cleanupEffect?.();
    if (origStdin) Object.defineProperty(process, "stdin", origStdin);
    process.stdout.write = origStdoutWrite;
    process.stderr.write = origStderrWrite;
    process.exit = origExit;
  };

  return {
    written,
    steered,
    followedUp,
    cancelled,
    setQuestions: (q) => {
      activeQuestions = q;
    },
    getDisposed: () => disposed,
    getExitedWith: () => exitedWith,
    ctx,
    agentObj,
    sessionObj,
    sendLine,
    restore,
  };
}

test("shed.mjs handles the bridge's NDJSON methods, events and malformed lines with numeric ids", async () => {
  const h = makeHarness();
  try {
    assert.deepEqual(h.written[0], { event: "ready" });

    // Malformed JSON carrying a numeric id (as Dsh::call sends) must answer under that numeric id instead of hanging.
    await h.sendLine('{"id":7,"method":broken}');
    const badReply = h.written.find((m) => m.id === 7);
    assert.ok(badReply, `expected error reply for numeric id 7, got ${JSON.stringify(h.written)}`);
    assert.match(badReply.error, /not JSON/);

    // open
    await h.sendLine(
      JSON.stringify({
        id: 1,
        method: "open",
        params: {
          cwd: "/work",
          resume: false,
          model: { provider: "opencodex", model: "deepseek/deepseek-flash", reasoningEffort: "high" },
        },
      }),
    );
    const opened = h.written.find((m) => m.id === 1);
    assert.equal(opened.result.sessionId, "sess-root");
    assert.equal(opened.result.contextWindow, 128000);
    assert.equal(opened.result.events.length, 1);

    // models
    await h.sendLine(JSON.stringify({ id: 2, method: "models", params: {} }));
    assert.deepEqual(h.written.find((m) => m.id === 2).result, {
      models: [{ provider: "opencodex", id: "deepseek/deepseek-flash", name: "DeepSeek Flash" }],
    });

    // prompt (followup and steer)
    await h.sendLine(JSON.stringify({ id: 3, method: "prompt", params: { text: "first", images: [], mode: "followup" } }));
    await h.sendLine(JSON.stringify({ id: 4, method: "prompt", params: { text: "now", images: [], mode: "steer" } }));
    assert.equal(h.followedUp.length, 1);
    assert.equal(h.steered.length, 1);

    // cancel
    await h.sendLine(JSON.stringify({ id: 5, method: "cancel", params: { keepInbox: true } }));
    assert.equal(h.cancelled[0].opts.keepInbox, true);

    // select
    await h.sendLine(JSON.stringify({ id: 6, method: "select", params: { effort: "low" } }));
    assert.equal(h.written.find((m) => m.id === 6).result.model.reasoningEffort, "low");

    // command (/compact)
    await h.sendLine(JSON.stringify({ id: 8, method: "command", params: { line: "/compact" } }));
    assert.equal(h.written.find((m) => m.id === 8).result.kind, "success");

    // jobs & job_output & kill_job
    await h.sendLine(JSON.stringify({ id: 9, method: "jobs", params: {} }));
    assert.equal(h.written.find((m) => m.id === 9).result.jobs.length, 1);
    await h.sendLine(JSON.stringify({ id: 10, method: "job_output", params: { jobId: "j1" } }));
    assert.equal(h.written.find((m) => m.id === 10).result.text, "line1\nline2");
    await h.sendLine(JSON.stringify({ id: 11, method: "kill_job", params: { jobId: "j1" } }));
    assert.deepEqual(h.written.find((m) => m.id === 11).result, {});

    // question + answer
    h.setQuestions([
      {
        callId: "call-q1",
        state: "continued",
        questions: [{ id: "mode", question: "Mode?" }],
      },
    ]);
    h.ctx.emit("session/event", h.sessionObj, { type: "turn/end" });
    await new Promise((r) => setImmediate(r));
    assert.ok(h.written.some((m) => m.event === "questions" && m.active.length === 1));

    await h.sendLine(
      JSON.stringify({
        id: 12,
        method: "answer",
        params: { id: "call-q1", answers: [{ id: "mode", selected: ["Fast"] }] },
      }),
    );
    assert.deepEqual(h.written.find((m) => m.id === 12).result, {});

    // close
    await h.sendLine(JSON.stringify({ id: 13, method: "close", params: {} }));
    assert.equal(h.getDisposed(), true);
    assert.equal(h.getExitedWith(), 0);
  } finally {
    h.restore();
  }
});

test("shed-web.mjs passes -- before queries and URLs and surfaces errors", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shed-web-mjs-"));
  const fakeCmd = path.join(dir, "fake-shed-web");
  fs.writeFileSync(
    fakeCmd,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args.includes("fail-now")) {
  process.stderr.write("shed-web: provider quota exceeded\\n");
  process.exit(1);
}
if (args[0] === "search") {
  process.stdout.write(JSON.stringify({ sources: [{ url: "https://example.com", title: args.join(" ") }] }));
} else {
  process.stdout.write(JSON.stringify({ url: args.at(-2), statusCode: 200, markdown: "Hello", markdownFile: "/tmp/full.md", truncated: true }));
}
`,
    { mode: 0o755 },
  );

  try {
    let searchProvider;
    let fetchProvider;
    shedWebPlugin.apply(
      {
        web: {
          registerSearchProvider(p) {
            searchProvider = p;
          },
          registerFetchProvider(p) {
            fetchProvider = p;
          },
        },
      },
      { command: fakeCmd },
    );

    const hits = await searchProvider.search({ query: "--locked cargo", maxResults: 3 });
    assert.equal(hits.sources[0].title, "search --limit 3 -- --locked cargo --json");

    const page = await fetchProvider.fetch({ url: "https://example.com/doc" });
    assert.equal(page.url, "https://example.com/doc");
    assert.equal(page.truncated, true);
    assert.match(page.body.content, /\/tmp\/full\.md/);

    await assert.rejects(
      () => searchProvider.search({ query: "fail-now" }),
      (err) => err.message === "provider quota exceeded" && err.code === "WEB_PROVIDER_ERROR",
    );
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
