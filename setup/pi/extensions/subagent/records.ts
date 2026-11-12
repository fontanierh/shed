import * as os from "node:os";
import type { Message } from "@earendil-works/pi-ai";
import type { AgentScope } from "./agents.ts";

export interface UsageStats {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
	contextTokens: number;
	turns: number;
}

export interface SingleResult {
	agent: string;
	agentSource: "user" | "project" | "unknown";
	task: string;
	exitCode: number;
	messages: Message[];
	stderr: string;
	usage: UsageStats;
	model?: string;
	stopReason?: string;
	errorMessage?: string;
	step?: number;
}

export interface SubagentDetails {
	mode: "single" | "parallel" | "chain";
	agentScope: AgentScope;
	projectAgentsDir: string | null;
	results: SingleResult[];
}

export function emptyUsage(): UsageStats {
	return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
}

export function createSingleResult(params: {
	agent: string;
	agentSource: "user" | "project" | "unknown";
	task: string;
	model?: string;
	step?: number;
}): SingleResult {
	return {
		agent: params.agent,
		agentSource: params.agentSource,
		task: params.task,
		exitCode: -1,
		messages: [],
		stderr: "",
		usage: emptyUsage(),
		model: params.model,
		step: params.step,
	};
}

function isObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function isMessage(value: unknown): value is Message {
	return isObject(value) && typeof value.role === "string";
}

export function applySubagentLine(currentResult: SingleResult, line: string): boolean {
	if (!line.trim()) return false;
	let parsed: unknown;
	try {
		parsed = JSON.parse(line);
	} catch {
		return false;
	}
	if (!isObject(parsed)) return false;

	if (parsed.type === "message_end" && isMessage(parsed.message)) {
		const msg = parsed.message;
		currentResult.messages.push(msg);

		if (msg.role === "assistant") {
			currentResult.usage.turns++;
			const usage = msg.usage;
			if (usage) {
				currentResult.usage.input += usage.input || 0;
				currentResult.usage.output += usage.output || 0;
				currentResult.usage.cacheRead += usage.cacheRead || 0;
				currentResult.usage.cacheWrite += usage.cacheWrite || 0;
				currentResult.usage.cost += usage.cost?.total || 0;
				currentResult.usage.contextTokens = usage.totalTokens || 0;
			}
			if (!currentResult.model && msg.model) currentResult.model = msg.model;
			if (msg.stopReason) currentResult.stopReason = msg.stopReason;
			if (msg.errorMessage) currentResult.errorMessage = msg.errorMessage;
		}
		return true;
	}

	if (parsed.type === "tool_result_end" && isMessage(parsed.message)) {
		currentResult.messages.push(parsed.message);
		return true;
	}

	return false;
}

export function buildSubagentDetails(
	mode: "single" | "parallel" | "chain",
	agentScope: AgentScope,
	projectAgentsDir: string | null,
	results: SingleResult[],
): SubagentDetails {
	return {
		mode,
		agentScope,
		projectAgentsDir,
		results,
	};
}

export type DisplayItem =
	| { type: "text"; text: string }
	| { type: "toolCall"; name: string; args: Record<string, unknown> };

function str(value: unknown, fallback = ""): string {
	return typeof value === "string" && value.length > 0 ? value : fallback;
}

export function exitCodeFromClose(code: number | null, signal: NodeJS.Signals | null): number {
	if (typeof code === "number") return code;
	const sigNum = signal ? os.constants.signals[signal] : undefined;
	return typeof sigNum === "number" ? 128 + sigNum : 1;
}

export function substitutePrevious(task: string, previousOutput: string): string {
	return task.replaceAll("{previous}", () => previousOutput);
}

export function isSubagentDetails(value: unknown): value is SubagentDetails {
	return (
		isObject(value) &&
		(value.mode === "single" || value.mode === "parallel" || value.mode === "chain") &&
		Array.isArray(value.results)
	);
}

export function getDisplayItems(messages: Message[]): DisplayItem[] {
	const items: DisplayItem[] = [];
	for (const msg of messages) {
		if (msg.role === "assistant" && Array.isArray(msg.content)) {
			for (const part of msg.content) {
				if (part.type === "text" && typeof part.text === "string") {
					items.push({ type: "text", text: part.text });
				} else if (part.type === "toolCall" && typeof part.name === "string") {
					const args = isObject(part.arguments) ? part.arguments : {};
					items.push({ type: "toolCall", name: part.name, args });
				}
			}
		}
	}
	return items;
}

export type ToolThemeColor = "muted" | "toolOutput" | "accent" | "warning" | "dim";

export function formatToolCallRecord(
	toolName: string,
	args: Record<string, unknown>,
	themeFg: (color: ToolThemeColor, text: string) => string,
	homeDir: string,
	formatRange: (offset: number | undefined, limit: number | undefined) => string,
): string {
	const shortenPath = (p: string) => (homeDir && p.startsWith(homeDir) ? `~${p.slice(homeDir.length)}` : p);
	const num = (v: unknown): number | undefined => (typeof v === "number" ? v : undefined);

	switch (toolName) {
		case "bash": {
			const command = str(args.command, "...");
			const preview = command.length > 60 ? `${command.slice(0, 60)}...` : command;
			return themeFg("muted", "$ ") + themeFg("toolOutput", preview);
		}
		case "read": {
			const rawPath = str(args.file_path, str(args.path, "..."));
			const filePath = shortenPath(rawPath);
			const lineRange = formatRange(num(args.offset), num(args.limit));
			let text = themeFg("accent", filePath);
			if (lineRange) text += themeFg("warning", lineRange);
			return themeFg("muted", "read ") + text;
		}
		case "write": {
			const rawPath = str(args.file_path, str(args.path, "..."));
			const filePath = shortenPath(rawPath);
			const content = typeof args.content === "string" ? args.content : "";
			const lines = content.split("\n").length;
			let text = themeFg("muted", "write ") + themeFg("accent", filePath);
			if (lines > 1) text += themeFg("dim", ` (${lines} lines)`);
			return text;
		}
		case "edit": {
			const rawPath = str(args.file_path, str(args.path, "..."));
			return themeFg("muted", "edit ") + themeFg("accent", shortenPath(rawPath));
		}
		case "ls": {
			const rawPath = str(args.path, ".");
			return themeFg("muted", "ls ") + themeFg("accent", shortenPath(rawPath));
		}
		case "find": {
			const pattern = str(args.pattern, "*");
			const rawPath = str(args.path, ".");
			return (
				themeFg("muted", "find ") +
				themeFg("accent", pattern) +
				themeFg("dim", ` in ${shortenPath(rawPath)}`)
			);
		}
		case "grep": {
			const pattern = str(args.pattern, "");
			const rawPath = str(args.path, ".");
			return (
				themeFg("muted", "grep ") +
				themeFg("accent", `/${pattern}/`) +
				themeFg("dim", ` in ${shortenPath(rawPath)}`)
			);
		}
		default: {
			const argsStr = JSON.stringify(args);
			const preview = argsStr.length > 50 ? `${argsStr.slice(0, 50)}...` : argsStr;
			return themeFg("accent", toolName) + themeFg("dim", ` ${preview}`);
		}
	}
}
