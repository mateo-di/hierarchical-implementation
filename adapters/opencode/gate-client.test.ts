import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { test } from "node:test"

import {
  DEFAULT_GATE_SCRIPT,
  setupOpenCodeGate,
  type OpenCodeSessionInfo,
  type OpenCodeToolAfterEvent,
  type OpenCodeToolBeforeEvent,
} from "./gate-client.ts"

function setupFixture(workerAgents: string[] = []) {
  const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "hi-opencode-")))
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

  const sessions = new Map<string, OpenCodeSessionInfo>([
    ["ses_root1", { id: "ses_root1", agent: "build", location: { directory: repo } }],
    ["ses_child1", { id: "ses_child1", parentID: "ses_root1", agent: "general", location: { directory: repo } }],
    ["ses_lane1", { id: "ses_lane1", agent: "lane-worker", location: { directory: repo } }],
  ])

  let beforeHook: ((event: OpenCodeToolBeforeEvent) => Promise<void> | void) | undefined
  let afterHook: ((event: OpenCodeToolAfterEvent) => Promise<void> | void) | undefined

  const ready = setupOpenCodeGate({
    ...{ workerAgents },
    env,
    session: { get: async (id) => sessions.get(id) },
    tool: {
      hook: async (name, cb) => {
        if (name === "execute.before") beforeHook = cb as (event: OpenCodeToolBeforeEvent) => Promise<void> | void
        else afterHook = cb as (event: OpenCodeToolAfterEvent) => Promise<void> | void
      },
    },
  })

  const decide = (...args: string[]) =>
    execFileSync("bash", [DEFAULT_GATE_SCRIPT, "decide", ...args], { env, encoding: "utf8" })

  const cleanup = () => fs.rmSync(tmp, { recursive: true, force: true })

  return {
    repo,
    env,
    ready,
    decide,
    cleanup,
    before: async (event: OpenCodeToolBeforeEvent) => {
      await ready
      await beforeHook!(event)
    },
    after: async (event: OpenCodeToolAfterEvent) => {
      await ready
      await afterHook!(event)
    },
  }
}

test("opencode adapter denies undecided root edit, allows subagent edit, and unlocks after decide + spawn", async () => {
  const fx = setupFixture()
  try {
    await assert.rejects(
      () => fx.before({ tool: "edit", sessionID: "ses_root1", input: { path: "src/a.ts", oldString: "one", newString: "uno" } }),
      /decide .* ses_root1 delegate/,
    )

    // Child subagent session is never gated.
    await fx.before({ tool: "edit", sessionID: "ses_child1", input: { path: "src/a.ts", oldString: "one", newString: "uno" } })

    // Headless free-models.sh lane-worker session is never gated (it cannot run decide).
    await fx.before({ tool: "edit", sessionID: "ses_lane1", agent: "lane-worker", input: { path: "src/a.ts", oldString: "one", newString: "uno" } })

    // Spawning general before any decision is denied; explore (read-only) passes.
    await fx.before({ tool: "subagent", sessionID: "ses_root1", input: { agent: "explore", description: "read code" } })
    await assert.rejects(
      () => fx.before({ tool: "subagent", sessionID: "ses_root1", input: { agent: "general", name: "parser", model: "opencode-go/hy4-flash-free" } }),
      /Record the decision before the first worker/,
    )

    // Decide command itself passes through shell pre-check.
    await fx.before({
      tool: "shell",
      sessionID: "ses_root1",
      input: { command: `${DEFAULT_GATE_SCRIPT} decide ${fx.repo} ses_root1 delegate "parser and cli units"` },
    })
    fx.decide(fx.repo, "ses_root1", "delegate", "parser and cli units")

    // Delegate without a spawned worker still denies driver edits.
    await assert.rejects(
      () => fx.before({ tool: "edit", sessionID: "ses_root1", input: { path: "src/a.ts", oldString: "one", newString: "uno" } }),
      /has not spawned a worker/,
    )

    // Spawning a subagent logs the worker, tracks its child session for message attribution, and unlocks driver edits.
    await fx.after({
      tool: "subagent",
      sessionID: "ses_root1",
      status: "completed",
      input: { agent: "general", name: "parser", model: "opencode-go/hy4-flash-free" },
      result: { metadata: { sessionID: "ses_child1" } },
    })
    await fx.after({
      tool: "subagent",
      sessionID: "ses_root1",
      status: "completed",
      input: { sessionID: "ses_child1", prompt: "Fix edge case" },
    })
    const events = fs.readFileSync(fx.env.DELEGATION_EVENTS!, "utf8")
    assert.match(events, /\tspawn\tparser\topencode-go\/hy4-flash-free\tgeneral/)
    assert.match(events, /\tmessage\tparser\t/)
    await fx.before({ tool: "edit", sessionID: "ses_root1", input: { path: "src/a.ts", oldString: "one", newString: "uno" } })
  } finally {
    fx.cleanup()
  }
})

test("opencode adapter gates multi-file patch payloads and enforces trivial file/line budgets", async () => {
  const fx = setupFixture()
  try {
    fx.decide(fx.repo, "ses_root1", "direct", "trivial: small two file fix")

    const smallPatch = [
      "*** Begin Patch",
      "*** Update File: src/a.ts",
      "@@",
      "-one",
      "+uno",
      "*** Add File: src/b.ts",
      "+export const b = 1",
      "*** Add File: src/c.ts",
      "+export const c = 2",
      "*** End Patch",
    ].join("\n")
    await fx.before({ tool: "patch", sessionID: "ses_root1", input: { patchText: smallPatch } })

    const fourthFilePatch = [
      "*** Begin Patch",
      "*** Add File: src/d.ts",
      "+export const d = 3",
      "*** End Patch",
    ].join("\n")
    await assert.rejects(
      () => fx.before({ tool: "patch", sessionID: "ses_root1", input: { patchText: fourthFilePatch } }),
      /covers up to 3 files/,
    )
  } finally {
    fx.cleanup()
  }
})

test("opencode counts a configured custom worker but not a read-only specialist", async () => {
  const fx = setupFixture(["mid.agent"])
  try {
    const edit = { tool: "edit", sessionID: "ses_root1", input: { path: "src/a.ts", oldString: "one", newString: "uno" } }
    const worker = { tool: "subagent", sessionID: "ses_root1", input: { agent: "mid.agent", name: "parser" } }
    const specialist = { tool: "subagent", sessionID: "ses_root1", input: { agent: "code-reviewer" } }
    await fx.before(specialist)
    fx.decide(fx.repo, "ses_root1", "delegate", "implement parser unit")
    await fx.after({ ...specialist, status: "completed" })
    await assert.rejects(() => fx.before(edit), /has not spawned a worker/)
    await fx.before(worker)
    await fx.after({ ...worker, status: "completed" })
    await fx.before(edit)
  } finally {
    fx.cleanup()
  }
})
