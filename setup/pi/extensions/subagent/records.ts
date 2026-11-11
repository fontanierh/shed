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
		exitCode: 0,
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
