<!-- Excerpt to merge into ~/.claude/CLAUDE.md. The skill and the hook's deny text refer to these sections. -->

## When to Use Agents

| Task | Agent | Why |
|------|-------|-----|
| Implementation beyond a small edit | `hierarchical-implementation` skill | Default, with standing authorization for editing workers: named workers execute, one per unit (a coupled change is one unit); the main session briefs, reviews, sends corrections to the same worker for up to three rounds, and integrates. Work directly only when the whole task is a small edit (up to 3 files and 60 changed lines), a lane a coordinator spawned with `LANE_MODE=unit` to execute a unit it reviews (a `LANE_MODE=driver` lane delegates like a main session but spawns no further sessions), an opt-out, or in a harness without subagents; changes to the agent's own controls (hooks, gates, agent settings and permissions, CLAUDE.md, AGENTS.md, skill and agent definitions) or to files that hold secrets are never delegated and cover only the files named; repo ownership, CI and IAM files go to workers; workers spawn no agents |
| Subagent on a model I name ("use fable", "run it on deepseek") | Agent tool `model` for an Anthropic alias; otherwise the hierarchical-implementation skill's `free-models.sh run --model <provider/model>` when `opencode models` lists it | Never substitute: an unavailable model is reported and I pick. With `HI_FREE_WORKERS=1`, implementation units try free models first and fall back to an Agent worker |

- **The writer is not the verifier.** For PR-bound work, the final check runs in a fresh subagent that did not write the code and gets only the success criteria and the branch, because an author checks what it meant to build. For wide or risky changes, add a second model family through the codex CLI (`codex exec --sandbox read-only`); if it is unavailable, use a fresh subagent on a different Claude model and say so.

### Parallel Agent Git Safety

Git enforces **one worktree per branch** — two worktrees cannot check out the same branch at once (`fatal: '<branch>' is already used by worktree at '<path>'`). So parallelizing agents on worktrees only works when each agent is also on its own distinct branch.

**Normal case — each agent gets its own branch:**
```bash
# Agent 1: works on the original repo (stays on its current branch)
~/vscode/my-repo

# Agent 2: own worktree, own branch
git -C ~/vscode/my-repo worktree add ~/vscode/my-repo/.worktrees/agent2 -b agent2-<short-desc>

# Agent 3: own worktree, own branch
git -C ~/vscode/my-repo worktree add ~/vscode/my-repo/.worktrees/agent3 -b agent3-<short-desc>
```

**If agents must ultimately land work on ONE shared branch:** do NOT give them worktrees on that same branch — git will refuse it, and `--force` produces silent split-brain state (two working trees both claiming to be the branch's tip), not a real fix. Instead:
1. Each agent works on its own throwaway branch (as above) in its own worktree.
2. Once agents finish, the **lead** integrates each branch into the shared branch **one at a time, never concurrently** (cherry-pick or merge), resolving overlap manually.
3. Clean up agent branches/worktrees after integration.

**Rules:**
- The **team lead** is responsible for creating worktrees/branches before spawning agents and assigning each agent its working directory
- Clean up worktrees after agents finish (`git worktree remove`)
- Only the lead writes to the shared branch or merges changes back to the main working copy
- Read-only agents (Explore, Plan) can share the original repo safely

## Rules and what enforces them

| Rule | Enforced by |
|---|---|
| Record delegate or a direct exemption before the main session's first edit in a `~/vscode` worktree, or its first worker (the plugin's worker agent or a free-model run) while it works in one; delegate needs a worker spawned after the decision and keeps the driver to an integration budget; trivial covers 3 files and a line cap that commits do not reset; security covers the files it names, which must be agent-control or secrets paths; lane needs `LANE_MODE=unit`; named workers carry a model | `hierarchical-implementation-gate.sh` from the hierarchical-implementation plugin (edits plus recognized shell writes; logs decisions, spawns, messages and denials). Whether a review is critical is prose only |
