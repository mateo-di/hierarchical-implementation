import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { test } from "node:test"

import {
  DEFAULT_GATE_SCRIPT,
  registerOmpPiGate,
  type OmpContext,
  type OmpExtensionAPI,
} from "./gate-client.ts"

function setupFixture() {
  const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "hi-omp-")))
  const root = path.join(tmp, "vscode")
  const repo = path.join(root, "repo")
  fs.mkdirSync(path.join(repo, "src"), { recursive: true })
  fs.writeFileSync(path.join(repo, "src", "a.ts"), "one\ntwo\n")
  execFileSync("git", ["init", "-q", "-b", "main", repo])
  execFileSync("git", ["-C", repo, "add", "src/a.ts"])
  execFileSync("git", ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"])

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    XDG_STATE_HOME: path.join(tmp, "state"),
    HIERARCHICAL_GATE_ROOT: root,
    DELEGATION_LOG: path.join(tmp, "decisions.tsv"),
    DELEGATION_EVENTS: path.join(tmp, "events.tsv"),
  }
  delete env.LANE_MODE
  delete env.HI_FREE_WORKERS
  delete env.HIERARCHICAL_GATE

  const handlers = new Map<string, (event: any, ctx?: OmpContext) => unknown>()
  const api: OmpExtensionAPI = {
    setLabel: () => {},
    on: (event, handler) => {
      handlers.set(event, handler)
    },
  }
  registerOmpPiGate(api, { env })

  const mainCtx: OmpContext = {
    cwd: repo,
    agent: { kind: "main", id: "Main", name: "main" },
    sessionManager: { getSessionId: () => "omp_sess_1" },
  }
  const subCtx: OmpContext = {
    cwd: repo,
    agent: { kind: "sub", id: "0-worker", name: "worker" },
    sessionManager: { getSessionId: () => "omp_sess_1" },
  }

  const decide = (...args: string[]) =>
    execFileSync("bash", [DEFAULT_GATE_SCRIPT, "decide", ...args], { env, encoding: "utf8" })

  const cleanup = () => fs.rmSync(tmp, { recursive: true, force: true })

  return { repo, env, handlers, mainCtx, subCtx, decide, cleanup }
}

test("omp/pi extension blocks undecided main edits, skips subagents, and unlocks after task worker spawn", async () => {
  const fx = setupFixture()
  try {
    const toolCall = fx.handlers.get("tool_call")!
    const toolResult = fx.handlers.get("tool_result")!

    const denied = (await toolCall({ toolName: "edit", input: { path: "src/a.ts", oldText: "one", newText: "uno" } }, fx.mainCtx)) as any
    assert.equal(denied?.block, true)
    assert.match(denied?.reason ?? "", /decide .* omp_sess_1 delegate/)
    assert.match(denied?.reason ?? "", /task tool/)

    // Subagent edits are never gated.
    const subAllowed = await toolCall({ toolName: "edit", input: { path: "src/a.ts", oldText: "one", newText: "uno" } }, fx.subCtx)
    assert.equal(subAllowed, undefined)

    // Unit worker spawn before decision is blocked.
    const spawnDenied = (await toolCall({ toolName: "task", input: { agent: "worker", name: "parser" } }, fx.mainCtx)) as any
    assert.equal(spawnDenied?.block, true)
    assert.match(spawnDenied?.reason ?? "", /Record the decision before the first worker/)

    // Decide delegate and run a worker task.
    fx.decide(fx.repo, "omp_sess_1", "delegate", "parser and test units")
    const spawnAllowed = await toolCall({ toolName: "task", input: { agent: "worker", name: "parser" } }, fx.mainCtx)
    assert.equal(spawnAllowed, undefined)
    await toolResult({ toolName: "task", input: { agent: "worker", name: "parser", model: "sonnet" }, isError: false }, fx.mainCtx)

    // Now driver integration edit passes.
    const driverAllowed = await toolCall({ toolName: "edit", input: { path: "src/a.ts", oldText: "one", newText: "uno" } }, fx.mainCtx)
    assert.equal(driverAllowed, undefined)
  } finally {
    fx.cleanup()
  }
})

test("omp/pi extension enforces hashline multi-file edit paths against trivial file cap", async () => {
  const fx = setupFixture()
  try {
    const toolCall = fx.handlers.get("tool_call")!
    fx.decide(fx.repo, "omp_sess_1", "direct", "trivial: tiny multi file tweak")

    const ok = await toolCall(
      { toolName: "edit", input: { paths: ["src/a.ts", "src/b.ts", "src/c.ts"], input: "+one\n+two" } },
      fx.mainCtx,
    )
    assert.equal(ok, undefined)

    const over = (await toolCall(
      { toolName: "edit", input: { paths: ["src/d.ts"], input: "+three" } },
      fx.mainCtx,
    )) as any
    assert.equal(over?.block, true)
    assert.match(over?.reason ?? "", /covers up to 3 files/)
  } finally {
    fx.cleanup()
  }
})
