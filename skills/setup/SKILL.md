---
name: setup
description: Run every Claude Code subagent on one model, Sonnet by default, by adding two keys to your user settings.
disable-model-invocation: true
argument-hint: "[model]"
---

# Set up the subagent model

The plugin's workers are meant to run a cheaper model than the driver. `CLAUDE_CODE_SUBAGENT_MODEL` alone is only a default: an Agent call's `model` parameter, an agent definition's `model` field, and the built-in Explore and Plan agents all win over it. `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` (Claude Code v2.1.257 or later) makes it binding for every subagent, teammate and workflow agent. The Agent tool then takes no `model`, and forks and skills with `model: inherit` keep the session's model. The plugin's gate works in both modes.

The settings file is `$CLAUDE_CONFIG_DIR/settings.json` when that variable is set, otherwise `~/.claude/settings.json`. Its `env` block often holds tokens, so read and write it only with the commands below: they touch the two keys and keep the rest of the file out of the transcript.

1. **Read.** Show the file's path and the two keys' current values:
   ```bash
   f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; echo "$f"
   [ ! -s "$f" ] || jq '.env // {} | {CLAUDE_CODE_SUBAGENT_MODEL, CLAUDE_CODE_SUBAGENT_MODEL_FORCE}' "$f"
   ```
   A path with nothing after it means the file is missing or empty and both keys are unset. When `jq` reports an error, the file is not valid JSON or its `env` is not an object: tell the user and stop. Done when the user has seen the path and both values.
2. **Choose.** The model is `$ARGUMENTS` when given; otherwise ask the user, proposing `sonnet`. An alias follows the provider's current model; a full id such as `claude-sonnet-5-5` pins one. The model must match `^[A-Za-z0-9._:-]+(\[[A-Za-z0-9]+\])?$`, such as `sonnet`, `claude-sonnet-5-5` or `opus[1m]`; ask again for anything else. When both keys already hold the chosen model and `"1"`, say so and stop. Done when the model is settled.
3. **Confirm.** Show the path and the two entries that will be written, and ask for a yes:
   ```json
   "CLAUDE_CODE_SUBAGENT_MODEL": "<model>",
   "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"
   ```
   Done when the user says yes. Any other answer ends the skill with nothing written.
4. **Write.** Run this with the model from step 2 in place of `<model>`:
   ```bash
   m='<model>' f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
   [ -s "$f" ] || (umask 077 && mkdir -p "$(dirname "$f")" && echo '{}' > "$f")
   t=$(mktemp) && jq --arg m "$m" '.env.CLAUDE_CODE_SUBAGENT_MODEL = $m | .env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE = "1"' "$f" > "$t" && [ -s "$t" ] && cat "$t" > "$f"; rm -f "$t"
   ```
   Run the block as one command: its `&&` chain is what keeps a failed `jq` from reaching the file. When your rules make you split it, run the `cat` only after `jq` exited 0 and the temp file is non-empty, and remove the temp file either way. The copy goes back only when `jq` succeeded, `mktemp` makes it readable only by the user, and `cat` writes over the settings file's contents, so a symlinked file stays linked. Done when step 1's commands show both new values.
5. **Report.** Tell the user:
   - the keys apply to sessions started from now on;
   - to give one session's subagents another model, start it with `claude --settings '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL_FORCE":"0"}}'` and name the model on the Agent call;
   - project or managed settings that set either key take precedence over these;
   - to undo, remove the two keys.
