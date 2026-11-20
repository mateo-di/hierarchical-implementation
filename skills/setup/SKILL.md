---
name: setup
description: Run every Claude Code subagent on one model, Sonnet by default, by adding two keys to your user settings.
disable-model-invocation: true
argument-hint: "[model]"
---

# Set up the subagent model

The plugin's workers are meant to run a cheaper model than the driver. `CLAUDE_CODE_SUBAGENT_MODEL` alone is only a default: an Agent call's `model` parameter, an agent definition's `model` field, and the built-in Explore and Plan agents all win over it. `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` makes it binding for every subagent, teammate and workflow agent. The Agent tool then takes no `model`, and forks and skills with `model: inherit` keep the session's model. The plugin's gate works in both modes.

The settings file is `$CLAUDE_CONFIG_DIR/settings.json` when that variable is set, otherwise `~/.claude/settings.json`. Its `env` block often holds tokens, so read and write it with `jq`, touching only the two keys, and keep the rest of the file out of the transcript.

1. **Read.** Show the two keys' current values, or that they are unset:
   ```bash
   jq '.env // {} | {CLAUDE_CODE_SUBAGENT_MODEL, CLAUDE_CODE_SUBAGENT_MODEL_FORCE}' <settings file>
   ```
   Done when the user has seen both values.
2. **Choose.** The model is `$ARGUMENTS` when given; otherwise ask the user, proposing `sonnet`. An alias follows the provider's current model; a full id such as `claude-sonnet-5-5` pins one. When both keys already hold the chosen model and `"1"`, say so and stop. Done when the model is settled.
3. **Confirm.** Show the two entries that will be written and ask for a yes:
   ```json
   "CLAUDE_CODE_SUBAGENT_MODEL": "<model>",
   "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"
   ```
   Done when the user says yes. Any other answer ends the skill with nothing written.
4. **Write.** Start from `{}` when the file is missing. Set the two keys with `jq --arg m <model> '.env.CLAUDE_CODE_SUBAGENT_MODEL = $m | .env.CLAUDE_CODE_SUBAGENT_MODEL_FORCE = "1"'` into a temporary file, then copy it back over the settings file's contents (`cat <tmp> > <settings file>`), so a symlinked settings file stays linked. Done when step 1's command shows both new values.
5. **Report.** Tell the user:
   - the keys apply to sessions started from now on;
   - to give one session's subagents another model, start it with `claude --settings '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL_FORCE":"0"}}'` and name the model on the Agent call;
   - project or managed settings that set either key take precedence over these;
   - to undo, remove the two keys.
