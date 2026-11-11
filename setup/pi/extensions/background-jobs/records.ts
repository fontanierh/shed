import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export interface Job {
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

const TAIL_LIMIT = 16 * 1024;

export function startJobRecord(params: {
	id: string;
	command: string;
	cwd: string;
	pid: number;
	startedAt: string;
}): Job {
	return {
		id: params.id,
		command: params.command,
		cwd: params.cwd,
		pid: params.pid,
		startedAt: params.startedAt,
		status: "running",
	};
}

export function finishJobRecord(
	job: Job,
	code: number | null,
	signal: NodeJS.Signals | null,
	endedAtMs: number,
): Job {
	const signalNumber = signal ? os.constants.signals[signal] : undefined;
	return {
		...job,
		status: "finished",
		exitCode: code ?? -(signalNumber ?? 0),
		durationMs: endedAtMs - Date.parse(job.startedAt),
	};
}

export function saveJobRecord(dir: string, job: Job): void {
	fs.mkdirSync(dir, { recursive: true });
	const file = path.join(dir, `${job.id}.json`);
	fs.writeFileSync(`${file}.tmp`, JSON.stringify(job));
	fs.renameSync(`${file}.tmp`, file);
}

export function logFilePath(dir: string, id: string): string {
	return path.join(dir, `${id}.log`);
}

/** The last `lines` lines of a job's output, at most 16 KiB. */
export function tailJobLog(dir: string, id: string, lines = 50): string {
	let text = "";
	try {
		const fd = fs.openSync(logFilePath(dir, id), "r");
		const size = fs.fstatSync(fd).size;
		const length = Math.min(size, TAIL_LIMIT);
		const buffer = Buffer.alloc(length);
		fs.readSync(fd, buffer, 0, length, size - length);
		fs.closeSync(fd);
		text = buffer.toString("utf8");
	} catch {
		return "";
	}
	if (!text) return "";
	return text.replace(/\n$/, "").split("\n").slice(-Math.max(1, Math.min(lines, 500))).join("\n");
}

export function formatDoneNotice(job: Job, output: string): string {
	const trimmed = output.trim();
	return `[bash-done id:${job.id} pid:${job.pid} exit:${job.exitCode}]\n\nCommand: ${JSON.stringify(job.command)}${trimmed ? `\n\n${trimmed}` : ""}`;
}
