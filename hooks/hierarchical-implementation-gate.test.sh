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
trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
W="$T/vscode/repo"
git init -q -b main "$W"
mkdir -p "$W/src" "$T/other"
printf 'one\ntwo\n' >"$W/src/c.ts"
git -C "$W" add src/c.ts
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

# security covers only the named files
runs "decide direct security with a reason and a file" 0 bash "$HOOK" decide "$W/src" s1 direct $'security: edits\tthe gate itself' src/a.ts
check none "security: the named file is allowed" "$(edit "$W/src/a.ts")"
check deny "security: an unnamed file is denied" "$(edit "$W/src/b.ts")"
says "security deny names the scope, how to add a file, and not to re-record delegate" "$(edit "$W/src/b.ts")" \
  "not one of them" "decide $W s1 direct" "would drop the security scope"
s="" top="" choice="" why="" named="" extra=""
IFS=$'\t' read -r _ s top choice why named extra <"$DELEGATION_LOG"
[[ $s == s1 && $top == "$W" && $choice == direct && $why == "security: edits the gate itself" && $named == "$W/src/a.ts" && -z $extra ]] &&
  pass "decision logged with session, worktree, choice, a one-field reason and the named files" || fail "log line: $(cat "$DELEGATION_LOG")"
runs "decide security again adds a file" 0 bash "$HOOK" decide "$W" s1 direct "security: also the hook registration" "$W/src/b.ts"
check none "security: the added file is allowed" "$(edit "$W/src/b.ts")"

# trivial covers one file and a few lines
check deny "a decision does not carry over to another session" "$(edit "$W/src/c.ts" s2)"
runs "decide direct trivial" 0 bash "$HOOK" decide "$W" s2 direct "trivial: one-line typo fix"
check none "trivial: the first file after the decision is allowed" "$(edit "$W/src/c.ts" s2)"
check none "trivial: that same file stays allowed" "$(edit "$W/src/c.ts" s2)"
check deny "trivial: a second file is denied" "$(edit "$W/src/b.ts" s2)"
says "trivial deny says the task is not trivial and how to delegate" "$(edit "$W/src/b.ts" s2)" "covers one file" "decide $W s2 delegate"
big=$(jq -cn --arg p "$W/src/c.ts" --arg n "$(lines 30)" '{tool_input:{file_path:$p,old_string:"one",new_string:$n}}')
check deny "trivial: an edit past the line cap is denied" "$(edit "$W/src/c.ts" s2 "$big")"
multi=$(jq -cn --arg p "$W/src/c.ts" --arg n "$(lines 12)" '{tool_input:{file_path:$p,edits:[{old_string:"one",new_string:$n},{old_string:"two",new_string:$n}]}}')
check deny "trivial: a MultiEdit past the line cap is denied" "$(edit "$W/src/c.ts" s2 "$multi")"
whole=$(jq -cn --arg p "$W/src/c.ts" --arg n "$(lines 30)" '{tool_name:"Write",tool_input:{file_path:$p,content:$n}}')
check deny "trivial: a Write past the line cap is denied" "$(edit "$W/src/c.ts" s2 "$whole")"
lines 30 >>"$W/src/c.ts"
check deny "trivial: a file already past the line cap is denied" "$(edit "$W/src/c.ts" s2)"
git -C "$W" checkout -q -- src/c.ts
runs "decide trivial again" 0 bash "$HOOK" decide "$W" s2 direct "trivial: another one-line fix"
check none "trivial: recording again frees the file it covers" "$(edit "$W/src/b.ts" s2)"

# delegate needs a named editing worker and keeps the driver to an integration budget
runs "decide delegate with the units" 0 bash "$HOOK" decide "$W" s3 delegate "importer, report, cli wiring"
check deny "delegated: the driver may not edit before a worker is spawned" "$(edit "$W/src/a.ts" s3)"
says "the no-worker deny says to spawn first" "$(edit "$W/src/a.ts" s3)" "has not spawned a named worker"
check none "an Explore spawn is logged after the Agent call" "$(tool PostToolUse Agent s3 '{"prompt":"x","subagent_type":"Explore","model":"sonnet"}')"
check deny "delegated: a read-only Explore spawn does not count as a worker" "$(edit "$W/src/a.ts" s3)"
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
events=$(cut -f2-4,6 "$DELEGATION_EVENTS")
[[ $events == $'s3\tspawn\t\tExplore\ns3\tspawn\timporter\t\ns3\tmessage\timporter\t' ]] && pass "events log session, kind, target and agent type" || fail "events: $events"
report=$(bash "$HOOK" report)
[[ $report =~ s3[[:space:]]+delegate[[:space:]]+2[[:space:]]+1 && $report =~ s1[[:space:]]+security[[:space:]] ]] &&
  pass "report shows each session's decisions, spawns and messages" || fail "report: $report"
: >"$T/empty.tsv"
report=$(DELEGATION_LOG="$T/empty.tsv" bash "$HOOK" report)
[[ $report != *s3* ]] && pass "report with an empty decision log does not read events as decisions" || fail "report: $report"

# Bash: the decide command is approved
check approve "the gate's own decide command is approved" "$(shell s4 "$HOOK decide $W s4 direct \"trivial: one line typo fix\"")"
check approve "a security decide with files is approved" "$(shell s4 "$HOOK decide $W s4 direct \"security: edits the gate itself\" src/a.ts hooks/x.json")"
check none "a decide command chained with another is not approved" "$(shell s4 "$HOOK decide $W s4 direct \"trivial: one line typo fix\" && rm -rf $T/other")"
check none "a decide command with a substitution is not approved" "$(shell s4 "$HOOK decide $W s4 direct \"trivial: one \$(touch $T/pwned) fix\"")"
check none "a decide command with an exclamation mark is not approved" "$(shell s4 "$HOOK decide $W s4 direct \"trivial: one line fix!\"")"

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
$(lines 30)
EOF")"

# Agent: named workers carry a model, in sessions the gate has seen
check deny "a named worker without model is denied" "$(tool PreToolUse Agent s1 '{"name":"w1","prompt":"x"}')"
check none "a named worker with model is allowed" "$(tool PreToolUse Agent s1 '{"name":"w1","model":"sonnet","prompt":"x"}')"
check none "an unnamed agent is allowed" "$(tool PreToolUse Agent s1 '{"prompt":"x","subagent_type":"Explore"}')"
check none "a fork is allowed" "$(tool PreToolUse Agent s1 '{"name":"f1","prompt":"x","subagent_type":"fork"}')"
check none "a session the gate never saw is not asked for a model" "$(tool PreToolUse Agent fresh '{"name":"w1","prompt":"x"}')"

git -C "$W" worktree add -q "$W/.worktrees/fix" -b fix
mkdir -p "$W/.worktrees/fix/src"
check deny "linked worktree: the main checkout's decision does not carry over" "$(edit "$W/.worktrees/fix/src/a.ts")"

echo
((fails == 0)) && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
