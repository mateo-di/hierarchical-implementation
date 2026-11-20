import { execFile } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)

export const DEFAULT_GATE_SCRIPT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../hooks/hierarchical-implementation-gate.sh",
)

export type GateVerdict = {
  decision: "passthrough" | "allow" | "deny"
  kind?: string
  reason?: string
  additionalContext?: string
}

export type GateRunner = (payload: Record<string, unknown>, env?: NodeJS.ProcessEnv) => Promise<GateVerdict>

export type OmpAgentIdentity = {
  kind?: "main" | "sub"
  id?: string
  name?: string
}

export type OmpContext = {
  cwd?: string
  agent?: OmpAgentIdentity
  sessionManager?: {
    getSessionId?: () => string | undefined
  }
}

export type OmpToolCallEvent = {
  toolName?: string
  tool?: string
  input?: Record<string, unknown>
}

export type OmpToolResultEvent = {
  toolName?: string
  tool?: string
  input?: Record<string, unknown>
  isError?: boolean
}

export type OmpExtensionAPI = {
  setLabel?: (label: string) => void
  on: (event: string, handler: (event: any, ctx?: OmpContext) => unknown) => void
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined
}

export function lineDelta(oldText: string, newText: string): number {
  const a = oldText.split("\n")
  const b = newText.split("\n")
  const minLen = Math.min(a.length, b.length)
  let prefix = 0
  while (prefix < minLen && a[prefix] === b[prefix]) prefix += 1
  let suffix = 0
  while (suffix < minLen - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix += 1
  return a.length + b.length - 2 * (prefix + suffix)
}

export function extractEditFiles(toolName: string, input: Record<string, unknown>): Array<{ path: string; changed: number }> {
  if (toolName === "write") {
    const filePath = stringValue(input.path) ?? stringValue(input.file_path)
    if (!filePath) return []
    const content = typeof input.content === "string" ? input.content : ""
    return [{ path: filePath, changed: content ? content.split("\n").length : 0 }]
  }

  // OMP hashline edit mode exposes normalized `paths` array (and optional `path` for single-file).
  if (Array.isArray(input.paths) && input.paths.length > 0) {
    const paths = input.paths.filter((entry): entry is string => typeof entry === "string" && entry.length > 0)
    const raw = stringValue(input.input) ?? stringValue(input._input) ?? ""
    const rawChanged = raw
      ? raw.split("\n").filter((line) => /^[+-]/.test(line) && !/^\+\+\+|^---/.test(line)).length
      : 0
    return paths.map((filePath, idx) => ({ path: filePath, changed: idx === 0 ? rawChanged : 0 }))
  }

  const filePath = stringValue(input.path) ?? stringValue(input._path) ?? stringValue(input.file_path)
  if (!filePath) return []

  let changed = 0
  const oldStr = stringValue(input.oldText) ?? stringValue(input.old_string) ?? stringValue(input.old_text)
  const newStr = typeof input.newText === "string"
    ? input.newText
    : typeof input.new_string === "string"
      ? input.new_string
      : typeof input.new_text === "string"
        ? input.new_text
        : undefined
  if (oldStr !== undefined || newStr !== undefined) {
    changed += lineDelta(oldStr ?? "", newStr ?? "")
  }
  if (Array.isArray(input.edits)) {
    for (const entry of input.edits) {
      if (!isRecord(entry)) continue
      const o = typeof entry.oldText === "string" ? entry.oldText : typeof entry.old_string === "string" ? entry.old_string : ""
      const n = typeof entry.newText === "string" ? entry.newText : typeof entry.new_string === "string" ? entry.new_string : ""
      changed += lineDelta(o, n)
    }
  }
  return [{ path: filePath, changed }]
}

export function createGateRunner(scriptPath = DEFAULT_GATE_SCRIPT): GateRunner {
  return async (payload, env = process.env): Promise<GateVerdict> => {
    try {
      const child = execFileAsync("bash", [scriptPath, "--harness", "generic"], {
        env,
        timeout: 10_000,
        maxBuffer: 4 * 1024 * 1024,
      })
      child.child.stdin?.end(JSON.stringify(payload))
      const { stdout } = await child
      const trimmed = stdout.trim()
      if (!trimmed) return { decision: "passthrough" }
      const parsed: unknown = JSON.parse(trimmed)
      if (!isRecord(parsed) || typeof parsed.decision !== "string") return { decision: "passthrough" }
      const decision = parsed.decision === "deny" || parsed.decision === "allow" ? parsed.decision : "passthrough"
      return {
        decision,
        ...(typeof parsed.kind === "string" ? { kind: parsed.kind } : {}),
        ...(typeof parsed.reason === "string" ? { reason: parsed.reason } : {}),
        ...(typeof parsed.additionalContext === "string" ? { additionalContext: parsed.additionalContext } : {}),
      }
    } catch {
      return { decision: "passthrough" }
    }
  }
}

const EDIT_TOOLS = new Set(["edit", "write", "ast_edit"])
const UNIT_AGENTS = new Set(["worker", "hierarchical-implementation:worker"])

function detectHarness(ctx?: OmpContext, env: NodeJS.ProcessEnv = process.env): "omp" | "pi" {
  if (env.HIERARCHICAL_GATE_HARNESS === "pi") return "pi"
  if (env.HIERARCHICAL_GATE_HARNESS === "omp") return "omp"
  if (env.OMPCODE === "1" || ctx?.agent !== undefined) return "omp"
  return "pi"
}

function isSubagent(ctx?: OmpContext): boolean {
  return ctx?.agent?.kind !== undefined && ctx.agent.kind !== "main"
}

function sessionIdOf(ctx?: OmpContext, fallback?: string): string {
  try {
    const id = ctx?.sessionManager?.getSessionId?.()
    if (typeof id === "string" && id.length > 0) return id
  } catch {
    // ignore
  }
  return fallback || "omp-session"
}

export function registerOmpPiGate(
  pi: OmpExtensionAPI,
  options: { gateScript?: string; runGate?: GateRunner; env?: NodeJS.ProcessEnv } = {},
): void {
  const runGate = options.runGate ?? createGateRunner(options.gateScript)
  const env = options.env ?? process.env
  const fallbackSessionId = `omp-${process.pid}-${Date.now()}`
  let sessionNoteSent = false

  pi.on("session_switch", () => {
    sessionNoteSent = false
  })
  pi.on("session_clear", () => {
    sessionNoteSent = false
  })

  pi.on("before_agent_start", async (_event, ctx) => {
    if (isSubagent(ctx) || sessionNoteSent) return undefined
    sessionNoteSent = true
    const harness = detectHarness(ctx, env)
    const sessionID = sessionIdOf(ctx, fallbackSessionId)
    const cwd = ctx?.cwd || process.cwd()
    const verdict = await runGate({ event: "session_start", harness, session_id: sessionID, cwd }, env)
    if (verdict.additionalContext) {
      return {
        message: {
          customType: "hierarchical-implementation",
          content: verdict.additionalContext,
          display: false,
        },
      }
    }
    return undefined
  })

  pi.on("tool_call", async (event: OmpToolCallEvent, ctx) => {
    if (isSubagent(ctx)) return undefined
    const toolName = (event?.toolName ?? event?.tool ?? "").toLowerCase()
    const input = isRecord(event?.input) ? event.input : {}
    const harness = detectHarness(ctx, env)
    const sessionID = sessionIdOf(ctx, fallbackSessionId)
    const cwd = ctx?.cwd || process.cwd()

    let payload: Record<string, unknown> | undefined
    if (EDIT_TOOLS.has(toolName)) {
      const files = extractEditFiles(toolName, input)
      if (files.length === 0) return undefined
      payload = { event: "pre_tool", harness, session_id: sessionID, cwd, tool: toolName, action: "edit", files }
    } else if (toolName === "bash") {
      const command = stringValue(input.command)
      if (!command) return undefined
      payload = { event: "pre_tool", harness, session_id: sessionID, cwd, tool: toolName, action: "shell", command }
    } else if (toolName === "task") {
      const agent = stringValue(input.agent) ?? "task"
      const name = stringValue(input.name) ?? agent
      const model = stringValue(input.model) ?? ""
      payload = {
        event: "pre_tool",
        harness,
        session_id: sessionID,
        cwd,
        tool: toolName,
        action: "spawn",
        worker: { name, type: agent, model, unit: UNIT_AGENTS.has(agent.toLowerCase()) },
      }
    }

    if (!payload) return undefined
    const verdict = await runGate(payload, env)
    if (verdict.decision === "deny") {
      return { block: true, reason: verdict.reason || "Blocked by hierarchical-implementation delegation gate." }
    }
    return undefined
  })

  pi.on("tool_result", async (event: OmpToolResultEvent, ctx) => {
    if (isSubagent(ctx) || event?.isError === true) return undefined
    const toolName = (event?.toolName ?? event?.tool ?? "").toLowerCase()
    const input = isRecord(event?.input) ? event.input : {}
    const harness = detectHarness(ctx, env)
    const sessionID = sessionIdOf(ctx, fallbackSessionId)
    const cwd = ctx?.cwd || process.cwd()

    if (toolName === "bash") {
      const command = stringValue(input.command)
      if (!command) return undefined
      await runGate({ event: "post_tool", harness, session_id: sessionID, cwd, tool: toolName, action: "shell", command }, env)
    } else if (toolName === "task") {
      const agent = stringValue(input.agent) ?? "task"
      const name = stringValue(input.name) ?? agent
      const model = stringValue(input.model) ?? ""
      await runGate({
        event: "post_tool",
        harness,
        session_id: sessionID,
        cwd,
        tool: toolName,
        action: "spawn",
        worker: { name, type: agent, model },
      }, env)
    }
    return undefined
  })
}
