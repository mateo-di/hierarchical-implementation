# hierarchical-implementation

A Claude Code skill and PreToolUse hook that make worker subagents the default for implementation. The main session acts as a driver. It plans, briefs one named worker per unit, reviews each result, sends corrections to the same worker, and integrates. The hook stops the main session's first edit in a repo until it records whether it will delegate or which exemption lets it work directly.

## How it works

Three layers work together, and only the first edit is enforced by code.

1. **Policy** ([examples/CLAUDE.md](examples/CLAUDE.md)). A `CLAUDE.md` row makes delegation the default for anything beyond a trivial edit and gives standing authorization for editing workers, so Claude does not stop to ask before spawning one. It also lists the exemptions.
2. **Procedure** ([skills/hierarchical-implementation/SKILL.md](skills/hierarchical-implementation/SKILL.md)). The skill covers how to split work into units (one coupled change is one unit), what goes into a brief, how to isolate workers in their own worktrees and branches, how to review, the correction loop through `SendMessage` (at most three rounds per unit), and integration.
3. **Forcing function** ([hooks/hierarchical-implementation-gate.sh](hooks/hierarchical-implementation-gate.sh)). A PreToolUse hook on `Edit|Write|MultiEdit|NotebookEdit`.

### The hook

1. Subagent edits pass. Their hook input carries `agent_id`.
2. Paths outside `HIERARCHICAL_GATE_ROOT` (default `~/vscode`) pass. So do worktree paths outside a plain character set, because the deny text embeds the path in a command.
3. The hook looks for a decision keyed by the session id and a hash of the worktree's git dir. If there is none, it denies the edit.
4. The deny reason is the main trick. Claude reads it at the exact moment it wants to edit, so it works as a just-in-time prompt instead of a rule buried far back in context. It carries the ready-to-run `decide` commands for both paths, the instruction to load the skill, a summary of the review loop, and the exemption list.
5. Claude records a decision with the `decide` command. Allowlisting that command in `settings.json` means recording costs no permission prompt, but Claude still has to write a reason of at least three words. Each decision is appended to a TSV log for later review.
6. After a decision:
   - `delegate` and every exemption except `trivial` lift the gate for that session and worktree. The driver still edits to integrate.
   - `trivial` allows exactly one file. A second file is denied with "the task is not trivial".

```bash
hierarchical-implementation-gate.sh decide <worktree> <session> delegate "<units, three or more words>"
hierarchical-implementation-gate.sh decide <worktree> <session> direct "<exemption>: <why, three or more words>"
```

Exemptions: `trivial` (one file, a few lines), `security` (security, credential, permission, hook, gate, settings or `CLAUDE.md` changes, never delegated), `lane` (a coordinator session spawned this one to execute a unit it reviews), `opt-out` (the user or the repo's rules say not to delegate), `no-subagents` (the harness has no subagent tool). Coupling is not an exemption.

## Requirements

- Claude Code with the Agent and SendMessage tools
- `bash`, `git`, `jq`

## Install

```bash
git clone https://github.com/mateo-di/hierarchical-implementation
cp -r hierarchical-implementation/skills/hierarchical-implementation ~/.claude/skills/
cp hierarchical-implementation/hooks/hierarchical-implementation-gate.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/hierarchical-implementation-gate.sh
```

Then:

1. Merge [examples/settings.json](examples/settings.json) into `~/.claude/settings.json`. Replace `/home/you` in the allowlist with your home directory. The deny text prints the hook's absolute path, so the absolute form is the one that matches.
2. Merge [examples/CLAUDE.md](examples/CLAUDE.md) into `~/.claude/CLAUDE.md`.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `HIERARCHICAL_GATE_ROOT` | `~/vscode` | Only paths under this directory are gated |
| `HIERARCHICAL_GATE` | `on` | `off` disables the hook |
| `XDG_STATE_HOME` | `~/.local/state` | Decisions live under `$XDG_STATE_HOME/claude-gates/delegation/` |
| `DELEGATION_LOG` | `$XDG_STATE_HOME/claude-gates/delegation-decisions.tsv` | Append-only log: time, session, worktree, choice, reason |

To change the root, set it in the hook command, for example `HIERARCHICAL_GATE_ROOT="$HOME/src" "$s"`.

## Tests

```bash
bash hooks/hierarchical-implementation-gate.test.sh
```

The suite builds a throwaway repo and linked worktree, feeds the hook synthetic payloads and drives the `decide` CLI (31 cases).

## What it does not enforce

- **`delegate` is on the honor system.** It unlocks every edit in the worktree for the driver, and nothing checks that a worker was ever spawned.
- **Shell edits bypass the gate entirely.** That includes `sed`, heredocs and `tee`. The "do not edit through the shell" line in the deny text is only text.
- **`security` has no limit and Claude classifies it itself.** It covers any number of files.
- **`trivial` is only half checked.** The one-file limit is enforced, but "a few lines" is not.
- **Everything after the first edit is prose.** That covers the review loop, the corrections, the three-round cap and the model choice.
- **It fails open** on any resolution error, including a state dir it cannot write.

So the gate guarantees Claude makes a deliberate, logged decision before its first edit, with the default tilted toward delegating. It does not guarantee the decision is correct or that workers actually run. The decision log is there so you can check.

## Observed usage

Over two weeks of daily use the log recorded 106 decisions:
- `delegate`: 26 (25%)
- `trivial`: 39
- `security`: 32
- `lane`: 3
- older "coupled unit" exemptions: 6, all from before coupling stopped counting as an exemption

`security` was mostly ownership files such as `CODEOWNERS`, CI permissions and IAM changes, plus some merge-conflict resolutions in those files.

## Notes

- The skill also mentions a `/repro` gate and its `repro-gate.sh` hook. That gate blocks source edits until a bug is reproduced, and it is not part of this repo. The references are harmless without it.
- The skill suggests Claude Opus for the driver and Claude Sonnet for editing workers. It asks before switching the main session's model.

## License

MIT, see [LICENSE](LICENSE).
