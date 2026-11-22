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

export type OpenCodeSessionInfo = {
  id?: string
  parentID?: string
  agent?: string
  location?: { directory?: string }
}

export type OpenCodeToolBeforeEvent = {
  tool: string
  sessionID: string
  agent?: string
  id?: string
  input: unknown
}

export type OpenCodeToolAfterEvent = OpenCodeToolBeforeEvent & {
  status?: "completed" | "error"
  result?: unknown
}

export type OpenCodeGateRuntime = {
  gateScript?: string
  runGate?: GateRunner
  env?: NodeJS.ProcessEnv
  workerAgents?: readonly string[]
  session: {
    get: (sessionID: string) => Promise<OpenCodeSessionInfo | undefined>
  }
  tool: {
    hook: (
      name: "execute.before" | "execute.after",
      callback: (event: OpenCodeToolBeforeEvent | OpenCodeToolAfterEvent) => Promise<void> | void,
    ) => Promise<unknown>
  }
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

export function computeEditChanges(tool: string, input: unknown): { files: Array<{ path: string; changed: number }> } | { patch: string } | undefined {
  if (!isRecord(input)) return undefined
  if (tool === "patch") {
    const patchText = stringValue(input.patchText) ?? stringValue(input.patch) ?? stringValue(input.input)
    return patchText ? { patch: patchText } : undefined
  }
  const filePath = stringValue(input.path) ?? stringValue(input.filePath) ?? stringValue(input.file_path)
  if (!filePath) return undefined

  let changed = 0
  if (typeof input.content === "string") {
    changed += input.content.split("\n").length
  }
  const oldStr = typeof input.oldString === "string" ? input.oldString : typeof input.old_string === "string" ? input.old_string : undefined
  const newStr = typeof input.newString === "string" ? input.newString : typeof input.new_string === "string" ? input.new_string : undefined
  if (oldStr !== undefined || newStr !== undefined) {
    changed += lineDelta(oldStr ?? "", newStr ?? "")
  }
  if (Array.isArray(input.edits)) {
    for (const entry of input.edits) {
      if (!isRecord(entry)) continue
      const o = typeof entry.oldString === "string" ? entry.oldString : typeof entry.old_string === "string" ? entry.old_string : ""
      const n = typeof entry.newString === "string" ? entry.newString : typeof entry.new_string === "string" ? entry.new_string : ""
      changed += lineDelta(o, n)
    }
  }
  return { files: [{ path: filePath, changed }] }
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

const EDIT_TOOLS = new Set(["edit", "write", "patch", "multiedit"])
const SHELL_TOOLS = new Set(["shell", "bash"])
const UNIT_AGENTS = new Set(["worker", "hierarchical-implementation:worker", "general"])

function childSessionIDFromResult(result: unknown): string | undefined {
  if (!isRecord(result)) return undefined
  for (const candidate of [result, result.output, result.metadata]) {
    if (isRecord(candidate) && typeof candidate.sessionID === "string" && candidate.sessionID.length > 0) {
      return candidate.sessionID
    }
  }
  return undefined
}

function workerModelFromInput(input: Record<string, unknown>): string {
  if (typeof input.model === "string") return input.model
  if (isRecord(input.model)) {
    const provider = stringValue(input.model.providerID) ?? stringValue(input.model.provider)
    const id = stringValue(input.model.id) ?? stringValue(input.model.modelID)
    if (provider && id) return `${provider}/${id}`
    if (id) return id
  }
  return ""
}

export async function setupOpenCodeGate(runtime: OpenCodeGateRuntime): Promise<void> {
  const baseRunner = runtime.runGate ?? createGateRunner(runtime.gateScript)
  const runGate: GateRunner = (payload) => baseRunner(payload, runtime.env)
  const freeWorkerAgent = (runtime.env?.HI_FREE_AGENT || process.env.HI_FREE_AGENT || "lane-worker").toLowerCase()
  const customWorkers = new Set(runtime.workerAgents?.map((agent) => agent.toLowerCase()))
  const childWorkerNames = new Map<string, string>()

  function workerType(agent: string): string {
    const id = agent.toLowerCase()
    if (UNIT_AGENTS.has(id)) return id
    return customWorkers.has(id) ? "worker" : agent
  }

  async function resolveRootSession(sessionID: string, eventAgent?: string): Promise<{ cwd: string } | undefined> {
    if (eventAgent && eventAgent.toLowerCase() === freeWorkerAgent) return undefined
    try {
      const session = await runtime.session.get(sessionID)
      if (!session || session.parentID) return undefined
      if (session.agent && session.agent.toLowerCase() === freeWorkerAgent) return undefined
      return { cwd: session.location?.directory || process.cwd() }
    } catch {
      return undefined
    }
  }

  await runtime.tool.hook("execute.before", async (event) => {
    const root = await resolveRootSession(event.sessionID, event.agent)
    if (!root) return

    let payload: Record<string, unknown> | undefined
    if (EDIT_TOOLS.has(event.tool)) {
      const changes = computeEditChanges(event.tool, event.input)
      if (!changes) return
      payload = "patch" in changes
        ? { event: "pre_tool", harness: "opencode", session_id: event.sessionID, cwd: root.cwd, tool: event.tool, action: "patch", patch: changes.patch }
        : { event: "pre_tool", harness: "opencode", session_id: event.sessionID, cwd: root.cwd, tool: event.tool, action: "edit", files: changes.files }
    } else if (SHELL_TOOLS.has(event.tool) && isRecord(event.input)) {
      const command = stringValue(event.input.command)
      if (!command) return
      payload = { event: "pre_tool", harness: "opencode", session_id: event.sessionID, cwd: root.cwd, tool: event.tool, action: "shell", command }
    } else if (event.tool === "subagent" && isRecord(event.input)) {
      const resumeID = stringValue(event.input.sessionID)
      if (resumeID) return
      const agent = stringValue(event.input.agent) ?? "general"
      const name = stringValue(event.input.name) ?? stringValue(event.input.description) ?? agent
      const model = workerModelFromInput(event.input)
      const type = workerType(agent)
      payload = {
        event: "pre_tool",
        harness: "opencode",
        session_id: event.sessionID,
        cwd: root.cwd,
        tool: event.tool,
        action: "spawn",
        worker: { name, type, model, unit: UNIT_AGENTS.has(type) },
      }
    }

    if (!payload) return
    const verdict = await runGate(payload)
    if (verdict.decision === "deny") {
      throw new Error(verdict.reason || "Blocked by hierarchical-implementation delegation gate.")
    }
  })

  await runtime.tool.hook("execute.after", async (rawEvent) => {
    const event = rawEvent as OpenCodeToolAfterEvent
    if (event.status === "error") return
    const root = await resolveRootSession(event.sessionID, event.agent)
    if (!root) return

    if (SHELL_TOOLS.has(event.tool) && isRecord(event.input)) {
      const command = stringValue(event.input.command)
      if (!command) return
      await runGate({ event: "post_tool", harness: "opencode", session_id: event.sessionID, cwd: root.cwd, tool: event.tool, action: "shell", command })
      return
    }

    if (event.tool === "subagent" && isRecord(event.input)) {
      const resumeID = stringValue(event.input.sessionID)
      if (resumeID) {
        const targetName = childWorkerNames.get(resumeID) ?? stringValue(event.input.name) ?? resumeID
        await runGate({
          event: "post_tool",
          harness: "opencode",
          session_id: event.sessionID,
          cwd: root.cwd,
          tool: event.tool,
          action: "message",
          worker: { name: targetName },
        })
        return
      }
      const agent = stringValue(event.input.agent) ?? "general"
      const name = stringValue(event.input.name) ?? stringValue(event.input.description) ?? agent
      const model = workerModelFromInput(event.input)
      const childID = childSessionIDFromResult(event.result)
      if (childID) childWorkerNames.set(childID, name)
      await runGate({
        event: "post_tool",
        harness: "opencode",
        session_id: event.sessionID,
        cwd: root.cwd,
        tool: event.tool,
        action: "spawn",
        worker: { name, type: workerType(agent), model },
      })
    }
  })
}
