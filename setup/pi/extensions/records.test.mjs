// Checks the record shapes Pi's extensions write against the fixtures in protocol/, which the Rust bridge tests
// read too. Run with UPDATE_FIXTURES=1 to rewrite protocol/pi_job.json and protocol/pi_subagents.json.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
	finishJobRecord,
	formatDoneNotice,
	logFilePath,
	saveJobRecord,
	startJobRecord,
	tailJobLog,
} from "./background-jobs/records.ts";
import {
	applySubagentLine,
	buildSubagentDetails,
	createSingleResult,
} from "./subagent/records.ts";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const PI_JOB = path.join(ROOT, "protocol/pi_job.json");
const PI_SUBAGENTS = path.join(ROOT, "protocol/pi_subagents.json");

function checkFixture(file, value) {
	const expected = JSON.stringify(value, null, 2) + "\n";
	if (process.env.UPDATE_FIXTURES) {
		fs.writeFileSync(file, expected);
	}
	assert.equal(
		fs.readFileSync(file, "utf8"),
		expected,
		`${path.relative(ROOT, file)} is out of date: run UPDATE_FIXTURES=1 node --no-warnings --test setup/pi/extensions/records.test.mjs`,
	);
}

test("background-jobs writes running and finished records matching protocol/pi_job.json", () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-jobs-test-"));
	try {
		const running = startJobRecord({
			id: "j1a2b3",
			command: "cargo test --locked",
			cwd: "/work/project",
			pid: 4242,
			startedAt: "2026-11-11T10:00:00.000Z",
		});
		saveJobRecord(dir, running);
		const onDiskRunning = JSON.parse(fs.readFileSync(path.join(dir, "j1a2b3.json"), "utf8"));

		fs.writeFileSync(logFilePath(dir, "j1a2b3"), "line 1\nline 2\nall green\n");
		assert.equal(tailJobLog(dir, "j1a2b3", 2), "line 2\nall green");

		const finished = finishJobRecord(running, 0, null, Date.parse("2026-11-11T10:00:01.250Z"));
		saveJobRecord(dir, finished);
		const onDiskFinished = JSON.parse(fs.readFileSync(path.join(dir, "j1a2b3.json"), "utf8"));

		const killed = finishJobRecord(running, null, "SIGTERM", Date.parse("2026-11-11T10:00:02.000Z"));
		assert.equal(killed.exitCode, -os.constants.signals.SIGTERM);
		assert.equal(
			formatDoneNotice(killed, tailJobLog(dir, "j1a2b3", 2)),
			`[bash-done id:j1a2b3 pid:4242 exit:${killed.exitCode}]\n\nCommand: "cargo test --locked"\n\nline 2\nall green`,
		);

		checkFixture(PI_JOB, { running: onDiskRunning, finished: onDiskFinished });
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

test("subagent builds details.results matching protocol/pi_subagents.json", () => {
	const scout = createSingleResult({
		agent: "scout",
		agentSource: "user",
		task: "Find the entry point",
		model: "example/model-1",
		step: 1,
	});
	assert.equal(
		applySubagentLine(
			scout,
			JSON.stringify({
				type: "message_end",
				message: {
					role: "user",
					content: [{ type: "text", text: "Task: Find the entry point" }],
					timestamp: 1700000100000,
				},
			}),
		),
		true,
	);
	assert.equal(
		applySubagentLine(
			scout,
			JSON.stringify({
				type: "message_end",
				message: {
					role: "assistant",
					content: [{ type: "text", text: "It is src/main.rs." }],
					model: "example/model-1",
					stopReason: "stop",
					usage: {
						input: 800,
						output: 400,
						cacheRead: 0,
						cacheWrite: 0,
						totalTokens: 1200,
						cost: { total: 0.25 },
					},
					timestamp: 1700000101000,
				},
			}),
		),
		true,
	);

	const reviewer = createSingleResult({
		agent: "reviewer",
		agentSource: "user",
		task: "Review src/main.rs",
		step: 2,
	});
	reviewer.exitCode = 1;
	reviewer.stopReason = "error";
	reviewer.stderr = "provider rate limit\nretry later";

	const details = buildSubagentDetails("chain", "user", null, [scout, reviewer]);
	checkFixture(PI_SUBAGENTS, details);
});
