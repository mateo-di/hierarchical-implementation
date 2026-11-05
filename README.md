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
- **Logging.** Worker spawns and `SendMessage` calls are logged.

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

## Tests

```bash
bash hooks/hierarchical-implementation-gate.test.sh
```

## What it does not enforce

- **Whether a review was critical.** The log shows that messages were sent, not whether they were right.
- **Which worktree a worker serves.** Any named editing worker spawned in the session satisfies `delegate`, including one spawned for another worktree. A spawned worker can also edit outside the files it owns; the skill has the driver check `git diff --name-only`.
- **Other shell writes.** `cp`, `mv`, `patch`, `git apply`, scripts, writes inside `$(...)`, and targets built from variables other than `$HOME` are not recognized. Writes other than heredocs have no known size, so they don't count against the budget or the trivial cap. A command that writes more than 20 files is denied.
- **Repeated decisions.** Recording `trivial` again frees its file for a new task. The log shows every repeat.
- **Classification.** Claude still picks the exemption itself. The hook only bounds what each one allows.
- **Errors and timeouts.** The hook fails open on any resolution error. If it takes longer than its timeout, Claude Code lets the call through. Commands of about 20 KB take around half a second.

## Background

The first published version only checked that a decision was recorded. The author's log at that point held 106 decisions: 26 `delegate`, 39 `trivial`, 32 `security`, 3 `lane`, and 6 recorded under older exemption names. A few of the rows are the same conversation recorded twice under two session ids.

One long session showed two gaps:
- It recorded `security` for three worktrees within 3 seconds, then wrote their IAM, CI workflow and docs changes itself.
- It made 22 edits to one spec file under a single `trivial` decision.

Named files for `security` and the line cap for `trivial` come from that session. The spawn requirement and the integration budget close the gap where `delegate` was taken on trust. The log has no case of `delegate` being abused.

## License

MIT, see [LICENSE](LICENSE).
