#!/usr/bin/env bash
# Regression suite for hierarchical-implementation-gate.sh: builds a throwaway root with a repo
# and a linked worktree, feeds the hook synthetic Edit/Write payloads, and drives the decide CLI.
# Runs against the hook next to it, as a chezmoi source file or as the applied copy.
#   bash ~/.claude/hooks/hierarchical-implementation-gate.test.sh
set -u

HOOK="${HOOK:-$(dirname "$0")/hierarchical-implementation-gate.sh}"
[[ -f $HOOK ]] || HOOK="$(dirname "$0")/executable_hierarchical-implementation-gate.sh"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

T=$(cd "$(mktemp -d)" && pwd -P)
export XDG_STATE_HOME="$T/state" HIERARCHICAL_GATE_ROOT="$T/vscode" DELEGATION_LOG="$T/decisions.tsv"
trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
W="$T/vscode/repo"
git init -q -b main "$W"
git -C "$W" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$W/src" "$T/other"
git init -q -b main "$T/other"

hook() { # hook <file_path> [session] [extra json] -> the hook's output
  jq -cn --arg p "$1" --arg s "${2:-s1}" --arg c "$W" --argjson x "${3:-{\}}" \
    '{tool_name:"Edit",session_id:$s,cwd:$c,tool_input:{file_path:$p}} + $x' | bash "$HOOK"
}
expect() { # expect <allow|deny> <label> <file_path> [session] [extra json]
  local out got
  out=$(hook "$3" "${4:-}" "${5:-}")
  if [[ $out == *'"permissionDecision":"deny"'* ]]; then got=deny; else [[ -z $out ]] && got=allow || got="malformed:$out"; fi
  [[ $got == "$1" ]] && pass "$2" || fail "$2 (expected $1, got $got)"
}
runs() { # runs <label> <expected-exit> <cmd...>
  local label=$1 want=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  [[ $got == "$want" ]] && pass "$label" || fail "$label (exit $got, wanted $want)"
}
says() { # says <label> <reason> <substring...>
  local label=$1 reason=$2
  shift 2
  for s in "$@"; do [[ $reason == *"$s"* ]] || { fail "$label (missing '$s'): $reason"; return; }; done
  pass "$label"
}

expect deny "the main thread's first file is denied" "$W/src/a.ts"
expect deny "a relative path is resolved against cwd" "src/a.ts"
expect deny "a notebook path is gated too" "$W/src/a.ipynb" s1 "{\"tool_input\":{\"notebook_path\":\"$W/src/a.ipynb\"}}"
expect allow "subagent edits are not gated" "$W/src/a.ts" s1 '{"agent_id":"worker-1"}'
expect allow "paths outside the root are not gated" "$T/other/a.ts"
expect allow "a session id that is not an id fails open" "$W/src/a.ts" '../escape'
ln -s "$W" "$T/link"
expect deny "a symlinked path into the root is still gated" "$T/link/src/a.ts"
out=$(HIERARCHICAL_GATE=off bash "$HOOK" <<<"$(jq -cn --arg p "$W/src/a.ts" '{session_id:"s1",tool_input:{file_path:$p}}')")
[[ -z $out ]] && pass "HIERARCHICAL_GATE=off allows" || fail "HIERARCHICAL_GATE=off still denied"
touch "$T/not-a-dir"
out=$(XDG_STATE_HOME="$T/not-a-dir" bash "$HOOK" <<<"$(jq -cn --arg p "$W/src/a.ts" '{session_id:"s1",tool_input:{file_path:$p}}')")
[[ -z $out ]] && pass "a state dir that cannot be written fails open" || fail "unwritable state dir still denied"

says "deny reason carries the authorization, the loop, the exemptions and both commands" \
  "$(hook "$W/src/a.ts" | jq -r '.hookSpecificOutput.permissionDecisionReason')" \
  "standing authorization" hierarchical-implementation "decide $W s1 delegate" "decide $W s1 direct" \
  "same worker with SendMessage" "three rounds" "trivial (" "never delegated" "lane (" "opt-out (" "no-subagents (" "/repro"

odd="$T/vscode/x\$(touch $T/pwned)"
git init -q -b main "$odd"
out=$(hook "$odd/a.ts")
[[ -z $out && ! -e $T/pwned ]] && pass "a worktree path outside the plain set is never gated" || fail "odd path: $out"

runs "decide refused for an unknown choice" 1 bash "$HOOK" decide "$W" s1 maybe "one unit only here"
runs "decide refused for delegate units under three words" 1 bash "$HOOK" decide "$W" s1 delegate "one unit"
runs "decide refused for direct without an exemption" 1 bash "$HOOK" decide "$W" s1 direct "one coupled unit here"
runs "decide refused for an unknown exemption" 1 bash "$HOOK" decide "$W" s1 direct "coupled: load and assign share exports"
runs "decide refused for an exemption without three words of why" 1 bash "$HOOK" decide "$W" s1 direct "trivial: typo"
runs "decide refused outside a git repo" 1 bash "$HOOK" decide "$T" s1 direct "trivial: one-line typo fix"
runs "decide refused for a session that is not an id" 1 bash "$HOOK" decide "$W" ../s1 direct "trivial: one-line typo fix"

runs "decide direct security with a reason" 0 bash "$HOOK" decide "$W/src" s1 direct $'security: edits\tthe gate itself'
expect allow "security: the denied file is allowed" "$W/src/a.ts"
expect allow "security: further files are allowed" "$W/src/b.ts"
s="" top="" choice="" why="" extra=""
IFS=$'\t' read -r _ s top choice why extra <"$DELEGATION_LOG"
[[ $s == s1 && $top == "$W" && $choice == direct && $why == "security: edits the gate itself" && -z $extra ]] &&
  pass "decision logged with session, worktree, choice and a reason kept on one field" || fail "log line: $(cat "$DELEGATION_LOG")"

expect deny "a decision does not carry over to another session" "$W/src/a.ts" s2
runs "decide direct trivial" 0 bash "$HOOK" decide "$W" s2 direct "trivial: one-line typo fix"
expect allow "trivial: the first file after the decision is allowed" "$W/src/a.ts" s2
expect allow "trivial: that same file stays allowed" "$W/src/a.ts" s2
expect deny "trivial: a second file is denied" "$W/src/b.ts" s2
says "trivial deny says the task is not trivial and how to delegate" \
  "$(hook "$W/src/b.ts" s2 | jq -r '.hookSpecificOutput.permissionDecisionReason')" \
  "covers one file" "decide $W s2 delegate"
runs "decide delegate with the units" 0 bash "$HOOK" decide "$W" s2 delegate "importer, report, cli wiring"
expect allow "delegated: the driver may integrate" "$W/src/b.ts" s2

git -C "$W" worktree add -q "$W/.worktrees/fix" -b fix
mkdir -p "$W/.worktrees/fix/src"
expect deny "linked worktree: the main checkout's decision does not carry over" "$W/.worktrees/fix/src/a.ts"

echo
((fails == 0)) && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
