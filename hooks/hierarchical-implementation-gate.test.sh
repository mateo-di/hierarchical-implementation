#!/usr/bin/env bash
# Regression suite for hierarchical-implementation-gate.sh: builds a throwaway root with a repo
# and a linked worktree, feeds the hook synthetic tool payloads, and drives the decide and report CLI.
#   bash hooks/hierarchical-implementation-gate.test.sh
set -u

HOOK="${HOOK:-$(dirname "$0")/hierarchical-implementation-gate.sh}"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

T=$(cd "$(mktemp -d)" && pwd -P)
export XDG_STATE_HOME="$T/state" HIERARCHICAL_GATE_ROOT="$T/vscode" DELEGATION_LOG="$T/decisions.tsv" DELEGATION_EVENTS="$T/events.tsv"
unset LANE_MODE HI_FREE_WORKERS OPENCODE_BIN
trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
W="$T/vscode/repo"
git init -q -b main "$W"
mkdir -p "$W/src" "$T/other"
printf 'one\ntwo\n' >"$W/src/c.ts"
seq 40 | sed 's/.*/x/' >"$W/src/r.ts"
git -C "$W" add src/c.ts src/r.ts
git -C "$W" -c user.email=t@t -c user.name=t commit -q -m init
git init -q -b main "$T/other"

lines() { seq "$1" | sed 's/^/line /'; }
state() { # state <session> -> the state file prefix the hook uses for $W
  printf '%s/claude-gates/delegation/%s/%s' "$XDG_STATE_HOME" "$1" "$(printf '%s' "$(git -C "$W" rev-parse --absolute-git-dir)" | git hash-object --stdin)"
}
run() { bash "$HOOK" <<<"$1"; }
edit() { # edit <file_path> [session] [extra json] -> Edit payload
  local x=${3:-}
  [[ -n $x ]] || x='{}'
  jq -cn --arg p "$1" --arg s "${2:-s1}" --arg c "$W" --argjson x "$x" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",session_id:$s,cwd:$c,tool_input:{file_path:$p}} + $x'
}
tool() { # tool <event> <tool> <session> <tool_input json> [cwd] -> payload
  jq -cn --arg e "$1" --arg t "$2" --arg s "$3" --arg c "${5:-$W}" --argjson i "$4" \
    '{hook_event_name:$e,tool_name:$t,session_id:$s,cwd:$c,tool_input:$i}'
}
shell() { # shell <session> <command> [cwd] -> Bash payload
  tool PreToolUse Bash "$1" "$(jq -cn --arg c "$2" '{command:$c}')" "${3:-$W}"
}
verdict() { # deny and approve are the hook's explicit answers; none means no opinion, the normal permission flow
  case $1 in
    '') echo none ;;
    *'"permissionDecision":"deny"'*) echo deny ;;
    *'"permissionDecision":"allow"'*) echo approve ;;
    *) echo "malformed:$1" ;;
  esac
}
check() { # check <none|deny|approve> <label> <payload>
  local got
  got=$(verdict "$(run "$3")")
  [[ $got == "$1" ]] && pass "$2" || fail "$2 (expected $1, got $got)"
}
runs() { # runs <label> <expected-exit> <cmd...>
  local label=$1 want=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  [[ $got == "$want" ]] && pass "$label" || fail "$label (exit $got, wanted $want)"
}
says() { # says <label> <payload> <substring...>
  local label=$1 reason
  reason=$(run "$2" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  shift 2
  for s in "$@"; do [[ $reason == *"$s"* ]] || { fail "$label (missing '$s'): $reason"; return; }; done
  pass "$label"
}

# The first edit
check deny "the main thread's first file is denied" "$(edit "$W/src/a.ts")"
check deny "a relative path is resolved against cwd" "$(edit "src/a.ts")"
check deny "a notebook path is gated too" "$(edit "$W/src/a.ipynb" s1 "{\"tool_input\":{\"notebook_path\":\"$W/src/a.ipynb\"}}")"
check none "subagent edits are not gated" "$(edit "$W/src/a.ts" s1 '{"agent_id":"worker-1"}')"
check none "paths outside the root are not gated" "$(edit "$T/other/a.ts")"
check none "a session id that is not an id fails open" "$(edit "$W/src/a.ts" '../escape')"
ln -s "$W" "$T/link"
check deny "a symlinked path into the root is still gated" "$(edit "$T/link/src/a.ts")"
out=$(HIERARCHICAL_GATE=off bash "$HOOK" <<<"$(edit "$W/src/a.ts")")
[[ -z $out ]] && pass "HIERARCHICAL_GATE=off allows" || fail "HIERARCHICAL_GATE=off still denied"
touch "$T/not-a-dir"
out=$(XDG_STATE_HOME="$T/not-a-dir" bash "$HOOK" <<<"$(edit "$W/src/a.ts")")
[[ -z $out ]] && pass "a state dir that cannot be written fails open" || fail "unwritable state dir still denied"
says "deny reason carries the authorization, the loop, the exemptions and both commands" "$(edit "$W/src/a.ts")" \
  "standing authorization" hierarchical-implementation "decide $W s1 delegate" "decide $W s1 direct" \
  "same worker with SendMessage" "three rounds" "model set" "trivial (" "never delegated" "files you name" \
  "lane (" "opt-out (" "no-subagents (" "/repro"
odd="$T/vscode/x\$(touch $T/pwned)"
git init -q -b main "$odd"
out=$(run "$(edit "$odd/a.ts")")
[[ -z $out && ! -e $T/pwned ]] && pass "a worktree path outside the plain set is never gated" || fail "odd path: $out"

# decide refuses malformed decisions
runs "decide refused for an unknown choice" 1 bash "$HOOK" decide "$W" s1 maybe "one unit only here"
runs "decide refused for delegate units under three words" 1 bash "$HOOK" decide "$W" s1 delegate "one unit"
runs "decide refused for direct without an exemption" 1 bash "$HOOK" decide "$W" s1 direct "one coupled unit here"
runs "decide refused for an unknown exemption" 1 bash "$HOOK" decide "$W" s1 direct "coupled: load and assign share exports"
runs "decide refused for an exemption without three words of why" 1 bash "$HOOK" decide "$W" s1 direct "trivial: typo"
runs "decide refused outside a git repo" 1 bash "$HOOK" decide "$T" s1 direct "trivial: one-line typo fix"
runs "decide refused for a session that is not an id" 1 bash "$HOOK" decide "$W" ../s1 direct "trivial: one-line typo fix"
runs "decide refused for security without files" 1 bash "$HOOK" decide "$W" s1 direct "security: edits the gate itself"
runs "decide refused for files on a non-security decision" 1 bash "$HOOK" decide "$W" s1 direct "trivial: one-line typo fix" src/a.ts
runs "decide refused for a security file outside the worktree" 1 bash "$HOOK" decide "$W" s1 direct "security: edits the gate itself" ../escape.ts
runs "decide refused for a security file outside the control paths" 1 bash "$HOOK" decide "$W" s1 direct "security: edits the gate itself" src/a.ts
runs "decide refused for a CI workflow under security" 1 bash "$HOOK" decide "$W" s1 direct "security: edits the deploy workflow" .github/workflows/ci.yml
runs "decide refused for a top-level hooks dir outside a plugin" 1 bash "$HOOK" decide "$W" s1 direct "security: edits a react hook" hooks/useThing.ts

# security covers only the named files, and only agent-control or secret paths
runs "decide direct security with a reason and a file" 0 bash "$HOOK" decide "$W/src" s1 direct $'security: edits\tthe gate itself' .claude/hooks/gate.sh
check none "security: the named file is allowed" "$(edit "$W/.claude/hooks/gate.sh")"
check deny "security: an unnamed file is denied" "$(edit "$W/CLAUDE.md")"
says "security deny names the scope, how to add a file, and not to re-record delegate" "$(edit "$W/CLAUDE.md")" \
  "not one of them" "decide $W s1 direct" "would drop the security scope"
s="" top="" choice="" why="" named="" extra=""
IFS=$'\t' read -r _ s top choice why named extra <"$DELEGATION_LOG"
[[ $s == s1 && $top == "$W" && $choice == direct && $why == "security: edits the gate itself" && $named == "$W/.claude/hooks/gate.sh" && -z $extra ]] &&
  pass "decision logged with session, worktree, choice, a one-field reason and the named files" || fail "log line: $(cat "$DELEGATION_LOG")"
runs "decide security again adds a file" 0 bash "$HOOK" decide "$W" s1 direct "security: also the agent rules" "$W/CLAUDE.md"
check none "security: the added file is allowed" "$(edit "$W/CLAUDE.md")"
for f in AGENTS.md skills/x/SKILL.md .codex/config.toml dot_claude/settings.json.tmpl private_dot_codex/config.toml \
  dot_config/opencode/lib/gate.ts opencode.json config/.env.local deploy/secrets.yaml certs/server.pem \
  private_dot_config/claude/settings.json exact_dot_claude/agents/x.md .chezmoitemplates/claude-settings.json.tmpl \
  dot_aws/private_credentials config/secrets/prod.yaml; do
  runs "security accepts $f" 0 bash "$HOOK" decide "$W" s1b direct "security: control path coverage check" "$f"
done
for f in src/secretsManager.ts .envrc docs/agents.md bin/keychain-secrets.sh src/auth/credentials.ts lib/secrets_manager.py; do
  runs "security refuses $f" 1 bash "$HOOK" decide "$W" s1b direct "security: control path coverage check" "$f"
done
runs "SECURITY_PATHS replaces the control paths" 0 env SECURITY_PATHS='^src/' bash "$HOOK" decide "$W" s1b direct "security: a repo of its own controls" src/a.ts
check deny "security: a file only an override on decide admitted is denied at edit time" "$(edit "$W/src/a.ts" s1b)"
P="$T/vscode/plug"
git init -q -b main "$P"
mkdir -p "$P/.claude-plugin" "$P/plugins/eng/.claude-plugin"
runs "security refuses a plugin's hooks without a tracked manifest" 1 bash "$HOOK" decide "$P" s1b direct "security: edits the plugin gate" hooks/gate.sh
echo '{}' >"$P/.claude-plugin/plugin.json"
echo '{}' >"$P/plugins/eng/.claude-plugin/plugin.json"
git -C "$P" add .claude-plugin/plugin.json plugins/eng/.claude-plugin/plugin.json
runs "security accepts a plugin's top-level hooks" 0 bash "$HOOK" decide "$P" s1b direct "security: edits the plugin gate" hooks/gate.sh agents/worker.md
runs "security accepts a nested plugin's agents and skill scripts" 0 bash "$HOOK" decide "$P" s1b direct "security: edits the nested plugin" plugins/eng/agents/w.md plugins/eng/skills/x/scripts/run.sh
runs "security refuses a plugin's README" 1 bash "$HOOK" decide "$P" s1b direct "security: edits the plugin readme" README.md

# trivial covers a few files and a capped number of changed lines in all
check deny "a decision does not carry over to another session" "$(edit "$W/src/c.ts" s2)"
runs "decide direct trivial" 0 bash "$HOOK" decide "$W" s2 direct "trivial: one-line typo fix"
check none "trivial: the first file after the decision is allowed" "$(edit "$W/src/c.ts" s2)"
check none "trivial: that same file stays allowed" "$(edit "$W/src/c.ts" s2)"
check none "trivial: a second file is allowed" "$(edit "$W/src/b.ts" s2)"
check none "trivial: a third file is allowed" "$(edit "$W/src/d.ts" s2)"
check deny "trivial: a fourth file is denied" "$(edit "$W/src/e.ts" s2)"
says "trivial deny says the task is not trivial and how to delegate" "$(edit "$W/src/e.ts" s2)" "covers up to 3 files" "decide $W s2 delegate"
big=$(jq -cn --arg p "$W/src/c.ts" --arg n "$(lines 70)" '{tool_input:{file_path:$p,old_string:"one",new_string:$n}}')
check deny "trivial: an edit past the line cap is denied" "$(edit "$W/src/c.ts" s2 "$big")"
multi=$(jq -cn --arg p "$W/src/c.ts" --arg n "$(lines 32)" '{tool_input:{file_path:$p,edits:[{old_string:"one",new_string:$n},{old_string:"two",new_string:$n}]}}')
check deny "trivial: a MultiEdit past the line cap is denied" "$(edit "$W/src/c.ts" s2 "$multi")"
whole=$(jq -cn --arg p "$W/src/c.ts" --arg n "$(lines 70)" '{tool_name:"Write",tool_input:{file_path:$p,content:$n}}')
check deny "trivial: a Write past the line cap is denied" "$(edit "$W/src/c.ts" s2 "$whole")"
lines 70 >>"$W/src/c.ts"
check deny "trivial: a file already past the line cap is denied" "$(edit "$W/src/c.ts" s2)"
git -C "$W" checkout -q -- src/c.ts
runs "decide trivial again" 0 bash "$HOOK" decide "$W" s2 direct "trivial: another one-line fix"
check none "trivial: recording again frees the files it covers" "$(edit "$W/src/e.ts" s2)"
runs "decide trivial for the cumulative cap" 0 bash "$HOOK" decide "$W" s2b direct "trivial: a few small edits"
step=$(jq -cn --arg p "$W/src/c.ts" --arg n "$(lines 24)" '{tool_input:{file_path:$p,old_string:"one",new_string:$n}}')
check none "trivial: a first 25-line edit is allowed" "$(edit "$W/src/c.ts" s2b "$step")"
git -C "$W" -c user.email=t@t -c user.name=t commit -q --allow-empty -m step
check none "trivial: a second 25-line edit after a commit is allowed" "$(edit "$W/src/c.ts" s2b "$step")"
git -C "$W" -c user.email=t@t -c user.name=t commit -q --allow-empty -m step
check deny "trivial: a commit does not reset the line count" "$(edit "$W/src/c.ts" s2b "$step")"
out=$(bash "$HOOK" decide "$W" s2b direct "trivial: a fresh small edit")
[[ $out == *"for 10 more changed lines of the 60"* ]] && pass "decide trivial again says how many lines are left" || fail "decide output: $out"
check deny "trivial: recording trivial again does not reset the line count" "$(edit "$W/src/c.ts" s2b "$step")"
runs "decide trivial for an edit with context" 0 bash "$HOOK" decide "$W" s2c direct "trivial: one line among many"
ctx=$(jq -cn --arg p "$W/src/c.ts" --arg o "$(lines 70)" --arg n "$(lines 70 | sed 's/^line 35$/changed/')" '{tool_input:{file_path:$p,old_string:$o,new_string:$n}}')
check none "trivial: unchanged context around an edit does not count" "$(edit "$W/src/c.ts" s2c "$ctx")"
out=$(TRIVIAL_MAX_LINES=08 bash "$HOOK" decide "$W" s2d direct "trivial: a small typo fix")
[[ $out == *"of the 60"* ]] && pass "a limit with a leading zero falls back to the default" || fail "decide output: $out"

# delegate needs a worker spawned after the decision and keeps the driver to an integration budget
printf '2000-01-01T00:00:00Z\ts3\tspawn\tearly\tsonnet\tgeneral-purpose\n' >>"$DELEGATION_EVENTS"
runs "decide delegate with the units" 0 bash "$HOOK" decide "$W" s3 delegate "importer, report, cli wiring"
check deny "delegated: a worker spawned before the decision does not count" "$(edit "$W/src/a.ts" s3)"
says "the no-worker deny says to spawn first" "$(edit "$W/src/a.ts" s3)" "has not spawned a named worker"
check none "an Explore spawn is logged after the Agent call" "$(tool PostToolUse Agent s3 '{"prompt":"x","subagent_type":"Explore","model":"sonnet"}')"
check deny "delegated: a read-only Explore spawn does not count as a worker" "$(edit "$W/src/a.ts" s3)"
check none "a bookkeeping agent spawn is logged" "$(tool PostToolUse Agent s3 '{"name":"pm","model":"sonnet","prompt":"x","subagent_type":"project-manager"}')"
check deny "delegated: a named agent outside the worker types does not count" "$(edit "$W/src/a.ts" s3)"
check none "a worker spawn is logged after the Agent call" "$(tool PostToolUse Agent s3 '{"name":"importer","model":"sonnet","prompt":"x"}')"
check none "delegated: after a worker spawn the driver may integrate" "$(edit "$W/src/a.ts" s3)"
huge=$(jq -cn --arg p "$W/src/a.ts" --arg n "$(lines 70)" '{tool_input:{file_path:$p,old_string:"x",new_string:$n}}')
check deny "delegated: the driver past the integration budget is denied" "$(edit "$W/src/a.ts" s3 "$huge")"
says "the budget deny says it is authoring" "$(edit "$W/src/a.ts" s3 "$huge")" "integration budget" "SendMessage" "opt-out"
runs "decide delegate again" 0 bash "$HOOK" decide "$W" s3 delegate "a second round of the same units"
check deny "delegated: recording delegate again does not refill the budget" "$(edit "$W/src/a.ts" s3 "$huge")"
printf 'a[$(touch %s/pwned-driver)]\n' "$T" >"$(state s3).driver"
check none "delegated: a non-numeric budget file is read as zero, never evaluated" "$(edit "$W/src/a.ts" s3)"
[[ ! -e $T/pwned-driver ]] && pass "the budget file is not evaluated as arithmetic" || fail "the budget file ran a command"
out=$(DELEGATION_EVENTS="$T/missing/events.tsv" bash "$HOOK" <<<"$(edit "$W/src/a.ts" s3)")
[[ -z $out ]] && pass "delegated: an events log that cannot exist fails open" || fail "missing events dir still denied: $out"
check none "a message is logged after the SendMessage call" "$(tool PostToolUse SendMessage s3 '{"to":"importer","message":"1. fix the test"}')"
check none "a message to a teammate the session did not spawn is logged" "$(tool PostToolUse SendMessage s3 '{"to":"team-lead","message":"status"}')"
events=$(awk -F'\t' '$2 == "s3" && $3 != "deny"' "$DELEGATION_EVENTS" | cut -f2-4,6)
[[ $events == $'s3\tspawn\tearly\tgeneral-purpose\ns3\tspawn\t\tExplore\ns3\tspawn\tpm\tproject-manager\ns3\tspawn\timporter\t\ns3\tmessage\timporter\t\ns3\tmessage\tteam-lead\t' ]] &&
  pass "events log session, kind, target and agent type" || fail "events: $events"
denied=$(awk -F'\t' '$2 == "s3" && $3 == "deny" && $4 == "Edit" && $6 == "no-worker"' "$DELEGATION_EVENTS" | grep -c .)
[[ $denied -ge 3 ]] && pass "each denial is logged with its tool and kind" || fail "deny events for s3: $denied"
check deny "a session that never decides is denied" "$(edit "$W/src/a.ts" s0u)"
report=$(bash "$HOOK" report)
[[ $report =~ s3[[:space:]]+delegate[[:space:]]+2[[:space:]]+1[[:space:]]+[1-9] && $report =~ s1[[:space:]]+security[[:space:]] ]] &&
  pass "report counts workers, messages to them and denials per session" || fail "report: $report"
[[ $report =~ s0u[[:space:]]+undecided[[:space:]]+0[[:space:]]+0[[:space:]]+1 ]] && pass "report lists a session that was denied but never decided" || fail "report: $report"
runs "decide delegate for the worker agent" 0 bash "$HOOK" decide "$W" s3w delegate "parser unit for the worker agent"
check none "the plugin's worker agent spawn is logged" "$(tool PostToolUse Agent s3w '{"name":"parser","model":"sonnet","prompt":"x","subagent_type":"hierarchical-implementation:worker"}')"
check none "delegated: the plugin's worker agent counts as a worker" "$(edit "$W/src/a.ts" s3w)"
: >"$T/empty.tsv"
report=$(DELEGATION_LOG="$T/empty.tsv" bash "$HOOK" report)
[[ $report != *delegate* && $report != *security* ]] && pass "report with an empty decision log does not read events as decisions" || fail "report: $report"

# a free-model worker started through the skill's script counts like an Agent worker
free() { tool PostToolUse Bash "${2:-sfree}" "$(jq -cn --arg c "$1" '{command:$c}')"; }
runs "decide delegate for a free-model worker" 0 bash "$HOOK" decide "$W" sfree delegate "parser unit on a free model"
check none "a Bash call that is not a free-model worker is not logged" "$(free "git status")"
check deny "delegated: an unrelated Bash call is not a worker" "$(edit "$W/src/a.ts" sfree)"
check none "a free-model worker run is logged after the Bash call" "$(free "/x/scripts/free-models.sh run $W parser /tmp/brief.md 2>&1")"
check none "delegated: after a free-model worker the driver may integrate" "$(edit "$W/src/a.ts" sfree)"
check none "continuing a free-model session is logged" "$(free "free-models.sh run --model opencode/x-free $W parser /tmp/fix.md ses_abc123")"
check none "a quoted script path and a quoted session are logged" "$(free "\"\$D/free-models.sh\" run $W lexer /tmp/fix.md \"\$SID\"")"
events=$(awk -F'\t' '$2 == "sfree" && $3 != "deny"' "$DELEGATION_EVENTS" | cut -f3-6)
[[ $events == $'spawn\tparser\tfree\tfree-models\nmessage\tparser\topencode/x-free\tfree-models\nmessage\tlexer\tfree\tfree-models' ]] &&
  pass "free-model events log kind, worker name, model and the free-models type" || fail "events: $events"
# a mention of the script, or a chained command, is not a worker
runs "decide delegate for mentions of the script" 0 bash "$HOOK" decide "$W" sfp delegate "parser unit on a free model"
for c in "echo free-models.sh run a b c" \
  "grep \"free-models.sh run <worktree> <name> <brief-file>\" SKILL.md" \
  "git commit -m \"feat: free-models.sh run logs as a spawn\"" \
  "false && free-models.sh run $W parser /tmp/brief.md" \
  "free-models.sh run $W parser /tmp/brief.md; rm -rf $W" \
  "free-models.sh run $W parser /tmp/brief.md | tee log" \
  "free-models.sh run $W parser \$(cat x)"; do
  free "$c" sfp >/dev/null
done
[[ -z $(grep sfp "$DELEGATION_EVENTS") ]] && pass "mentions and chained commands are not logged" || fail "events: $(grep sfp "$DELEGATION_EVENTS")"
check deny "delegated: a mention of the script is not a worker" "$(edit "$W/src/a.ts" sfp)"

# Bash: the decide command is approved
check approve "the gate's own decide command is approved" "$(shell s4 "$HOOK decide $W s4 direct \"trivial: one line typo fix\"")"
check approve "a security decide with files is approved" "$(shell s4 "$HOOK decide $W s4 direct \"security: edits the gate itself\" src/a.ts hooks/x.json")"
check none "a decide command chained with another is not approved" "$(shell s4 "$HOOK decide $W s4 direct \"trivial: one line typo fix\" && rm -rf $T/other")"
check none "a decide command with a substitution is not approved" "$(shell s4 "$HOOK decide $W s4 direct \"trivial: one \$(touch $T/pwned) fix\"")"
check none "a decide command with an exclamation mark is not approved" "$(shell s4 "$HOOK decide $W s4 direct \"trivial: one line fix!\"")"
check none "a decide command for another session is not approved" "$(shell s4 "$HOOK decide $W s9 direct \"opt-out: the user said so\"")"
check none "a decide command with the sandbox disabled is not approved" "$(tool PreToolUse Bash s4 "$(jq -cn --arg c "$HOOK decide $W s4 direct \"trivial: one line typo fix\"" '{command:$c,dangerouslyDisableSandbox:true}')")"

# paths the edit tools would resolve into the root are judged there
check deny "a .. through a missing directory is resolved into the root" "$(edit "$T/other/zzz/../../vscode/repo/src/c.ts" s8)"
ln -s "$W/src/c.ts" "$T/other/flink"
check deny "a symlinked file outside the root is judged by its target" "$(edit "$T/other/flink" s8)"
check deny "a path with a newline under the root is denied" "$(edit "$W/src/x
y.ts" s8)"

# Bash and Monitor: recognized shell writes are gated like edits
check deny "sed -i on a gated file is denied before a decision" "$(shell s5 "sed -i 's/one/uno/' $W/src/c.ts")"
check deny "a redirect into a gated file is denied" "$(shell s5 "echo hi > src/c.ts")"
check deny "an appending redirect is denied" "$(shell s5 "echo hi >> src/c.ts")"
check deny "tee into a gated file is denied" "$(shell s5 "printf x | tee -a src/new.ts")"
check deny "perl -pi is denied" "$(shell s5 "perl -pi -e 's/a/b/' src/c.ts")"
check deny "a redirect glued to the previous word is denied" "$(shell s5 "echo hi>src/c.ts")"
check deny "tee glued to a pipe is denied" "$(shell s5 "printf x|tee src/c.ts")"
check deny "sed -i glued to && is denied" "$(shell s5 "true&&sed -i s/a/b/ src/c.ts")"
check deny "tee called by path is denied" "$(shell s5 "/usr/bin/tee src/c.ts")"
check deny ">& to a file is denied" "$(shell s5 "echo hi >&src/c.ts")"
check deny "a word with a quoted part does not hide a later redirect" "$(shell s5 "echo \"a\"b > src/c.ts")"
check deny "a comment does not hide the next line" "$(shell s5 "true # <<
echo hi > src/c.ts")"
check deny "a line after a heredoc body is parsed" "$(shell s5 "cat <<'EOF' > $T/other/x.md
body > src/c.ts
EOF
echo hi > src/c.ts")"
check deny "cd into a worktree is followed" "$(shell s5 "cd $W && echo hi > f.ts" "$T/other")"
out=$(HOME="$W" bash "$HOOK" <<<"$(shell s5 "echo hi > ~/src/c.ts" "$T/other")")
[[ $(verdict "$out") == deny ]] && pass "~ is expanded in a target" || fail "~ target: $(verdict "$out")"
check deny "Monitor commands are gated like Bash" "$(tool PreToolUse Monitor s5 '{"command":"echo hi > src/c.ts","description":"x"}')"
says "the shell deny names the file and the decision" "$(shell s5 "echo hi >src/c.ts")" "This command writes $W/src/c.ts" "decide $W s5 delegate"
many=$(printf " $T/other/f%d" $(seq 21))
check deny "a command writing more files than the gate checks is denied" "$(shell s5 "printf x | tee$many")"

# Bash: read-only commands are not mistaken for writes
check none "a redirect outside the root is allowed" "$(shell s5 "git -C $W diff > $T/other/out.txt 2>/dev/null")"
check none "sed without -i is allowed" "$(shell s5 "sed -n '1,5p' $W/src/c.ts")"
check none "the word tee as an argument is not tee" "$(shell s5 "grep -n tee src/c.ts")"
check none "a quoted tee argument is not tee" "$(shell s5 "rg -n \"tee\" src/")"
check none "perl -M is not in-place" "$(shell s5 "perl -Mstrict -ne 'print' src/c.ts")"
check none "perl -MList::Util with -lane is not in-place" "$(shell s5 "perl -MList::Util=sum -lane 'print' src/c.ts")"
check none "a quoted > is not a redirect" "$(shell s5 "gh pr comment 1 --body \"a > src/c.ts\"")"
check none "a standalone quoted > is not a redirect" "$(shell s5 "grep -c '>' src/c.ts")"
check none "a > inside a glued quoted option is not a redirect" "$(shell s5 "gh api x --jq='.n > 1'")"
check none "escaped quotes keep the string open" "$(shell s5 "echo \"say \\\"hi\\\" > src/c.ts\"")"
check none "a > inside [[ ]] compares" "$(shell s5 "[[ a > src/c.ts ]] && echo y")"
check none "a > inside (( )) compares" "$(shell s5 "(( n > 5 ))")"
check none "file descriptor duplication is not a file" "$(shell s5 "make 2>&1 >&2")"
check none "a target with an unknown variable is skipped" "$(shell s5 "git diff > \"\$TMPDIR/x.diff\"")"
check none "a target under \$HOME outside the root is allowed" "$(shell s5 "git diff > \$HOME/patch.diff")"
check none "heredoc bodies are not parsed" "$(shell s5 "cat > $T/other/x.md <<'EOF'
> src/c.ts
EOF")"

# heredoc bodies give a shell write its size
runs "decide trivial for heredoc sizing" 0 bash "$HOOK" decide "$W" s6 direct "trivial: one small file rewrite"
check none "trivial: a small heredoc write is allowed" "$(shell s6 "cat > src/c.ts <<'EOF'
one
EOF")"
check deny "trivial: a heredoc write past the line cap is denied" "$(shell s6 "cat > src/c.ts <<'EOF'
$(lines 70)
EOF")"

# Agent: named workers carry a model, in sessions the gate has seen
check deny "a named worker without model is denied" "$(tool PreToolUse Agent s1 '{"name":"w1","prompt":"x"}')"
check none "a named worker with model is allowed" "$(tool PreToolUse Agent s1 '{"name":"w1","model":"sonnet","prompt":"x"}')"
check none "an unnamed agent is allowed" "$(tool PreToolUse Agent s1 '{"prompt":"x","subagent_type":"Explore"}')"
check none "a fork is allowed" "$(tool PreToolUse Agent s1 '{"name":"f1","prompt":"x","subagent_type":"fork"}')"
check none "a session the gate never saw is not asked for a model" "$(tool PreToolUse Agent fresh '{"name":"w1","prompt":"x"}')"

# a worker, like the first edit, needs a decision, so a task that only delegates still records one
worker='{"name":"w1","model":"sonnet","prompt":"x","subagent_type":"hierarchical-implementation:worker"}'
check deny "the plugin's worker before any decision is denied" "$(tool PreToolUse Agent sw0 "$worker")"
says "the spawn deny gives the decide command, the exemptions and the reader type" "$(tool PreToolUse Agent sw0 "$worker")" "decide $W sw0 delegate" "trivial, security" "spawn it as Explore"
check deny "an unnamed worker of the plugin's type is denied too" "$(tool PreToolUse Agent sw0 '{"model":"sonnet","prompt":"x","subagent_type":"worker"}')"
check deny "the worker type is matched the way Claude Code folds it" "$(tool PreToolUse Agent sw0 '{"model":"sonnet","prompt":"x","subagent_type":"Hierarchical_Implementation:Worker"}')"
check deny "a free-model worker before any decision is denied" "$(shell sw0 "/x/scripts/free-models.sh run $W parser /tmp/brief.md 2>&1")"
check none "a free-model continuation is not a first worker" "$(shell sw0 "/x/scripts/free-models.sh run $W parser /tmp/fix.md ses_abc123")"
check none "a named general-purpose agent, which may only research, is not asked" "$(tool PreToolUse Agent sw0 '{"name":"hunt","model":"sonnet","prompt":"x"}')"
check none "an explicit general-purpose agent is not asked" "$(tool PreToolUse Agent sw0 '{"name":"hunt","model":"sonnet","prompt":"x","subagent_type":"general-purpose"}')"
check none "a fork is not asked" "$(tool PreToolUse Agent sw0 '{"name":"f1","prompt":"x","subagent_type":"fork"}')"
check none "a named reader before any decision is allowed" "$(tool PreToolUse Agent sw0 '{"name":"scout","model":"sonnet","prompt":"x","subagent_type":"Explore"}')"
check none "a session working outside the root is not asked for a decision" "$(tool PreToolUse Agent sw0 "$worker" "$T/other")"
out=$(XDG_STATE_HOME="$T/not-a-dir" bash "$HOOK" <<<"$(tool PreToolUse Agent sw0 "$worker")")
[[ -z $out ]] && pass "a state dir that cannot be written lets the worker start" || fail "unwritable state dir still denied the worker"
denied=$(awk -F'\t' '$2 == "sw0" && $3 == "deny" && $6 == "undecided" {print $4}' "$DELEGATION_EVENTS" | sort -u | tr '\n' ' ')
[[ $denied == "Agent Bash " ]] && pass "an undecided spawn is logged as an undecided denial" || fail "deny events for sw0: $denied"
runs "decide delegate before the first worker" 0 bash "$HOOK" decide "$T/other" sw0 delegate "parser unit for one worker"
check none "a decision in another worktree lets the named worker start" "$(tool PreToolUse Agent sw0 "$worker")"
check none "a decision lets the free-model worker start" "$(shell sw0 "/x/scripts/free-models.sh run $W parser /tmp/brief.md 2>&1")"
check deny "after a decision a named worker still needs a model" "$(tool PreToolUse Agent sw0 '{"name":"w2","prompt":"x","subagent_type":"worker"}')"
mkdir -p "$T/st[1]" "$T/st1"
XDG_STATE_HOME="$T/st[1]" bash "$HOOK" decide "$W" sw1 delegate "parser unit for one worker" >/dev/null 2>&1
mkdir -p "$T/st1/claude-gates/delegation/sw1" # a glob would read st[1] as st1 and find no decision here
out=$(XDG_STATE_HOME="$T/st[1]" bash "$HOOK" <<<"$(tool PreToolUse Agent sw1 "$worker")")
[[ -z $out ]] && pass "a decision under a state path with glob characters is found" || fail "decision under st[1] not found"

# edit sizes and state hold up against replace_all, git config and parallel calls
runs "decide trivial for replace_all" 0 bash "$HOOK" decide "$W" s9 direct "trivial: one word swap in r"
once=$(jq -cn --arg p "$W/src/r.ts" '{tool_input:{file_path:$p,old_string:"x",new_string:"y"}}')
check none "trivial: a single replacement is small" "$(edit "$W/src/r.ts" s9 "$once")"
every=$(jq -cn --arg p "$W/src/r.ts" '{tool_input:{file_path:$p,old_string:"x",new_string:"y",replace_all:true}}')
check deny "trivial: replace_all counts every occurrence" "$(edit "$W/src/r.ts" s9 "$every")"
git -C "$W" config core.fsmonitor "touch $T/pwned-fsmonitor"
run "$(edit "$W/src/r.ts" s9)" >/dev/null
git -C "$W" config --unset core.fsmonitor
[[ ! -e $T/pwned-fsmonitor ]] && pass "the hook's git calls never run core.fsmonitor" || fail "core.fsmonitor ran"
runs "decide trivial for a parallel race" 0 bash "$HOOK" decide "$W" s10 direct "trivial: one small parallel fix"
for i in 1 2 3 4; do run "$(edit "$W/src/p$i.ts" s10)" >"$T/race$i" & done
wait
denied=$(cat "$T/race1" "$T/race2" "$T/race3" "$T/race4" | grep -c '"deny"')
[[ $denied == 1 ]] && pass "trivial: four parallel edits to different files let only three through" || fail "parallel trivial edits: $denied denied"

# LANE_MODE, exported by a lane spawner, outranks the brief
runs "decide refuses the lane exemption in a driver lane" 1 env LANE_MODE=driver bash "$HOOK" decide "$W" s11 direct "lane: the coordinator spawned this session"
runs "decide refuses the lane exemption without LANE_MODE" 1 bash "$HOOK" decide "$W" s11 direct "lane: the coordinator spawned this session"
runs "decide accepts the lane exemption in a unit lane" 0 env LANE_MODE=unit bash "$HOOK" decide "$W" s11 direct "lane: the coordinator spawned this session"
got=$(verdict "$(LANE_MODE=unit bash "$HOOK" <<<"$(edit "$W/src/a.ts" s11)")")
[[ $got == none ]] && pass "lane: a unit lane edits after recording lane" || fail "lane under LANE_MODE=unit: $got"
got=$(verdict "$(LANE_MODE=driver bash "$HOOK" <<<"$(edit "$W/src/a.ts" s11)")")
[[ $got == deny ]] && pass "lane: a recorded lane exemption is denied in a driver lane" || fail "lane under LANE_MODE=driver: $got"
check deny "lane: a recorded lane exemption is denied without LANE_MODE" "$(edit "$W/src/a.ts" s11)"
reason=$(LANE_MODE=driver bash "$HOOK" <<<"$(edit "$W/src/a.ts" s12)" | jq -r '.hookSpecificOutput.permissionDecisionReason')
[[ $reason == *"spawned as a driver lane"* ]] && pass "lane: an undecided driver lane is told to delegate" || fail "driver lane first-edit reason: $reason"
reason=$(LANE_MODE=unit bash "$HOOK" <<<"$(edit "$W/src/a.ts" s12u)" | jq -r '.hookSpecificOutput.permissionDecisionReason')
[[ $reason == *"spawned as a unit lane"* ]] && pass "lane: an undecided unit lane is told to record lane itself" || fail "unit lane first-edit reason: $reason"
grep -q $'\ts12u\t' "$DELEGATION_LOG" && fail "unit lane decision: $(grep s12u "$DELEGATION_LOG")" || pass "lane: LANE_MODE=unit records no decision by itself"

# HI_FREE_WORKERS=1: the plugin's worker on sonnet waits for a free-model run of its unit
mkdir -p "$T/bin"
printf '#!/bin/sh\n' >"$T/bin/opencode"
chmod +x "$T/bin/opencode"
fcheck() { # fcheck <none|deny> <label> <payload> [VAR=value...]: check with free-model workers on and a stub opencode
  local want=$1 label=$2 payload=$3 got
  shift 3
  got=$(verdict "$(env HI_FREE_WORKERS=1 OPENCODE_BIN="$T/bin/opencode" "$@" bash "$HOOK" <<<"$payload")")
  [[ $got == "$want" ]] && pass "$label" || fail "$label (expected $want, got $got)"
}
fw() { jq -cn --arg n "$1" --arg m "${2:-sonnet}" --arg t "${3:-hierarchical-implementation:worker}" '{name:$n,model:$m,prompt:"x",subagent_type:$t}'; }
runs "decide delegate for free-first" 0 bash "$HOOK" decide "$W" sf1 delegate "parser and lexer units"
runs "decide delegate in a second free-first session" 0 bash "$HOOK" decide "$W" sf2 delegate "parser unit only"
fcheck deny "free-first: the plugin's worker on sonnet before a free-model run is denied" "$(tool PreToolUse Agent sf1 "$(fw parser)")"
reason=$(env HI_FREE_WORKERS=1 OPENCODE_BIN="$T/bin/opencode" bash "$HOOK" <<<"$(tool PreToolUse Agent sf1 "$(fw parser)")" | jq -r '.hookSpecificOutput.permissionDecisionReason')
[[ $reason == *"references/free-models.md"* && $reason == *"free-models.sh run <worktree> parser <brief-file>"* && $reason == *"exits 3"* ]] &&
  pass "free-first: the deny names the reference, the run command with the unit and the fallback" || fail "free-first reason: $reason"
fcheck deny "free-first: a full sonnet model id counts as sonnet" "$(tool PreToolUse Agent sf1 "$(fw parser claude-sonnet-5-5)")"
fcheck deny "free-first: an unnamed plugin worker is denied" "$(tool PreToolUse Agent sf1 '{"model":"sonnet","prompt":"x","subagent_type":"worker"}')"
fcheck none "free-first: off without HI_FREE_WORKERS=1" "$(tool PreToolUse Agent sf1 "$(fw parser)")" HI_FREE_WORKERS=
fcheck none "free-first: off when opencode is missing" "$(tool PreToolUse Agent sf1 "$(fw parser)")" OPENCODE_BIN="$T/bin/none"
fcheck none "free-first: a driver lane is not asked" "$(tool PreToolUse Agent sf1 "$(fw parser)")" LANE_MODE=driver
fcheck none "free-first: a model the user named runs as asked" "$(tool PreToolUse Agent sf1 "$(fw parser fable)")"
fcheck none "free-first: a general-purpose agent is not asked" "$(tool PreToolUse Agent sf1 "$(fw parser sonnet general-purpose)")"
fcheck none "free-first: a session working outside the root is not asked" "$(tool PreToolUse Agent sf1 "$(fw parser)" "$T/other")"
got=$(env HI_FREE_WORKERS=1 OPENCODE_BIN="$T/bin/opencode" bash "$HOOK" <<<"$(tool PreToolUse Agent sf1 '{"name":"parser","prompt":"x","subagent_type":"worker"}')" | jq -r '.hookSpecificOutput.permissionDecisionReason')
[[ $got == "Set model"* ]] && pass "free-first: a named worker without a model gets the model deny first" || fail "free-first without model: $got"
check none "free-first: the parser free-model run is logged" "$(free "/x/scripts/free-models.sh run $W parser /tmp/brief.md 2>&1" sf1)"
fcheck none "free-first: after its free-model run the unit's worker starts" "$(tool PreToolUse Agent sf1 "$(fw parser)")"
fcheck none "free-first: a redo named after the unit starts" "$(tool PreToolUse Agent sf1 "$(fw parser-b)")"
fcheck deny "free-first: another unit still needs its own run" "$(tool PreToolUse Agent sf1 "$(fw lexer)")"
fcheck deny "free-first: a name sharing a prefix without a dash does not match" "$(tool PreToolUse Agent sf1 "$(fw parserx)")"
fcheck deny "free-first: another session's run does not count" "$(tool PreToolUse Agent sf2 "$(fw parser)")"
check none "free-first: a run with a quoted unit name is logged" "$(free "free-models.sh run $W \"lexer\" /tmp/brief.md" sf1)"
fcheck none "free-first: a quoted unit name matches the worker's name" "$(tool PreToolUse Agent sf1 "$(fw lexer)")"
fcheck deny "free-first: an events log in a directory not created yet still asks" "$(tool PreToolUse Agent sf1 "$(fw parser)")" DELEGATION_EVENTS="$T/new-events/events.tsv"
grep -q $'\tsf1\tdeny\tAgent\t\tfree-first$' "$DELEGATION_EVENTS" && pass "free-first: a denial is logged with its kind" || fail "free-first deny events: $(grep sf1 "$DELEGATION_EVENTS")"
start() { jq -cn '{hook_event_name:"SessionStart",session_id:"ss1",cwd:"/",source:"startup"}'; }
out=$(env HI_FREE_WORKERS=1 OPENCODE_BIN="$T/bin/opencode" bash "$HOOK" <<<"$(start)")
[[ $(jq -r '.hookSpecificOutput | .hookEventName + " " + .additionalContext' <<<"$out" 2>/dev/null) == "SessionStart Free-model workers are on"* ]] &&
  pass "session start: the note is added when free-model workers are on" || fail "session start output: $out"
out=$(env OPENCODE_BIN="$T/bin/opencode" bash "$HOOK" <<<"$(start)")
[[ -z $out ]] && pass "session start: nothing without HI_FREE_WORKERS=1" || fail "session start without the variable: $out"
out=$(env HI_FREE_WORKERS=1 OPENCODE_BIN="$T/bin/none" bash "$HOOK" <<<"$(start)")
[[ -z $out ]] && pass "session start: nothing when opencode is missing" || fail "session start without opencode: $out"
out=$(env HI_FREE_WORKERS=1 OPENCODE_BIN="$T/bin/opencode" LANE_MODE=driver bash "$HOOK" <<<"$(start)")
[[ -z $out ]] && pass "session start: nothing in a driver lane" || fail "session start in a driver lane: $out"

git -C "$W" worktree add -q "$W/.worktrees/fix" -b fix
mkdir -p "$W/.worktrees/fix/src"
check deny "linked worktree: the main checkout's decision does not carry over" "$(edit "$W/.worktrees/fix/src/a.ts")"

echo
((fails == 0)) && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
