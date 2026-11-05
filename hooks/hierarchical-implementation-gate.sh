#!/usr/bin/env bash
# Hook and decision CLI behind the hierarchical-implementation skill. Implementation runs through
# worker subagents by default: the main thread briefs, reviews, sends corrections and integrates.
# So its first edit in a worktree under the implementation root is denied until the session records
# a decision: delegate, or direct with one of EXEMPTIONS. Coupling is not an exemption: a coupled
# change goes whole to one worker. Subagents are never gated (their hook input carries agent_id).
#
# Each decision is judged before the task's size shows, so each one is held to what it claims:
#   delegate   the driver edits only after a worker was spawned in this session, and only up to an
#              integration budget of changed lines per worktree; past that it is authoring
#   trivial    one file, up to a cap of changed lines
#   security   only the files named when it was recorded
#   lane, opt-out, no-subagents   the whole worktree
#
# PreToolUse on Edit|Write|MultiEdit|NotebookEdit gates edits. On Bash it approves this script's own
# decide command, so recording costs no permission prompt, and applies the same gate to files a
# command writes through >, >>, tee, sed -i or perl -i; other shell writes are not recognized. On
# Agent|Task it requires model on named workers. PostToolUse on Agent|Task|SendMessage logs spawns
# and messages to DELEGATION_EVENTS, which the delegate rule and the report command read.
#
# Only paths under HIERARCHICAL_GATE_ROOT (~/vscode, where implementation repos live) are gated.
# State is keyed by session and worktree under the state dir; each decision is appended to
# DELEGATION_LOG for review. The deny reason hands the model a command that contains the worktree
# path, so paths outside a plain character set are never gated. Fails open on any resolution error,
# including a state dir it cannot write. HIERARCHICAL_GATE=off disables the guard.
#
#   hierarchical-implementation-gate.sh decide <worktree> <session> delegate "<units>"
#   hierarchical-implementation-gate.sh decide <worktree> <session> direct "<exemption>: <why>"
#   hierarchical-implementation-gate.sh decide <worktree> <session> direct "security: <why>" <file>...
#   hierarchical-implementation-gate.sh report

GIT_BIN="${GIT_BIN:-git}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-gates"
DELEGATION_LOG="${DELEGATION_LOG:-$STATE_DIR/delegation-decisions.tsv}"
DELEGATION_EVENTS="${DELEGATION_EVENTS:-$STATE_DIR/delegation-events.tsv}"
TRIVIAL_MAX_LINES="${TRIVIAL_MAX_LINES:-20}"
INTEGRATE_MAX_LINES="${INTEGRATE_MAX_LINES:-60}"
EXEMPTIONS='trivial|security|lane|opt-out|no-subagents'
PLAIN='^[A-Za-z0-9._/@+-]+$'
SID='^[A-Za-z0-9-]+$'
WORDS='^[^[:space:]]+([[:space:]]+[^[:space:]]+){2,}'
DECIDE_ARGS='^[A-Za-z0-9._/@+-]+ [A-Za-z0-9-]+ (delegate|direct) "[^"`$\\!]*"( [A-Za-z0-9._/@+-]+)*$'
REDIRECT='^([0-9]*|&)(>>?)(.*)$'

state_base() { # state_base <session> <path-in-worktree> -> <state dir>/delegation/<session>/<digest of the worktree git dir>
  local d h
  [[ $1 =~ $SID ]] || return 1
  d=$("$GIT_BIN" -C "$2" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  h=$(printf '%s' "$d" | "$GIT_BIN" hash-object --stdin 2>/dev/null) && [[ -n $h ]] || return 1
  printf '%s/delegation/%s/%s' "$STATE_DIR" "$1" "$h"
}

resolve() { # resolve <path> <base dir>: sets path (absolute, existing directories made physical) and real (its nearest existing directory)
  local p=$1 parent d
  [[ $p == /* ]] || p="$2/$p"
  parent=$(dirname "$p")
  d=$parent
  while [[ ! -d $d && $d != / ]]; do d=$(dirname "$d"); done
  real=$(cd "$d" && pwd -P) || return 1
  path="$real${parent#"$d"}/$(basename "$p")"
}

diff_lines() { # diff_lines <top> <file> -> lines added plus deleted against HEAD; an untracked file counts whole
  if "$GIT_BIN" -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1; then
    "$GIT_BIN" -C "$1" diff --numstat HEAD -- "$2" 2>/dev/null | awk '{n += $1 + $2} END {print n + 0}'
  elif [[ -f $2 ]]; then
    wc -l <"$2"
  else
    echo 0
  fi
}

# The policy these texts enforce is the When to Use Agents row in CLAUDE.md; change both together.
delegate_how() { # delegate_how <top>
  printf '%s' "run $0 decide $1 $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill, and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a named worker with model set, including the file in this edit. Review each result critically, send numbered corrections to the same worker with SendMessage or re-brief a fresh worker, stop after three rounds, and edit here only to integrate. While a /repro gate is open here, the worker works in this worktree."
}
direct_how() { # direct_how <top>
  printf '%s' "run $0 decide $1 $session direct \"<exemption>: <why, plain words>\" and retry; a security exemption also lists every file it covers after the reason, as paths relative to $1"
}
EXEMPTION_TEXT="trivial (one file, a few lines; it covers one file and at most $TRIVIAL_MAX_LINES changed lines), security (the change edits the agent's own controls: hooks, gates, agent settings or permissions, CLAUDE.md, AGENTS.md, skill or agent definitions, or it handles secret values; it is never delegated and covers only the files you name; repo ownership, CI and IAM files are not in this class), lane (a coordinator session spawned this one to execute a unit it will review), opt-out (the user or the repo's rules say not to delegate), no-subagents (this harness has no subagent tool)"

gate() { # gate <file> <changed lines this edit adds> -> prints a deny reason, or nothing to allow
  local root base top choice why n
  [[ -n $1 && $1 != *$'\n'* ]] || return 0
  resolve "$1" "$cwd" || return 0
  root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || return 0
  [[ $path == "$root"/* ]] || return 0
  base=$(state_base "$session" "$real") || return 0
  mkdir -p "$(dirname "$base")" 2>/dev/null && [[ -w $(dirname "$base") ]] || return 0
  top=$("$GIT_BIN" -C "$real" rev-parse --show-toplevel 2>/dev/null) || return 0
  [[ $top =~ $PLAIN && $0 =~ $PLAIN ]] || return 0
  if [[ ! -f $base.decision ]]; then
    echo "Implementation runs through worker subagents by default, with the user's standing authorization for editing workers, so decide before the main thread edits $top. Delegate: $(delegate_how "$top") Work directly only when the whole task is one of these exemptions: $EXEMPTION_TEXT. Then $(direct_how "$top"). Write reasons in plain words, without backticks, quotes or dollar signs. Do not edit through the shell to get around this."
    return 0
  fi
  IFS=$'\t' read -r choice why <"$base.decision"
  case $choice:$why in
    delegate:*)
      if ! grep -qF -e "$(printf '\t%s\tspawn\t' "$session")" "$DELEGATION_EVENTS" 2>/dev/null; then
        echo "This session recorded delegate for $top but has not spawned a worker, so there is nothing to integrate yet. Spawn the named workers with the Agent tool and model set first, then edit here only to integrate. If the task is in fact an exemption, $(direct_how "$top")."
        return 0
      fi
      n=$(($(cat "$base.driver" 2>/dev/null || echo 0) + $2))
      if ((n > INTEGRATE_MAX_LINES)); then
        echo "Under delegate the driver's own edits in $top would reach $n changed lines, past the integration budget of $INTEGRATE_MAX_LINES: that is authoring, not integration. Send the change to the worker that owns the file with SendMessage, or spawn a worker for it. If the user asked you to finish it yourself, run $0 decide $top $session direct \"opt-out: <what the user said>\"."
      else
        echo "$n" >"$base.driver"
      fi
      ;;
    direct:trivial:*)
      [[ -s $base.trivial ]] || printf '%s\n' "$path" >"$base.trivial"
      if ! grep -qxF -- "$path" "$base.trivial"; then
        echo "The trivial exemption recorded for $top covers one file and this edit is another, so the task is not trivial. Delegate: $(delegate_how "$top") Or record a different exemption: $(direct_how "$top"). Do not edit through the shell to get around this."
        return 0
      fi
      n=$(($(diff_lines "$top" "$path") + $2))
      ((n <= TRIVIAL_MAX_LINES)) ||
        echo "The trivial exemption covers a few lines, and this edit brings $path to about $n changed lines, past the cap of $TRIVIAL_MAX_LINES, so the task is not trivial. Delegate: $(delegate_how "$top") Or record a different exemption: $(direct_how "$top")."
      ;;
    direct:security:*)
      grep -qxF -- "$path" "$base.files" 2>/dev/null ||
        echo "The security exemption recorded for $top covers only the files named when it was recorded, and $path is not one of them. If this file also edits the agent's own controls or handles secret values, add it: run $0 decide $top $session direct \"security: <why, plain words>\" <file>. Otherwise delegate it: $(delegate_how "$top")"
      ;;
  esac
}

own_decide() { # own_decide <command>: true when the command is exactly this script's decide call with inert arguments
  [[ $0 =~ $PLAIN && $1 == "$0 decide "* && $1 != *$'\n'* && ${1#"$0 decide "} =~ $DECIDE_ARGS ]]
}

shell_targets() { # shell_targets <command> -> files the command writes through >, >>, tee, sed -i or perl -i, one per line
  local line w t q="" mode i
  local -a words
  while IFS= read -r line; do
    read -r -a words <<<"$line"
    mode=""
    for ((i = 0; i < ${#words[@]}; i++)); do
      w=${words[i]}
      if [[ -n $q ]]; then
        [[ $w == *"$q" ]] && q=""
        continue
      fi
      if [[ $w == [\"\']* && (${#w} -eq 1 || $w != *"${w:0:1}") ]]; then
        q=${w:0:1}
        continue
      fi
      w=${w//[\"\']/}
      case $w in
        '|' | '||' | '&&' | ';' | '&') mode="" ;;
        tee | sed | perl) mode=$w ;;
        *)
          if [[ $w =~ $REDIRECT ]]; then
            t=${BASH_REMATCH[3]#|}
            [[ -n $t ]] || { t=${words[i + 1]:-}; i=$((i + 1)); }
            t=${t//[\"\']/}
            [[ -z $t || $t == '&'* ]] || echo "$t"
            continue
          fi
          case $mode in
            tee) [[ $w == -* ]] || echo "$w" ;;
            sed) [[ $w == --in-place* || $w =~ ^-[a-zA-Z]*i ]] && mode=inplace ;;
            perl) [[ $w =~ ^-[a-zA-Z]*i ]] && mode=inplace ;;
            inplace) [[ $w != -* && (-f $w || -f $cwd/$w) ]] && echo "$w" ;;
          esac
          ;;
      esac
    done
    [[ $line == *'<<'* ]] && break
  done <<<"$1"
}

if [[ ${1:-} == decide ]]; then
  repo="${2:-.}" session=${3:-} choice=${4:-} reason=${5:-}
  files=("${@:6}")
  repo="${repo/#\~/$HOME}"
  reason=${reason//[[:cntrl:]]/ }
  ok=0 needs_files=0
  case $choice in
    delegate) [[ $reason =~ $WORDS ]] && ok=1 ;;
    direct) [[ $reason =~ ^($EXEMPTIONS):[[:space:]]+(.*)$ && ${BASH_REMATCH[2]} =~ $WORDS ]] && ok=1 ;;
  esac
  [[ $choice == direct && $reason == security:* ]] && needs_files=1
  ((ok && (${#files[@]} > 0) == needs_files)) || {
    echo "usage: $0 decide <worktree> <session> delegate \"<units, three or more words>\"" >&2
    echo "   or: $0 decide <worktree> <session> direct \"<trivial, lane, opt-out, no-subagents>: <why, three or more words>\"" >&2
    echo "   or: $0 decide <worktree> <session> direct \"security: <why, three or more words>\" <file>..." >&2
    exit 1
  }
  base=$(state_base "$session" "$repo") || { echo "not a session id and git worktree: $session $repo" >&2; exit 1; }
  top=$("$GIT_BIN" -C "$repo" rev-parse --show-toplevel)
  [[ $top =~ $PLAIN ]] || { echo "this gate never asks about $top" >&2; exit 1; }
  named=()
  for f in "${files[@]}"; do
    resolve "$f" "$top" && [[ $path == "$top"/* && $path =~ $PLAIN ]] || { echo "not a plain path inside $top: $f" >&2; exit 1; }
    named+=("$path")
  done
  {
    mkdir -p "$(dirname "$base")" "$(dirname "$DELEGATION_LOG")" &&
      printf '%s\t%s\n' "$choice" "$reason" >"$base.decision" &&
      { ((${#named[@]} == 0)) || printf '%s\n' "${named[@]}" >>"$base.files"; } &&
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$session" "$top" "$choice" "$reason" "${named[*]}" >>"$DELEGATION_LOG"
  } || { echo "could not record the decision under $STATE_DIR" >&2; exit 1; }
  case $choice:$reason in
    delegate:*) echo "recorded delegate: spawn the workers; after that, this session's edits in $top are limited to integration ($INTEGRATE_MAX_LINES changed lines)" ;;
    direct:trivial:*) echo "recorded direct (trivial): one file in $top, up to $TRIVIAL_MAX_LINES changed lines, is no longer gated" ;;
    direct:security:*) echo "recorded direct (security): ${#named[@]} named file(s) in $top are no longer gated" ;;
    *) echo "recorded $choice: this session's edits in $top are no longer gated" ;;
  esac
  exit 0
fi

if [[ ${1:-} == report ]]; then
  [[ -f $DELEGATION_LOG ]] || { echo "no decisions recorded in $DELEGATION_LOG" >&2; exit 1; }
  events=$DELEGATION_EVENTS
  [[ -f $events ]] || events=/dev/null
  awk -F'\t' '
    FNR == NR { seen[$2] = 1; kind[$2] = (kind[$2] == "" || kind[$2] == $4) ? $4 : "mixed"; next }
    $3 == "spawn" { spawns[$2]++ }
    $3 == "message" { messages[$2]++ }
    END {
      printf "%-36s  %-8s  %6s  %8s\n", "session", "decision", "spawns", "messages"
      for (s in seen) printf "%-36s  %-8s  %6d  %8d\n", s, kind[s], spawns[s], messages[s]
    }' "$DELEGATION_LOG" "$events"
  exit 0
fi

[[ ${HIERARCHICAL_GATE:-on} == off ]] && exit 0

input=$(cat)
[[ -z $(jq -r '.agent_id // empty' <<<"$input" 2>/dev/null) ]] || exit 0
IFS=$'\x1f' read -r event tool session cwd < <(jq -r '[.hook_event_name // "PreToolUse", .tool_name // "", .session_id // "", .cwd // ""] | join("\u001f")' <<<"$input" 2>/dev/null) || exit 0
cwd=${cwd:-$PWD}

if [[ $event == PostToolUse ]]; then
  case $tool in
    Agent | Task) kind=spawn ;;
    SendMessage) kind=message ;;
    *) exit 0 ;;
  esac
  [[ $session =~ $SID ]] || exit 0
  fields=$(jq -r '.tool_input | [.name // .to // .description // "", .model // "", .subagent_type // ""] | map(tostring | gsub("[\\t\\n\\r]"; " ")) | join("\t")' <<<"$input" 2>/dev/null) || exit 0
  mkdir -p "$(dirname "$DELEGATION_EVENTS")" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$session" "$kind" "$fields" >>"$DELEGATION_EVENTS" 2>/dev/null
  exit 0
fi

reason=""
case $tool in
  Edit | Write | MultiEdit | NotebookEdit)
    file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$input" 2>/dev/null) || exit 0
    lines=$(jq -r '[.tool_input | .old_string, .new_string, .content, .new_source, (.edits[]? | .old_string, .new_string)] | map(select(type == "string") | split("\n") | length) | add // 0' <<<"$input" 2>/dev/null) || lines=0
    reason=$(gate "$file" "${lines:-0}")
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || exit 0
    if own_decide "$cmd"; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"records a hierarchical-implementation decision"}}'
      exit 0
    fi
    while IFS= read -r target; do
      reason=$(gate "$target" 0)
      [[ -z $reason ]] || { reason="This command writes $target, which the gate treats like an edit. $reason"; break; }
    done < <(shell_targets "$cmd")
    ;;
  Agent | Task)
    jq -e '(.tool_input.name // "") != "" and (.tool_input.model // "") == "" and .tool_input.subagent_type != "fork"' <<<"$input" >/dev/null 2>&1 || exit 0
    reason="Set model on every named worker: the hierarchical-implementation skill passes the worker model explicitly (sonnet for editing workers unless the user chose another) instead of inheriting the main session's. Retry this call with model set."
    ;;
esac
[[ -z $reason ]] || jq -cn --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
