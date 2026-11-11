/**
 * Background Jobs - run shell commands without blocking the agent
 *
 * Pi's bash tool waits for its command. This extension adds tools to start a command in the background, check its
 * output, list jobs and stop them. When a job exits, the agent gets a `[bash-done id:… pid:… exit:N]` notice, which
 * starts a turn when it's idle, so it can end its turn instead of polling. This mirrors Prime's background `bash()`:
 * the same notice, a "shells: N" footer count while jobs run, and /jobs to see a job's output or cancel it.
 *
 * Each job is a JSON record plus a log of its combined output in the jobs folder: $AGENT_REMOTE_JOBS_DIR (the Agent
 * Remote bridge sets one per session, and lists, tails and stops jobs from there), else ~/.pi/agent/jobs/<pid>.
 * Jobs run in their own process group; stopping a job, or the session ending, signals the whole group.
 */

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";

interface Job {
	id: string;
	command: string;
	cwd: string;
	pid: number;
	startedAt: string;
	status: "running" | "finished";
	/** Negative signal number when a signal ended it, as Prime reports (-15 for SIGTERM). */
	exitCode?: number;
	durationMs?: number;
}

const DIR = process.env.AGENT_REMOTE_JOBS_DIR || path.join(os.homedir(), ".pi", "agent", "jobs", String(process.pid));
const TAIL_LIMIT = 16 * 1024;

const jobs = new Map<string, Job>();
let ui: ExtensionContext["ui"] | undefined;

/** "shells: N" in the footer while jobs run, as in Prime's TUI. */
function showStatus() {
	const running = [...jobs.values()].filter((job) => job.status === "running").length;
	ui?.setStatus("background-jobs", running ? ui.theme.fg("dim", `shells: ${running}`) : undefined);
}

function save(job: Job) {
	fs.mkdirSync(DIR, { recursive: true });
	const file = path.join(DIR, `${job.id}.json`);
	fs.writeFileSync(`${file}.tmp`, JSON.stringify(job));
	fs.renameSync(`${file}.tmp`, file);
}

function logPath(id: string) {
	return path.join(DIR, `${id}.log`);
}

/** The last `lines` lines of a job's output, at most 16 KiB. */
function tail(id: string, lines = 50): string {
	let text = "";
	try {
		const fd = fs.openSync(logPath(id), "r");
		const size = fs.fstatSync(fd).size;
		const length = Math.min(size, TAIL_LIMIT);
		const buffer = Buffer.alloc(length);
		fs.readSync(fd, buffer, 0, length, size - length);
		fs.closeSync(fd);
		text = buffer.toString("utf8");
	} catch {
		return "";
	}
	return text.split("\n").slice(-Math.max(1, Math.min(lines, 500))).join("\n");
}

function find(id: string): Job {
	const job = jobs.get(id);
	if (!job) throw new Error(`No background job ${id}. Known jobs: ${[...jobs.keys()].join(", ") || "none"}`);
	return job;
}

function stop(job: Job, signal: NodeJS.Signals = "SIGTERM") {
	if (job.status !== "running") return false;
	try {
		process.kill(-job.pid, signal);
	} catch {
		return false;
	}
	// Commands that ignore SIGTERM get SIGKILL after 5 seconds.
	if (signal === "SIGTERM") setTimeout(() => job.status === "running" && stop(job, "SIGKILL"), 5000).unref();
	return true;
}

function describe(job: Job): string {
	const state =
		job.status === "running"
			? `running for ${Math.round((Date.now() - Date.parse(job.startedAt)) / 1000)}s`
			: `exited ${job.exitCode}`;
	return `${job.id}  ${state}  pid ${job.pid}  $ ${job.command}`;
}

const text = (value: string) => ({ content: [{ type: "text" as const, text: value }], details: {} });

export default function (pi: ExtensionAPI) {
	pi.registerTool(
		defineTool({
			name: "bash_background",
			label: "Background bash",
			description:
				"Start a shell command in the background and return at once with a job id. Use it for long-running work " +
				"(builds, test suites, servers, downloads) so you can keep working. When the job exits you receive a " +
				"[bash-done id:<id> exit:<code>] message with the end of its output; don't poll for it, end your turn if " +
				"there's nothing else to do. Use job_output to see progress, job_kill to stop it, jobs to list them.",
			parameters: Type.Object({
				command: Type.String({ description: "Shell command, run with bash -lc" }),
				cwd: Type.Optional(Type.String({ description: "Working directory (default: the session's)" })),
			}),
			async execute(_id, params, _signal, _onUpdate, ctx) {
				fs.mkdirSync(DIR, { recursive: true });
				const id = Math.random().toString(36).slice(2, 8);
				const cwd = params.cwd ? path.resolve(ctx.cwd, params.cwd) : ctx.cwd;
				// A folder that is gone makes the spawn fail with an `error` event, which, unheard, would end Pi itself.
				if (!fs.existsSync(cwd)) throw new Error(`No such folder: ${cwd}`);
				const out = fs.openSync(logPath(id), "a");
				const child = spawn("bash", ["-lc", params.command], { cwd, detached: true, stdio: ["ignore", out, out] });
				child.once("error", (error) => console.error(`background job ${id}: ${error.message}`));
				fs.closeSync(out);
				if (child.pid === undefined) throw new Error(`Could not start: ${params.command}`);
				const job: Job = {
					id,
					command: params.command,
					cwd,
					pid: child.pid,
					startedAt: new Date().toISOString(),
					status: "running",
				};
				jobs.set(id, job);
				save(job);
				showStatus();
				child.on("exit", (code, signal) => {
					job.status = "finished";
					job.exitCode = code ?? -(os.constants.signals[signal as NodeJS.Signals] ?? 0);
					job.durationMs = Date.now() - Date.parse(job.startedAt);
					save(job);
					showStatus();
					const output = tail(id, 20).trim();
					pi.sendMessage(
						{
							customType: "bash-done",
							content: `[bash-done id:${id} pid:${job.pid} exit:${job.exitCode}]\n\nCommand: ${JSON.stringify(job.command)}${output ? `\n\n${output}` : ""}`,
							display: true,
							details: job,
						},
						{ triggerTurn: true, deliverAs: "steer" },
					);
				});
				child.unref();
				return text(`Started background job ${id} (pid ${child.pid}): ${params.command}`);
			},
		}),
	);

	pi.registerTool(
		defineTool({
			name: "job_output",
			label: "Job output",
			description: "Show the last lines of a background job's output and whether it is still running.",
			parameters: Type.Object({
				id: Type.String({ description: "Job id from bash_background" }),
				lines: Type.Optional(Type.Number({ description: "How many lines (default 50, at most 500)" })),
			}),
			async execute(_id, params) {
				const job = find(params.id);
				return text(`${describe(job)}\n\n${tail(job.id, params.lines ?? 50) || "(no output yet)"}`);
			},
		}),
	);

	pi.registerTool(
		defineTool({
			name: "job_kill",
			label: "Stop job",
			description: "Stop a background job (SIGTERM to its process group, then SIGKILL after 5 seconds).",
			parameters: Type.Object({ id: Type.String({ description: "Job id from bash_background" }) }),
			async execute(_id, params) {
				const job = find(params.id);
				return text(stop(job) ? `Stopping ${job.id}.` : `${job.id} is not running.`);
			},
		}),
	);

	pi.registerTool(
		defineTool({
			name: "jobs",
			label: "Background jobs",
			description: "List this session's background jobs.",
			parameters: Type.Object({}),
			async execute() {
				return text([...jobs.values()].map(describe).join("\n") || "No background jobs.");
			},
		}),
	);

	pi.registerCommand("jobs", {
		description: "Background commands: see output or cancel one",
		handler: async (_args, ctx) => {
			if (!jobs.size) return ctx.ui.notify("No background commands", "info");
			const list = [...jobs.values()].reverse();
			// Labels of running jobs tick, so match the choice by position.
			const labels = list.map(describe);
			const choice = await ctx.ui.select("Background commands", labels);
			const job = choice === undefined ? undefined : list[labels.indexOf(choice)];
			if (!job) return;
			const output = tail(job.id, 40) || "No output yet";
			if (job.status === "running" && (await ctx.ui.confirm("Cancel command?", `${describe(job)}\n\n${output}`))) stop(job);
			else if (job.status !== "running") ctx.ui.notify(`${describe(job)}\n\n${output}`, "info");
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		ui = ctx.hasUI ? ctx.ui : undefined;
	});

	pi.on("session_shutdown", async () => {
		for (const job of jobs.values()) stop(job);
	});
}
