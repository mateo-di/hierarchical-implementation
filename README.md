# hierarchical-implementation

A Claude Code plugin that makes worker subagents the default for implementation. The main session acts as a driver. It plans, briefs one named worker per unit, reviews each result critically, sends corrections to the same worker, and integrates. A hook holds the driver to that: it must decide before its first edit or first worker, and each decision only allows what it claims.

## Install

```bash
claude plugin marketplace add mateo-di/hierarchical-implementation
claude plugin install hierarchical-implementation@hierarchical-implementation
```

Then merge [examples/CLAUDE.md](examples/CLAUDE.md) into `~/.claude/CLAUDE.md`. It holds the policy row the skill and the hook refer to, including the standing authorization for editing workers. Hooks load when a session starts, so restart open sessions.

Requirements: Claude Code with the Agent and SendMessage tools, `bash` 3.2 or newer, `git`, `jq`.

### Run every subagent on one model (recommended)

The plugin's workers are meant to run a cheaper model than the driver. The skill suggests Sonnet workers under an Opus driver.

`CLAUDE_CODE_SUBAGENT_MODEL` alone is only a default: an Agent call's `model` parameter, an agent definition's `model` field, and the built-in Explore and Plan agents win over it.

`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` (Claude Code v2.1.257 or later) makes it binding for every subagent, teammate and workflow agent. The Agent tool then takes no `model`; forks and skills with `model: inherit` keep the session's model. See the [Claude Code docs](https://code.claude.com/docs/en/sub-agents.md#run-every-subagent-on-one-model).

A plugin cannot set these for you, so run `/hierarchical-implementation:setup`, optionally with a model, for example `/hierarchical-implementation:setup claude-sonnet-5-5`. It shows the current values, proposes `sonnet`, shows the change and writes the two keys to your user settings only after you say yes.

Or add them yourself to the `env` block of `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet",
    "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"
  }
}
```

To give one session's subagents another model, start it with `claude --settings '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL_FORCE":"0"}}'`.

The keys apply to sessions started after the change.

### Upgrading from a manual install

Earlier versions were copied into `~/.claude` by hand. Remove those copies, or two gates with different rules will run side by side:

- `~/.claude/skills/hierarchical-implementation/`
- `~/.claude/hooks/hierarchical-implementation-gate.sh` and its `.test.sh`
- In `~/.claude/settings.json`: the PreToolUse entry that runs that hook, and the `hierarchical-implementation-gate.sh decide` allow rules. The plugin's hook approves its own `decide` command, so it doesn't need them.

Existing decisions and logs under `~/.local/state/claude-gates/` keep working.

## How it works

There are three layers.

1. **Policy** ([examples/CLAUDE.md](examples/CLAUDE.md)). Delegation is the default for anything beyond a small edit, and Claude does not ask before spawning editing workers.
2. **Procedure** ([skills/hierarchical-implementation/SKILL.md](skills/hierarchical-implementation/SKILL.md)). The skill covers:
   - splitting work into units, one todo per unit (a coupled change is one unit);
   - what goes into a brief;
   - isolating workers in their own worktrees and branches;
   - critical review: accept, correct or redo;
   - corrections through `SendMessage`, at most three rounds per unit;
   - best of N for a unit a test decides after three failed rounds, and a council of models for a costly design choice no test decides;
   - integration.

   Workers run as [agents/worker.md](agents/worker.md) (`hierarchical-implementation:worker`): file and shell tools only, its own rules and a short report format. A general-purpose agent loads every tool schema, skill listing and MCP server instruction; in the author's setup it started at 89,285 tokens against 29,727 for a tool-restricted agent, and a worker carries that context on every call.
3. **Enforcement** ([hooks/hierarchical-implementation-gate.sh](hooks/hierarchical-implementation-gate.sh), registered by [hooks/hooks.json](hooks/hooks.json)).

### The hook

- **The first edit.** In a worktree under `HIERARCHICAL_GATE_ROOT`, the main thread's first edit is denied until the session records a decision. The deny reason works as a just-in-time prompt: Claude reads it at the moment it wants to edit. It carries the ready-to-run `decide` commands, the exemption list and the review loop. Subagents are never gated.
- **The first worker.** While the session works in such a worktree, its first worker (the plugin's worker agent, or a `free-models.sh run`) is denied the same way, because a driver that only reviews may never edit and would leave no decision behind. Any decision of the session lets workers start, since they may edit another worktree. General-purpose agents and forks are not asked: sessions also spawn them to research and review.
- **Recording a decision.** The hook approves its own `decide` command, but only in its exact form with inert arguments, so recording costs no permission prompt. Each decision is appended to a log.
- **Each decision is held to its scope:**
  - `delegate`: the driver's edits are denied until it has spawned a named worker since it recorded `delegate`. A worker is an agent of one of `WORKER_TYPES` (general-purpose, the plugin's worker, a fork, a `free-models.sh run`), or a named agent with no type; read-only and bookkeeping agents don't count. After that, the driver's own edits count against an integration budget of changed lines per worktree. Past the budget, the edit is authoring and should go to a worker.
  - `trivial`: up to 3 files and a cap of changed lines in all. The cap sums the lines the driver's edits change (context an edit repeats unchanged does not count), so neither a commit nor recording `trivial` again resets it.
  - `security`: only the files named when it was recorded, each of which must match `SECURITY_PATHS`; `decide` refuses other files, and each edit is checked again, since `decide` runs in an environment the model sets. "Security" means the agent's own controls (hooks, gates, agent settings and permissions, `CLAUDE.md`, `AGENTS.md`, skill and agent definitions, also as chezmoi sources) or data and config files that hold secrets, not the code that handles them. A plugin's `hooks/`, `skills/`, `agents/` and `commands/` count too, where a tracked `.claude-plugin/plugin.json` marks the plugin. Repo ownership, CI and IAM files go to workers.
  - `lane`: the whole worktree, only in a session started with `LANE_MODE=unit`, which a lane spawner such as `herdr-spawn --lane unit` exports. The session records `lane` itself: the variable outlives the lane in its pane's shell, so the gate does not exempt a later session there without a decision.
  - `opt-out`, `no-subagents`: the whole worktree.
- **Shell writes.** In `Bash` and `Monitor` commands, a quote-aware tokenizer finds files written through redirects (`>`, `>>`, `>|`, `&>`, `>&`), `tee`, `sed -i` and `perl -i`. Those files go through the same rules as edits. A heredoc body counts toward the size of the file it writes.
- **Named worker calls** (`Agent` with `name`) must set `model`. This applies only in sessions that have touched the gate root. With `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` on, the Agent tool takes no model, so the check is skipped. See [Run every subagent on one model](#run-every-subagent-on-one-model-recommended).
- **Free model first.** With `HI_FREE_WORKERS=1` and opencode installed, the plugin's worker on sonnet is denied until the session logged a `free-models.sh run` under its name, or under its name's prefix before a dash (a redo or a best-of-N attempt). Driver lanes and workers on another model are not asked. At session start the hook adds a note that free-model workers are on, since a session cannot see the variable otherwise.
- **Logging.** Worker spawns, `SendMessage` calls, `free-models.sh run` commands and denials are logged.

```bash
hierarchical-implementation-gate.sh decide <worktree> <session> delegate "<units>"
hierarchical-implementation-gate.sh decide <worktree> <session> direct "<exemption>: <why>"
hierarchical-implementation-gate.sh decide <worktree> <session> direct "security: <why>" <file>...
hierarchical-implementation-gate.sh report
```

The script lives in the plugin's `hooks/` directory under `~/.claude/plugins/cache/`. Recording a decision again resets which files `trivial` covers and adds files to `security`. It keeps both line counts and the time `delegate` was first recorded, so recording again refills nothing.

`report` prints each session's decisions with its worker, message and denial counts; only messages to the session's own workers, by name, count. A session that was denied but never decided shows as `undecided`. `delegate` sessions with workers but no messages suggest reviews that never sent a correction.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `HIERARCHICAL_GATE_ROOT` | `~/vscode` | Only paths under this directory are gated |
| `HIERARCHICAL_GATE` | `on` | `off` disables the hook |
| `TRIVIAL_MAX_LINES` | `60` | Changed-line cap for a trivial exemption, per worktree and session |
| `TRIVIAL_MAX_FILES` | `3` | Files a trivial exemption covers |
| `INTEGRATE_MAX_LINES` | `60` | Driver's changed-line budget per worktree under delegate |
| `SECURITY_PATHS` | agent-control and secrets paths | Extended regex a security file's path, relative to the worktree, must match |
| `WORKER_TYPES` | `general-purpose\|worker\|hierarchical-implementation:worker\|fork\|free-models` | Agent types that count as a worker under delegate; `free-models` is the type logged for a `free-models.sh run`, so keep it in an override |
| `XDG_STATE_HOME` | `~/.local/state` | Per-session state lives under `$XDG_STATE_HOME/claude-gates/delegation/` |
| `DELEGATION_LOG` | `…/claude-gates/delegation-decisions.tsv` | Decisions: time, session, worktree, choice, reason, named files |
| `DELEGATION_EVENTS` | `…/claude-gates/delegation-events.tsv` | Spawns, messages and denials: time, session, kind, target (the tool for a denial), model (the one the spawn resolved to, when Claude Code reports it), agent type (for a denial, its kind: `undecided`, `no-worker`, `budget`, `trivial-files`, `trivial-lines`, `security`, `lane`, `model`, `too-many-files` or `newline`) |

Set these in the environment Claude Code starts with.

### Free-model workers (optional)

With `HI_FREE_WORKERS=1` and [opencode](https://opencode.ai) installed, the skill tries each editing unit on a free model first, through `skills/hierarchical-implementation/scripts/free-models.sh`. That script runs a headless `opencode run` in the worktree and records which free models work. A model that fails, or prints nothing for a while (opencode retries rate limits silently), cools down and is retried later. When no free model finishes, the script exits 3 and the driver uses a normal Agent worker. A model the user names runs through `--model`: once, with no cooldown and no fallback, and exit 1 when it cannot run or finish. The hook logs each run as a worker spawn, so it satisfies `delegate`.

The run approves every permission its opencode agent leaves at "ask", so it needs a restricted agent. Install the example, which denies everything except file tools inside the worktree, git read commands and common test runners:

```bash
cp examples/opencode-lane-worker.md ~/.config/opencode/agents/lane-worker.md
```

Without it the script runs no model and the driver falls back. The agent narrows what the model can call. It is not a sandbox: a test runner executes the repo's code.

With the Antigravity CLI installed, a model id `agy/<id>`, with `<id>` from `agy models`, runs through a headless `agy -p` instead, on your agy quota rather than a free tier. The rotation tries one only when `HI_FREE_MODELS_PREFER` names it, and `--model agy/<id>` runs one directly. agy runs with your own agy permission settings, not a restricted agent: in Auto mode, its default for headless runs, it approves the commands it judges safe, so the brief's limits are instructions there.

| Variable | Default | Effect |
|---|---|---|
| `HI_FREE_WORKERS` | unset | `1` turns free-model workers on |
| `HI_FREE_MODELS_PREFER` | empty | Space-separated model ids to try first; the only way an `agy/<id>` model joins the rotation |
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
- **Which worktree a worker serves.** Any worker spawned in the session after the decision satisfies `delegate`, including one spawned for another worktree. A `free-models.sh run` counts once it starts, even if it then exits 3. A spawned worker can also edit outside the files it owns; the skill has the driver check `git diff --name-only`.
- **Other shell writes.** The hook doesn't recognize:
  - `cp`, `mv`, `patch`, `git apply` or scripts;
  - writes inside `$(...)`;
  - targets built from variables other than `$HOME`;
  - the PowerShell tool.

  Writes other than heredocs have no known size, so they don't count against the budget. The trivial cap also reads git's diff of its files, so it sees them until they are committed. A command that writes more than 20 files is denied.
- **Lines that never landed.** The hook counts an edit before it runs, so an edit that fails, that the user rejects, or a command denied at a later target still counts against the caps.
- **Workers the hook does not count.** A driver that never edits itself records no decision, so `report` does not list it, when it delegates through general-purpose workers instead of the plugin's agent, works from a directory outside `HIERARCHICAL_GATE_ROOT`, or runs `free-models.sh` in a form the hook does not recognize.
- **Free-first by model and name.** A worker on a model other than sonnet passes the free-first check, since the user may have named that model, and a name with the prefix of an earlier free run passes too. Any logged `free-models.sh run` call counts, even one that failed or never ran a model.
- **Inherited lane mode.** `LANE_MODE=unit` stays in the lane pane's shell after the lane ends, so a later session there may still record `lane`. Each recording is logged.
- **Repeated decisions.** Recording `trivial` again frees its files for a new task, and the log shows every repeat. Line counts carry over.
- **Classification.** Claude still picks the exemption itself. The hook only bounds what each one allows, and `opt-out` is taken on trust.
- **Errors and timeouts.** The hook fails open on any resolution error. If it takes longer than its timeout, Claude Code lets the call through. Commands of about 20 KB take around half a second.

## Background

The first published version only checked that a decision was recorded. The author's log at that point held 106 decisions: 26 `delegate`, 39 `trivial`, 32 `security`, 3 `lane`, and 6 recorded under older exemption names. A few of the rows are the same conversation recorded twice under two session ids.

One long session showed two gaps:
- It recorded `security` for three worktrees within 3 seconds, then wrote their IAM, CI workflow and docs changes itself.
- It made 22 edits to one spec file under a single `trivial` decision.

Named files for `security` and the line cap for `trivial` come from that session. The spawn requirement and the integration budget close the gap where `delegate` was taken on trust. The log has no case of `delegate` being abused.

A later review covered 248 decisions and the token usage in their sessions' transcripts. It found:
- `security` was the most used decision (71). Before it named files, most lines edited under it were outside agent-control paths: chart templates, CI scripts. With named files about a tenth still were, half of them a settings template that the path list now covers. `decide` and each edit now check the paths.
- Changes of 40 lines or fewer cost a median of about 3 to 4 times as many tokens delegated as done directly, partly because a 1-file, 20-line `trivial` cap pushed code plus its test into delegation. The sample is small (11 delegated changes of that size). The cap is now 3 files and 60 lines.
- Two holes were open in the code with no case in the log: a commit reset the `trivial` cap, and a named agent of any type spawned before the decision satisfied `delegate`. Both are closed.
- Drivers reread diffs and reran checks their workers had already run. The skill now has the worker report a diffstat and pass/fail, and the driver run the checks once.

## Notes

- The skill and the deny text mention a `/repro` gate. That separate hook blocks source edits until a bug is reproduced, and it is not part of this plugin. The references are harmless without it.
- The skill uses Claude Sonnet for editing workers unless the user names another model.

## License

MIT, see [LICENSE](LICENSE).
