// funnotch-sessions — publishes each omp session's status for Fun Notch.
//
// Fun Notch shows Claude Code sessions by reading the registry Claude Code keeps
// in ~/.claude/sessions. omp keeps no such registry, so this extension writes one
// in the same shape to ~/.omp/notch-sessions/<pid>-<sessionId>.json: one file per
// session (an ACP host such as Orca can run several sessions in one process),
// with a status of busy, waiting or idle, the tool running right now, and the
// session's token use. Nothing from the conversation itself is written.
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
	/** The tool running right now, e.g. "bash" or "task ×3". */
	activity?: string;
	/** Tokens of every assistant reply in this session, cache reads included. */
	tokens: number;
	/** USD, as the provider or omp's price table reports it; 0 on subscriptions. */
	cost: number;
	/** Tokens currently in the context window, and the window's size. */
	contextTokens?: number;
	contextWindow?: number;
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

/** Tokens and cost of one assistant message's `usage`, or nothing for other messages. */
function assistantUsage(message: unknown): { tokens: number; cost: number } | undefined {
	if (!message || typeof message !== "object" || !("role" in message) || message.role !== "assistant") return;
	if (!("usage" in message) || !message.usage || typeof message.usage !== "object") return;
	const usage = message.usage as Record<string, unknown>;
	const count = (key: string) => (typeof usage[key] === "number" ? (usage[key] as number) : 0);
	const tokens =
		count("totalTokens") || count("input") + count("output") + count("cacheRead") + count("cacheWrite");
	const costTable = usage.cost && typeof usage.cost === "object" ? (usage.cost as Record<string, unknown>) : {};
	return { tokens, cost: typeof costTable.total === "number" ? costTable.total : 0 };
}

function toolLabel(toolName: string, args: unknown): string {
	if (toolName === "task" && args && typeof args === "object" && "tasks" in args && Array.isArray(args.tasks)) {
		return `task ×${args.tasks.length}`;
	}
	return toolName;
}

export default function (pi: ExtensionAPI): void {
	let file: string | null = null;
	let record: Entry | null = null;
	let running = false;
	let tokens = 0;
	let cost = 0;
	// Tools running right now, by call id; the newest one is what the notch shows.
	const activeTools = new Map<string, string>();

	function remove(): void {
		if (!file) return;
		removeFile(file);
		owned.delete(file);
		file = null;
		record = null;
	}

	// Sums what the session has already spent, for a resumed or switched-to session.
	function recount(ctx: ExtensionContext): void {
		tokens = 0;
		cost = 0;
		try {
			for (const entry of ctx.sessionManager.getBranch()) {
				if (entry.type !== "message") continue;
				const usage = assistantUsage(entry.message);
				if (!usage) continue;
				tokens += usage.tokens;
				cost += usage.cost;
			}
		} catch {}
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
			let contextTokens: number | undefined;
			let contextWindow: number | undefined;
			try {
				const usage = ctx.getContextUsage();
				contextTokens = typeof usage?.tokens === "number" ? usage.tokens : undefined;
				contextWindow = typeof usage?.contextWindow === "number" ? usage.contextWindow : ctx.model?.contextWindow;
			} catch {}
			const activity = [...activeTools.values()].at(-1);

			const next: Entry = {
				pid: process.pid,
				sessionId,
				cwd: ctx.cwd || process.cwd(),
				name,
				status,
				...(waitingFor ? { waitingFor } : {}),
				...(activity ? { activity } : {}),
				tokens,
				cost,
				...(contextTokens !== undefined ? { contextTokens } : {}),
				...(contextWindow !== undefined ? { contextWindow } : {}),
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

	// Writes the latest activity or usage without changing the status.
	const republish = (ctx: ExtensionContext) => publish(ctx, record?.status ?? "idle", record?.waitingFor);
	const settled = (ctx: ExtensionContext) => publish(ctx, running ? "busy" : "idle");

	pi.on("session_start", (_event, ctx) => {
		recount(ctx);
		publish(ctx, "idle");
	});
	pi.on("session_switch", (_event, ctx) => {
		running = false;
		activeTools.clear();
		recount(ctx);
		publish(ctx, "idle");
	});
	pi.on("session_branch", (_event, ctx) => {
		recount(ctx);
		settled(ctx);
	});
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
		activeTools.clear();
		publish(ctx, "idle");
	});
	pi.on("message_end", (event, ctx) => {
		const usage = assistantUsage(event.message);
		if (!usage) return;
		tokens += usage.tokens;
		cost += usage.cost;
		republish(ctx);
	});

	pi.on("tool_approval_requested", (_event, ctx) => publish(ctx, "waiting", "permission prompt"));
	pi.on("tool_approval_resolved", (_event, ctx) => settled(ctx));
	pi.on("tool_execution_start", (event, ctx) => {
		activeTools.set(event.toolCallId, toolLabel(event.toolName, event.args));
		if (event.toolName === "ask") publish(ctx, "waiting", "input needed");
		else republish(ctx);
	});
	pi.on("tool_execution_end", (event, ctx) => {
		activeTools.delete(event.toolCallId);
		if (event.toolName === "ask") settled(ctx);
		else republish(ctx);
	});
	pi.on("plan_review_requested", (_event, ctx) => publish(ctx, "waiting", "input needed"));
	pi.on("plan_review_resolved", (_event, ctx) => settled(ctx));
}
