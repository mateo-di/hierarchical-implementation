#!/usr/bin/env bash
# PreToolUse guard (Edit|Write|MultiEdit|NotebookEdit) and the decision CLI behind the
# hierarchical-implementation skill. Implementation runs through worker subagents by default:
# the main thread briefs, reviews, sends corrections and integrates. So its first edit in a
# worktree under the implementation root is denied until the session records a decision:
# delegate, or direct with one of EXEMPTIONS. Coupling is not an exemption: a coupled change
# goes whole to one worker. A trivial exemption covers one file, because it is judged at the
# first edit, before the task's size shows. Subagents are not gated (their hook input carries
# agent_id); a delegate decision lifts the gate for the driver too, because it integrates.
#
# Only paths under HIERARCHICAL_GATE_ROOT (~/vscode, where implementation repos live) are gated.
# State is keyed by session and worktree under the state dir; each decision is appended to
# DELEGATION_LOG (time, session, worktree, choice, reason) for review. The deny reason names the
# session, so the decision lands where the hook looks. The deny reason hands the model a command
# that contains the worktree path, so paths outside a plain character set are never gated.
# Shell-based edits are not intercepted. Fails open on any resolution error, including a state
# dir it cannot write, since a decision could not be recorded there.
# HIERARCHICAL_GATE=off disables the guard.
#
#   hierarchical-implementation-gate.sh decide <worktree> <session> delegate "<units>"
#   hierarchical-implementation-gate.sh decide <worktree> <session> direct "<exemption>: <why>"

GIT_BIN="${GIT_BIN:-git}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-gates"
DELEGATION_LOG="${DELEGATION_LOG:-$STATE_DIR/delegation-decisions.tsv}"
EXEMPTIONS='trivial|security|lane|opt-out|no-subagents'
PLAIN='^[A-Za-z0-9._/@+-]+$'
WORDS='^[^[:space:]]+([[:space:]]+[^[:space:]]+){2,}'

state_base() { # state_base <session> <path-in-worktree> -> <state dir>/delegation/<session>/<digest of the worktree git dir>
  local d h
  [[ $1 =~ ^[A-Za-z0-9-]+$ ]] || return 1
  d=$("$GIT_BIN" -C "$2" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  h=$(printf '%s' "$d" | "$GIT_BIN" hash-object --stdin 2>/dev/null) && [[ -n $h ]] || return 1
  printf '%s/delegation/%s/%s' "$STATE_DIR" "$1" "$h"
}

if [[ ${1:-} == decide ]]; then
  repo="${2:-.}" session=${3:-} choice=${4:-} reason=${5:-}
  repo="${repo/#\~/$HOME}"
  reason=${reason//[[:cntrl:]]/ }
  case $choice in
    delegate) [[ $reason =~ $WORDS ]] ;;
    direct) [[ $reason =~ ^($EXEMPTIONS):[[:space:]]+(.*)$ && ${BASH_REMATCH[2]} =~ $WORDS ]] ;;
    *) false ;;
  esac || {
    echo "usage: $0 decide <worktree> <session> delegate \"<units, three or more words>\"" >&2
    echo "   or: $0 decide <worktree> <session> direct \"<${EXEMPTIONS//|/, }>: <why, three or more words>\"" >&2
    exit 1
  }
  base=$(state_base "$session" "$repo") || { echo "not a session id and git worktree: $session $repo" >&2; exit 1; }
  top=$("$GIT_BIN" -C "$repo" rev-parse --show-toplevel)
  [[ $top =~ $PLAIN ]] || { echo "this gate never asks about $top" >&2; exit 1; }
  if ! mkdir -p "$(dirname "$base")" "$(dirname "$DELEGATION_LOG")" ||
    ! printf '%s\t%s\n' "$choice" "$reason" >"$base.decision" ||
    ! printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$session" "$top" "$choice" "$reason" >>"$DELEGATION_LOG"; then
    echo "could not record the decision under $STATE_DIR" >&2
    exit 1
  fi
  [[ $reason == trivial:* ]] && echo "recorded direct (trivial): one file in $top is no longer gated" ||
    echo "recorded $choice: this session's edits in $top are no longer gated"
  exit 0
fi

[[ ${HIERARCHICAL_GATE:-on} == off ]] && exit 0

input=$(cat)
[[ -z $(jq -r '.agent_id // empty' <<<"$input" 2>/dev/null) ]] || exit 0
session=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || exit 0
path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$input" 2>/dev/null) || exit 0
[[ -n $path && $path != *$'\n'* ]] || exit 0
if [[ $path != /* ]]; then
  cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null)
  path="${cwd:-$PWD}/$path"
fi

parent=$(dirname "$path")
d=$parent
while [[ ! -d $d && $d != / ]]; do d=$(dirname "$d"); done
real=$(cd "$d" && pwd -P) || exit 0
path="$real${parent#"$d"}/$(basename "$path")"
root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || exit 0
[[ $path == "$root"/* ]] || exit 0
base=$(state_base "$session" "$real") || exit 0
mkdir -p "$(dirname "$base")" 2>/dev/null && [[ -w $(dirname "$base") ]] || exit 0
trivial=""
if [[ -f $base.decision ]]; then
  [[ $(cut -f2 "$base.decision") == trivial:* ]] || exit 0
  grep -qxF -- "$path" "$base.trivial" 2>/dev/null && exit 0
  [[ -s $base.trivial ]] || { printf '%s\n' "$path" >"$base.trivial"; exit 0; }
  trivial=1
fi

top=$("$GIT_BIN" -C "$real" rev-parse --show-toplevel 2>/dev/null) || exit 0
[[ $top =~ $PLAIN && $0 =~ $PLAIN ]] || exit 0
delegate="run $0 decide $top $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill, and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a named worker, including the file in this edit. Review each result yourself, send corrections to the same worker with SendMessage, stop after three rounds, and edit here only to integrate. While a /repro gate is open here, the worker works in this worktree."
# The policy this text enforces is the When to Use Agents row in CLAUDE.md; change both together.
if [[ -n $trivial ]]; then
  reason="The trivial exemption recorded for $top covers one file and this edit is another, so the task is not trivial. Delegate: $delegate Or record a different exemption: run $0 decide $top $session direct \"<exemption>: <why, plain words>\". Do not edit through the shell to get around this."
else
  reason="Implementation runs through worker subagents by default, with the user's standing authorization for editing workers, so decide before the main thread edits $top. Delegate: $delegate Work directly only when the whole task is one of these exemptions: trivial (one file, a few lines; it covers one file), security (a security, credential, permission, hook, gate, settings or CLAUDE.md change, which is never delegated), lane (a coordinator session spawned this one to execute a unit it will review), opt-out (the user or the repo's rules say not to delegate), no-subagents (this harness has no subagent tool). Then run $0 decide $top $session direct \"<exemption>: <why, plain words>\" and retry this edit. Write reasons in plain words, without backticks, quotes or dollar signs. Do not edit through the shell to get around this."
fi
jq -cn --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
