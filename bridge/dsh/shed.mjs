// Shed's plugin for DeepSeek Harness. The bridge runs `dsh --profile shed` with this plugin in place of the SDK's
// JSON-RPC server, and speaks newline-delimited JSON over stdio:
//
//   bridge → dsh   {"id": 1, "method": "open", "params": {...}}
//   dsh → bridge   {"id": 1, "result": ...} or {"id": 1, "error": "..."}
//   dsh → bridge   {"event": "session" | "stream" | "status" | "subagent_end" | "error", ...}
//
// Events are dsh's own, forwarded nearly raw: durable session events for the session and every subagent under
// it, live assistant stream frames, and agent status. The bridge turns them into Shed's events.

import { randomUUID } from "node:crypto";
import { admitEncodedImages } from "@deepseek-ai/dsh-attachment";
import { installModelSelection } from "@deepseek-ai/dsh-agent";
import { brandString } from "@deepseek-ai/dsh-brand";
import { ReasoningEffortId, createUserMessage, errorChain } from "@deepseek-ai/dsh-llm";

export const name = "shed";
export const inject = ["agents", "llm", "sdkAppStartup"];

export function apply(ctx) {
  const write = (message) => process.stdout.write(JSON.stringify(message) + "\n");
  const send = (event, fields) => write({ event, ...fields });
  let root; // { handle, agent, selection }

  ctx.on("session/event", (session, event) => {
    const parent = session.header.parentSession;
    send("session", { sessionId: String(session.id), ...(parent ? { parent: String(parent) } : {}), data: event });
  });
  ctx.on("agent/assistant-stream", ({ agent, frame }) => {
    send("stream", { sessionId: String(agent.session.id), frame });
  });
  ctx.on("agent/status", ({ agent, status }) => {
    send("status", { sessionId: String(agent.session.id), status });
  });
  ctx.on("agent/error", ({ agent, error }) => {
    send("error", { sessionId: String(agent.session.id), message: errorChain(error) });
  });
  ctx.on("subagent/end", (info) => {
    send("subagent_end", { sessionId: String(info.id), stopReason: info.stopReason });
  });
  // Shed runs its agents without asking, as it does Pi and Prime.
  ctx.on("approval/request", () => "allowed-once");

  const live = () => {
    if (!root) throw new Error("no session is open");
    return root;
  };

  // The session's durable events, which hold its whole conversation.
  const history = () => {
    const session = live().agent.session;
    const events = [];
    for (let seq = 0; seq < session.seq; seq++) {
      const event = session.eventAt(seq);
      if (event !== undefined) events.push(event);
    }
    return events;
  };

  const selected = async (want) => {
    const base = want?.model ? want : ctx.get("agentDefaultModel")?.currentSelection();
    if (!base) return undefined;
    const resolved = await ctx.llm.resolveCallConfig({
      provider: base.provider,
      model: base.model,
      ...(base.reasoningEffort ? { reasoningEffort: ReasoningEffortId(base.reasoningEffort) } : {}),
    });
    return {
      provider: resolved.provider,
      model: resolved.model,
      ...(resolved.reasoningEffort === undefined ? {} : { reasoningEffort: resolved.reasoningEffort }),
    };
  };

  const describe = async () => {
    const { agent, selection } = live();
    const current = selection.current;
    const info = current ? await ctx.llm.resolveModelInfo(current.provider, current.model).catch(() => undefined) : undefined;
    return {
      sessionId: String(agent.session.id),
      status: agent.status,
      model: current ?? null,
      contextWindow: info?.contextWindow ?? null,
      reasoning: info?.reasoning ?? null,
      title: agent.session.header.title ?? null,
    };
  };

  const methods = {
    async open({ sessionId, resume, cwd, model }) {
      if (root) throw new Error("a session is already open");
      const selection = { current: undefined, assembled: undefined };
      const setup = async (agentCtx, agent) => {
        const logged = resume ? agent?.session.requestHeader()?.config : undefined;
        selection.current = await selected(model?.model ? model : logged ? { ...logged } : undefined).catch(() =>
          logged ? { provider: logged.provider, model: logged.model } : undefined,
        );
        installModelSelection(agentCtx, selection);
      };
      const handle = resume
        ? await ctx.agents.resume({ resumeSessionId: brandString(sessionId), agentOptions: {}, setup })
        : await ctx.agents.create({
            sessionId: brandString(sessionId ?? randomUUID()),
            meta: { cwd },
            agentOptions: {},
            setup: (agentCtx) => setup(agentCtx, undefined),
          });
      root = { handle, agent: handle.agent, selection };
      return { ...(await describe()), events: history() };
    },

    async history() {
      return { events: history() };
    },

    async state() {
      return describe();
    },

    async prompt({ text, images = [], mode = "followup" }) {
      const { agent } = live();
      const blocks = [];
      if (images.length > 0) {
        const attachments = ctx.get("attachments");
        if (!attachments) throw new Error("this dsh profile has no attachment store for images");
        const refs = await admitEncodedImages(
          attachments,
          images.map((image) => ({ data: image.data, mediaType: image.mimeType })),
        );
        for (const attachment of refs) blocks.push({ type: "image", attachment });
      }
      if (text) blocks.unshift({ type: "text", text });
      const message = createUserMessage({ content: blocks, source: { kind: "user" } });
      if (mode === "steer") agent.steer(message);
      else agent.followup(message);
      return { messageId: message.id };
    },

    // keepInbox: stop the reply but still deliver what was queued behind it.
    async cancel({ keepInbox = false }) {
      live().agent.cancel({ kind: "user" }, { keepInbox });
      return {};
    },

    async select({ provider, model, effort }) {
      const state = live();
      const current = state.selection.current;
      state.selection.current = await selected({
        provider: provider ?? current?.provider,
        model: model ?? current?.model,
        ...(effort === undefined ? (current?.reasoningEffort ? { reasoningEffort: current.reasoningEffort } : {}) : effort ? { reasoningEffort: effort } : {}),
      });
      return describe();
    },

    async models() {
      const groups = await Promise.all(
        ctx.llm.listProviders().map(async (provider) => {
          const models = await ctx.llm.listModels(provider.id).catch(() => []);
          return models.map((m) => ({ provider: provider.id, id: m.id, name: m.name ?? m.id }));
        }),
      );
      return { models: groups.flat() };
    },

    async model_info({ provider, model }) {
      const info = await ctx.llm.resolveModelInfo(provider, model);
      return { contextWindow: info.contextWindow ?? null, reasoning: info.reasoning ?? null };
    },

    async command({ line }) {
      const commands = ctx.get("commands");
      if (!commands) throw new Error("this dsh profile has no slash commands");
      const run = await commands.execute(live().agent, line, [], new AbortController().signal);
      if (run === undefined) throw new Error(`unknown command: ${line}`);
      return run.result;
    },

    async jobs() {
      const jobs = ctx.get("jobs");
      return { jobs: jobs ? jobs.list(live().agent.session.id) : [] };
    },

    // The tail, read without moving the cursor the agent's own job_output reads from.
    async job_output({ jobId, owner, bytes = 16384 }) {
      const jobs = ctx.get("jobs");
      const caller = owner ?? live().agent.session.id;
      const job = jobs.get(jobId, caller);
      const read = jobs.readAt(jobId, Math.max(job.output.earliest, job.output.total - bytes), caller);
      const text = read.chunks.map((chunk) => (typeof chunk === "string" ? chunk : (chunk.text ?? ""))).join("");
      return { text, job };
    },

    async kill_job({ jobId, owner }) {
      await ctx.get("jobs").kill(jobId, owner ?? live().agent.session.id, "killed from Shed");
      return {};
    },

    async close() {
      const state = root;
      root = undefined;
      if (state) {
        state.agent.cancel({ kind: "user" });
        await ctx.get("subagents")?.drainDescendants([state.agent]).catch(() => {});
        await state.handle.dispose();
      }
      setImmediate(() => process.exit(0));
      return {};
    },
  };

  let buffer = "";
  const onData = (chunk) => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, end).trim();
      buffer = buffer.slice(end + 1);
      if (!line) continue;
      let request;
      try {
        request = JSON.parse(line);
      } catch {
        continue;
      }
      const handler = methods[request.method];
      Promise.resolve()
        .then(() => {
          if (!handler) throw new Error(`unknown method: ${request.method}`);
          return handler(request.params ?? {});
        })
        .then(
          (result) => write({ id: request.id, result: result ?? {} }),
          (error) => write({ id: request.id, error: errorChain(error) }),
        );
    }
  };
  ctx.effect(() => {
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", onData);
    write({ event: "ready" });
    return () => process.stdin.off("data", onData);
  }, "shed.serve");
}
