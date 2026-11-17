# hierarchical-implementation

A Claude Code plugin that makes worker subagents the default for implementation. The main session acts as a driver. It plans, briefs one named worker per unit, reviews each result critically, sends corrections to the same worker, and integrates. A hook holds the driver to that: it must decide before its first edit, and each decision only allows what it claims.

## Install

```bash
claude plugin marketplace add mateo-di/hierarchical-implementation
claude plugin install hierarchical-implementation@hierarchical-implementation
```

Then merge [examples/CLAUDE.md](examples/CLAUDE.md) into `~/.claude/CLAUDE.md`. It holds the policy row the skill and the hook refer to, including the standing authorization for editing workers. Hooks load when a session starts, so restart open sessions.

Requirements: Claude Code with the Agent and SendMessage tools, `bash` 3.2 or newer, `git`, `jq`.

### Upgrading from a manual install

Earlier versions were copied into `~/.claude` by hand. Remove those copies, or two gates with different rules will run side by side:

- `~/.claude/skills/hierarchical-implementation/`
- `~/.claude/hooks/hierarchical-implementation-gate.sh` and its `.test.sh`
- In `~/.claude/settings.json`: the PreToolUse entry that runs that hook, and the `hierarchical-implementation-gate.sh decide` allow rules. The plugin's hook approves its own `decide` command, so it doesn't need them.

Existing decisions and logs under `~/.local/state/claude-gates/` keep working.

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
  - `delegate`: the driver's edits are denied until it has spawned a named worker that can edit. Read-only `Explore` and `Plan` agents don't count. After that, the driver's own edits count against an integration budget of changed lines per worktree. Past the budget, the edit is authoring and should go to a worker.
  - `trivial`: one file, up to a cap of changed lines.
  - `security`: only the files named when it was recorded. "Security" means the agent's own controls (hooks, gates, agent settings and permissions, `CLAUDE.md`, `AGENTS.md`, skill and agent definitions) or secret values. Repo ownership, CI and IAM files go to workers.
  - `lane`, `opt-out`, `no-subagents`: the whole worktree.
- **Shell writes.** In `Bash` and `Monitor` commands, a quote-aware tokenizer finds files written through redirects (`>`, `>>`, `>|`, `&>`, `>&`), `tee`, `sed -i` and `perl -i`. Those files go through the same rules as edits. A heredoc body counts toward the size of the file it writes.
- **Named worker calls** (`Agent` with `name`) must set `model`. This applies only in sessions that have touched the gate root.
- **Logging.** Worker spawns, `SendMessage` calls and `free-models.sh run` commands are logged.

```bash
hierarchical-implementation-gate.sh decide <worktree> <session> delegate "<units>"
hierarchical-implementation-gate.sh decide <worktree> <session> direct "<exemption>: <why>"
hierarchical-implementation-gate.sh decide <worktree> <session> direct "security: <why>" <file>...
hierarchical-implementation-gate.sh report
```

The script lives in the plugin's `hooks/` directory under `~/.claude/plugins/cache/`. Recording a decision again resets which file `trivial` covers and adds files to `security`. It keeps the `delegate` budget, so recording `delegate` again does not refill it.

`report` prints each session's decisions with its spawn and message counts. `delegate` sessions with spawns but no messages suggest reviews that never sent a correction.

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

### Free-model workers (optional)

With `HI_FREE_WORKERS=1` and [opencode](https://opencode.ai) installed, the skill tries each editing unit on a free model first, through `skills/hierarchical-implementation/scripts/free-models.sh`. That script runs a headless `opencode run` in the worktree and records which free models work. A model that fails, or prints nothing for a while (opencode retries rate limits silently), cools down and is retried later. When no free model finishes, the script exits 3 and the driver uses a normal Agent worker. The hook logs each run as a worker spawn, so it satisfies `delegate`.

The run approves every permission its opencode agent leaves at "ask", so it needs a restricted agent. Install the example, which denies everything except file tools inside the worktree, git read commands and common test runners:

```bash
cp examples/opencode-lane-worker.md ~/.config/opencode/agents/lane-worker.md
```

Without it the script exits 3 and the driver falls back. The agent narrows what the model can call. It is not a sandbox: a test runner executes the repo's code.

| Variable | Default | Effect |
|---|---|---|
| `HI_FREE_WORKERS` | unset | `1` turns free-model workers on |
| `HI_FREE_MODELS_PREFER` | empty | Space-separated model ids to try first |
| `HI_FREE_AGENT` | `lane-worker` | opencode agent the worker runs as |
| `HI_FREE_COOLDOWN` | `3600` | Seconds a failed model is skipped |
| `HI_FREE_MAX_TRIES` | `3` | Models tried per unit before falling back |
| `HI_FREE_TIMEOUT` | `1800` | Seconds one attempt may take |
| `HI_FREE_STALL` | `300` | Seconds one attempt may print nothing before it counts as failed |
| `HI_FREE_REGISTRY` | `…/hierarchical-implementation/free-models.json` | Registry under `$XDG_STATE_HOME` |

Free models come and go, and some providers keep or train on prompts. Check each provider's terms before sending it code.

## Tests

```bash
bash hooks/hierarchical-implementation-gate.test.sh
bash skills/hierarchical-implementation/scripts/free-models.test.sh
```

## What it does not enforce

The gate is a speed bump, not a barrier. It makes skipping delegation a deliberate, logged act. A model set on getting around it can still write files in ways the hook doesn't see.

- **Whether a review was critical.** The log shows that messages were sent, not whether they were right.
- **Which worktree a worker serves.** Any named editing worker spawned in the session satisfies `delegate`, including one spawned for another worktree. A `free-models.sh run` counts once it starts, even if it then exits 3. A spawned worker can also edit outside the files it owns; the skill has the driver check `git diff --name-only`.
- **Other shell writes.** The hook doesn't recognize:
  - `cp`, `mv`, `patch`, `git apply` or scripts;
  - writes inside `$(...)`;
  - targets built from variables other than `$HOME`;
  - the PowerShell tool.

  Writes other than heredocs have no known size, so they don't count against the budget or the trivial cap. A command that writes more than 20 files is denied.
- **Repeated decisions and commits.** Recording `trivial` again frees its file for a new task, and the log shows every repeat. The trivial cap measures the file against `HEAD`, so a commit resets it.
- **Classification.** Claude still picks the exemption itself. The hook only bounds what each one allows.
- **Errors and timeouts.** The hook fails open on any resolution error. If it takes longer than its timeout, Claude Code lets the call through. Commands of about 20 KB take around half a second.

## Background

The first published version only checked that a decision was recorded. The author's log at that point held 106 decisions: 26 `delegate`, 39 `trivial`, 32 `security`, 3 `lane`, and 6 recorded under older exemption names. A few of the rows are the same conversation recorded twice under two session ids.

One long session showed two gaps:
- It recorded `security` for three worktrees within 3 seconds, then wrote their IAM, CI workflow and docs changes itself.
- It made 22 edits to one spec file under a single `trivial` decision.

Named files for `security` and the line cap for `trivial` come from that session. The spawn requirement and the integration budget close the gap where `delegate` was taken on trust. The log has no case of `delegate` being abused.

## Notes

- The skill and the deny text mention a `/repro` gate. That separate hook blocks source edits until a bug is reproduced, and it is not part of this plugin. The references are harmless without it.
- The skill suggests Claude Opus for the driver and Claude Sonnet for editing workers. It asks before switching the main session's model.

## License

MIT, see [LICENSE](LICENSE).
