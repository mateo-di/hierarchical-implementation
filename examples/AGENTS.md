<!-- Harness-neutral policy excerpt to merge into AGENTS.md / GEMINI.md (for OpenCode, Antigravity CLI, OMP, Codex, Gemini CLI, Cursor or Pi). -->

## When to Use Agents

| Task | Agent | Why |
|------|-------|-----|
| Implementation beyond a small edit | `hierarchical-implementation` skill | Default, with standing authorization for editing workers: named workers execute, one per unit (a coupled change is one unit); the main session briefs, reviews, sends corrections to the same worker for up to three rounds, and integrates. Work directly only when the whole task is a small edit (up to 3 files and 60 changed lines), a lane a coordinator spawned with `LANE_MODE=unit` to execute a unit it reviews (a `LANE_MODE=driver` lane delegates like a main session but spawns no further sessions), an opt-out, or in a harness without subagents; changes to the agent's own controls (hooks, gates, agent settings and permissions, CLAUDE.md, AGENTS.md, GEMINI.md, skill and agent definitions) or to files that hold secrets are never delegated and cover only the files named; repo ownership, CI and IAM files go to workers; workers spawn no agents |
| Subagent on a model I name | The harness's native model parameter, or `free-models.sh run --model <provider/model>` when `opencode models` lists it | Never substitute: an unavailable model is reported and I pick. With `HI_FREE_WORKERS=1`, implementation units try free models first and fall back to a native worker |

- **The writer is not the verifier.** For PR-bound work, run the final verification in a fresh subagent that did not write the code and gets only the success criteria and the branch.

### Parallel Agent Git Safety

Git enforces **one worktree per branch**: two worktrees cannot check out the same branch at once. Give each parallel worker its own worktree and branch:

```bash
git -C ~/vscode/my-repo worktree add ~/vscode/my-repo/.worktrees/worker1 -b worker1-<short-desc>
```

When parallel workers must land on one shared branch, each commits on its own throwaway branch and the driver integrates branches one at a time (never concurrently), resolving overlaps manually and removing the worktrees afterward.

## Enforcement

| Rule | Enforced by |
|------|-------------|
| Record `delegate` or a direct exemption before the main session's first edit or first worker in a `~/vscode` worktree; `delegate` needs a worker spawned after the decision and keeps the driver to an integration budget; `trivial` covers 3 files and 60 changed lines that commits do not reset; `security` covers only the agent-control or secrets files it names; `lane` needs `LANE_MODE=unit` | `hierarchical-implementation-gate.sh` and its harness adapter (`adapters/opencode`, `adapters/agy`, `adapters/omp-pi`, `adapters/codex`, `adapters/gemini`, `adapters/cursor`) |
