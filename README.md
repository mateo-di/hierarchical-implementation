# hierarchical-implementation

A Claude Code plugin that makes worker subagents the default for implementation. The main session acts as a driver. It plans, briefs one named worker per unit, reviews each result critically, sends corrections to the same worker, and integrates. A hook holds the driver to that: it must decide before its first edit, and each decision only allows what it claims.

## Install

```bash
claude plugin marketplace add mateo-di/hierarchical-implementation
claude plugin install hierarchical-implementation@hierarchical-implementation
```

Then merge [examples/CLAUDE.md](examples/CLAUDE.md) into `~/.claude/CLAUDE.md`. It holds the policy row the skill and the hook refer to, including the standing authorization for editing workers. Hooks load when a session starts, so restart open sessions.

Requirements: Claude Code with the Agent and SendMessage tools, `bash`, `git`, `jq`.

## How it works

There are three layers.

1. **Policy** ([examples/CLAUDE.md](examples/CLAUDE.md)). Delegation is the default for anything beyond a trivial edit, and Claude does not ask before spawning editing workers.
2. **Procedure** ([skills/hierarchical-implementation/SKILL.md](skills/hierarchical-implementation/SKILL.md)). The skill covers:
   - splitting work into units, one todo per unit (a coupled change is one unit);
   - what goes into a brief;
   - isolating workers in their own worktrees and branches;
   - critical review: accept, correct or redo;
   - corrections through `SendMessage`, at most three rounds per unit;
   - integration.
3. **Enforcement** ([hooks/hierarchical-implementation-gate.sh](hooks/hierarchical-implementation-gate.sh), registered by [hooks/hooks.json](hooks/hooks.json)).

### The hook

- **The first edit.** In a worktree under `HIERARCHICAL_GATE_ROOT`, the main thread's first edit is denied until the session records a decision. The deny reason works as a just-in-time prompt: Claude reads it at the moment it wants to edit. It carries the ready-to-run `decide` commands, the exemption list and the review loop. Subagents are never gated.
- **Recording a decision.** The hook approves its own `decide` command, but only in its exact form with inert arguments, so recording costs no permission prompt. Each decision is appended to a log.
- **Each decision is held to its scope:**
  - `delegate`: the driver's edits are denied until a worker has been spawned in the session. After that they count against an integration budget of changed lines per worktree. Past the budget, the edit is authoring and should go to a worker.
  - `trivial`: one file, up to a cap of changed lines.
  - `security`: only the files named when it was recorded. "Security" means the agent's own controls (hooks, gates, agent settings and permissions, `CLAUDE.md`, `AGENTS.md`, skill and agent definitions) or secret values. Repo ownership, CI and IAM files go to workers.
  - `lane`, `opt-out`, `no-subagents`: the whole worktree.
- **Shell writes** through `>`, `>>`, `tee`, `sed -i` and `perl -i` go through the same rules as edits.
- **Named worker calls** (`Agent` with `name`) must set `model`.
- **Logging.** Worker spawns and `SendMessage` calls are logged.

```bash
hierarchical-implementation-gate.sh decide <worktree> <session> delegate "<units>"
hierarchical-implementation-gate.sh decide <worktree> <session> direct "<exemption>: <why>"
hierarchical-implementation-gate.sh decide <worktree> <session> direct "security: <why>" <file>...
hierarchical-implementation-gate.sh report
```

`report` prints each session's decision with its spawn and message counts. A run of `delegate` sessions with no messages suggests reviews that never sent a correction.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `HIERARCHICAL_GATE_ROOT` | `~/vscode` | Only paths under this directory are gated |
| `HIERARCHICAL_GATE` | `on` | `off` disables the hook |
| `TRIVIAL_MAX_LINES` | `20` | Changed-line cap for a trivial exemption |
| `INTEGRATE_MAX_LINES` | `60` | Driver's changed-line budget per worktree under delegate |
| `XDG_STATE_HOME` | `~/.local/state` | Per-session state lives under `$XDG_STATE_HOME/claude-gates/delegation/` |
| `DELEGATION_LOG` | `…/claude-gates/delegation-decisions.tsv` | Decisions: time, session, worktree, choice, reason, named files |
| `DELEGATION_EVENTS` | `…/claude-gates/delegation-events.tsv` | Spawns and messages: time, session, kind, target, model, agent type |

Set these in the environment Claude Code starts with.

## Tests

```bash
bash hooks/hierarchical-implementation-gate.test.sh
```

## What it does not enforce

- **Whether a review was critical.** The log shows messages were sent, not whether they were right.
- **Unit boundaries.** A spawned worker can still edit outside the files it owns. The skill has the driver check `git diff --name-only`.
- **Uncommon shell writes.** `cp`, `mv`, `patch`, `git apply`, scripts, and redirects without a space before the target are not recognized. Shell writes under `delegate` don't count against the budget.
- **Classification.** Claude still picks the exemption itself. The hook only bounds what each one allows.
- **Errors.** It fails open on any resolution error.

## Background

Before this version, two weeks of use logged 106 decisions: 26 `delegate`, 39 `trivial`, 32 `security`, 3 `lane`, and 6 from an older rule that let coupling count as an exemption.

One long session showed what the old rules missed:
- It recorded `security` for four worktrees within seconds and then wrote their docs, tests and templates directly.
- It recorded `delegate`, then made dozens of authoring edits itself.

Named files for `security`, the spawn requirement and the integration budget come from that session.

## License

MIT, see [LICENSE](LICENSE).
