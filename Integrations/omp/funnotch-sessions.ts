// funnotch-sessions — publishes each omp session's status for Fun Notch.
//
// Fun Notch shows Claude Code sessions by reading the registry Claude Code keeps
// in ~/.claude/sessions. omp keeps no such registry, so this extension writes one
// in the same shape to ~/.omp/notch-sessions/<pid>-<sessionId>.json: one file per
// session (an ACP host such as Orca can run several sessions in one process),
// with a status of busy, waiting or idle. Nothing from the conversation is written.
//
// Install: copy this file to ~/.omp/agent/extensions/. It applies to sessions
// started afterwards.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

type Status = "busy" | "waiting" | "idle";

interface Entry {
	pid: number;
	sessionId: string;
	cwd: string;
	name: string;
	status: Status;
	waitingFor?: string;
	statusUpdatedAt: number;
	startedAt: number;
	procStart: string;
	entrypoint: "omp";
}

const DIR = path.join(os.homedir(), ".omp", "notch-sessions");

const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// `ps -o lstart` format in UTC, as Claude Code writes it. Fun Notch compares it
// with the real start of the pid, so a reused pid never revives a stale file.
function lstart(date: Date): string {
	const pad = (n: number) => String(n).padStart(2, "0");
	return `${DAYS[date.getUTCDay()]} ${MONTHS[date.getUTCMonth()]} ${date.getUTCDate()} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())} ${date.getUTCFullYear()}`;
}

const PROC_START = lstart(new Date(Date.now() - process.uptime() * 1000));

function removeFile(file: string): void {
	try {
		fs.unlinkSync(file);
	} catch {}
}

// Files left by processes that died without cleaning up.
function pruneDead(): void {
	let names: string[];
	try {
		names = fs.readdirSync(DIR);
	} catch {
		return;
	}
	for (const name of names) {
		const pid = Number.parseInt(name, 10);
		if (!name.endsWith(".json") || !Number.isInteger(pid) || pid === process.pid) continue;
		try {
			process.kill(pid, 0);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code === "ESRCH") removeFile(path.join(DIR, name));
		}
	}
}

// Files this process owns. Shared across module reloads so one exit hook removes them all.
const OWNED_KEY = Symbol.for("funnotch.omp.ownedFiles");
const owned: Set<string> = ((globalThis as Record<symbol, unknown>)[OWNED_KEY] as Set<string> | undefined) ??
	(() => {
		const files = new Set<string>();
		(globalThis as Record<symbol, unknown>)[OWNED_KEY] = files;
		process.on("exit", () => {
			for (const file of files) removeFile(file);
		});
		pruneDead();
		return files;
	})();

export default function (pi: ExtensionAPI): void {
	let file: string | null = null;
	let record: Entry | null = null;
	let running = false;

	function remove(): void {
		if (!file) return;
		removeFile(file);
		owned.delete(file);
		file = null;
		record = null;
	}

	function publish(ctx: ExtensionContext, status: Status, waitingFor?: string): void {
		// Only the session you talk to: task subagents and headless runs stay out of the notch.
		if (ctx.hasUI === false || Reflect.get(ctx, "agentKind") === "sub") return;
		try {
			const sessionId: unknown = ctx.sessionManager.getSessionId();
			if (typeof sessionId !== "string" || !sessionId) return;
			const target = path.join(DIR, `${process.pid}-${sessionId}.json`);
			if (file && file !== target) remove();

			const now = Date.now();
			const changed = !record || record.status !== status || record.waitingFor !== waitingFor;
			let name = "";
			try {
				name = pi.getSessionName() ?? "";
			} catch {}

			const next: Entry = {
				pid: process.pid,
				sessionId,
				cwd: ctx.cwd || process.cwd(),
				name,
				status,
				...(waitingFor ? { waitingFor } : {}),
				statusUpdatedAt: changed || !record ? now : record.statusUpdatedAt,
				startedAt: record ? record.startedAt : now,
				procStart: PROC_START,
				entrypoint: "omp",
			};

			fs.mkdirSync(DIR, { recursive: true });
			const temp = `${target}.tmp`;
			fs.writeFileSync(temp, JSON.stringify(next));
			fs.renameSync(temp, target);
			owned.add(target);
			file = target;
			record = next;
		} catch {}
	}

	const settled = (ctx: ExtensionContext) => publish(ctx, running ? "busy" : "idle");

	pi.on("session_start", (_event, ctx) => publish(ctx, "idle"));
	pi.on("session_switch", (_event, ctx) => {
		running = false;
		publish(ctx, "idle");
	});
	pi.on("session_branch", (_event, ctx) => settled(ctx));
	pi.on("session_shutdown", () => remove());

	pi.on("agent_start", (_event, ctx) => {
		running = true;
		publish(ctx, "busy");
	});
	pi.on("agent_end", (event, ctx) => {
		// Not finished while omp has already scheduled the next step or is waiting on background jobs.
		const end: Record<string, unknown> = { ...event };
		if (end.isTerminal === false || end.willContinue === true || end.awaitingAsyncWork === true) return;
		running = false;
		publish(ctx, "idle");
	});

	pi.on("tool_approval_requested", (_event, ctx) => publish(ctx, "waiting", "permission prompt"));
	pi.on("tool_approval_resolved", (_event, ctx) => settled(ctx));
	pi.on("tool_execution_start", (event, ctx) => {
		if (event.toolName === "ask") publish(ctx, "waiting", "input needed");
	});
	pi.on("tool_execution_end", (event, ctx) => {
		if (event.toolName === "ask") settled(ctx);
	});
	pi.on("plan_review_requested", (_event, ctx) => publish(ctx, "waiting", "input needed"));
	pi.on("plan_review_resolved", (_event, ctx) => settled(ctx));
}
