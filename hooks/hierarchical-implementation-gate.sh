#!/usr/bin/env bash
# Hook and decision CLI behind the hierarchical-implementation skill. Implementation runs through
# worker subagents by default: the main thread briefs, reviews, sends corrections and integrates.
# So its first edit in a worktree under the implementation root is denied until the session records
# a decision: delegate, or direct with one of EXEMPTIONS. Coupling is not an exemption: a coupled
# change goes whole to one worker. Subagents are never gated (their hook input carries agent_id).
#
# Each decision is judged before the task's size shows, so each one is held to what it claims:
#   delegate   the driver edits only after it spawned a named worker that can edit (Explore and Plan
#              do not count), and only up to an integration budget of changed lines per worktree;
#              past that it is authoring, not integrating
#   trivial    one file, up to a cap of changed lines
#   security   only the files named when it was recorded
#   lane, opt-out, no-subagents   the whole worktree
# Changed lines are counted two ways on purpose. Trivial reads git's diff of its one file, which only
# the driver touches. Delegate sums the driver's own edit payloads, because workers edit the same
# worktree and git cannot tell their lines apart; an edit that later fails still counts.
#
# Before a tool runs (hooks/hooks.json lists which), the hook gates file edits and the shell writes
# shell_targets recognizes, approves this script's own decide command so recording costs no
# permission prompt, and requires a model on named workers in sessions it has seen. After an agent
# spawn or a message it logs the event to DELEGATION_EVENTS, which delegate and report read.
#
# It is a speed bump that makes skipping delegation a deliberate, logged act, not a barrier: a model
# set on getting around it can write files in ways it does not see.
#
# Only paths under HIERARCHICAL_GATE_ROOT (~/vscode, where implementation repos live) are gated.
# State lives under <state dir>/delegation/<session>/<digest of the worktree's git dir>, in files
# with the suffixes .decision (choice and reason), .trivial (the one file a trivial decision
# covers), .security (the files security decisions named) and .driver (the driver's changed lines
# under delegate). Recording again resets .trivial, adds to .security and keeps .driver, so a new
# delegate decision does not refill the budget. Each decision is appended to DELEGATION_LOG. The
# deny reason hands the model a command that contains the worktree path, so paths outside a plain
# character set are never gated. Fails open on any resolution error, including state it cannot
# write. HIERARCHICAL_GATE=off disables it. Written for bash 3.2, the macOS default.
#
#   hierarchical-implementation-gate.sh decide <worktree> <session> delegate "<units>"
#   hierarchical-implementation-gate.sh decide <worktree> <session> direct "<exemption>: <why>"
#   hierarchical-implementation-gate.sh decide <worktree> <session> direct "security: <why>" <file>...
#   hierarchical-implementation-gate.sh report

GIT_BIN="${GIT_BIN:-git}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-gates"
DELEGATION_LOG="${DELEGATION_LOG:-$STATE_DIR/delegation-decisions.tsv}"
DELEGATION_EVENTS="${DELEGATION_EVENTS:-$STATE_DIR/delegation-events.tsv}"
# A trivial change is one a driver would not brief a worker for; integration leaves room for review
# fixups and merge resolution, not for a unit's worth of new code.
TRIVIAL_MAX_LINES="${TRIVIAL_MAX_LINES:-20}"
INTEGRATE_MAX_LINES="${INTEGRATE_MAX_LINES:-60}"
MAX_TARGETS=20 # distinct files one shell command may write; more is denied, which bounds the hook's run time
EXEMPTIONS='trivial|security|lane|opt-out|no-subagents'
PLAIN_SET='[A-Za-z0-9._/@+-]'
SID_SET='[A-Za-z0-9-]'
PLAIN='^'$PLAIN_SET'+$'
SID='^'$SID_SET'+$'
NUM='^[0-9]+$'
WORDS='^[^[:space:]]+([[:space:]]+[^[:space:]]+){2,}'
# The only Bash command the hook approves: a decide call whose paths and ids use plain characters and
# whose reason is double-quoted text with nothing bash expands or ends a string on inside quotes.
DECIDE_ARGS='^'$PLAIN_SET'+ '$SID_SET'+ (delegate|direct) "[^"`$\\!]*"( '$PLAIN_SET'+)*$'
ASSIGN='^[A-Za-z_][A-Za-z0-9_]*='
FD_DUP='^([0-9]+-?|-)$'
SED_INPLACE='^-[a-zA-Z]*i'
US=$'\x1f'

git_() { # git without core.fsmonitor, which would run a command from a .git/config the gate cannot protect
  "$GIT_BIN" -c core.fsmonitor=false "$@"
}

repo_of() { # repo_of <dir>: sets top (the worktree root) and gitdir (its git dir) with one git call
  local out
  out=$(git_ -C "$1" rev-parse --show-toplevel --absolute-git-dir 2>/dev/null) || return 1
  top=${out%%$'\n'*}
  gitdir=${out#*$'\n'}
}

state_base() { # state_base <session> <git dir> -> <state dir>/delegation/<session>/<digest of the git dir>
  local h
  [[ $1 =~ $SID ]] || return 1
  h=$(printf '%s' "$2" | git_ hash-object --stdin 2>/dev/null) && [[ -n $h ]] || return 1
  printf '%s/delegation/%s/%s' "$STATE_DIR" "$1" "$h"
}

normalize() { # normalize <absolute path>: sets normalized to the path without . and .. segments, removed lexically the way the edit tools resolve them
  local rest=${1#/} part IFS=/
  local -a kept=()
  while [[ -n $rest ]]; do
    part=${rest%%/*}
    if [[ $rest == */* ]]; then rest=${rest#*/}; else rest=""; fi
    case $part in
      '' | .) ;;
      ..) ((${#kept[@]})) && unset "kept[${#kept[@]}-1]" ;;
      *) kept[${#kept[@]}]=$part ;;
    esac
  done
  normalized="/${kept[*]}"
}

resolve() { # resolve <path> <base dir>: sets path (absolute, normalized, existing directories and a symlinked file made physical) and real (its nearest existing directory)
  local p=$1 parent d link hops=0
  [[ $p == /* ]] || p="$2/$p"
  normalize "$p"
  p=$normalized
  while [[ -L $p && $hops -lt 8 ]]; do # an edit through a symlinked file lands on its target
    link=$(readlink "$p") || break
    [[ $link == /* ]] || link=${p%/*}/$link
    normalize "$link"
    p=$normalized
    hops=$((hops + 1))
  done
  parent=${p%/*}
  d=${parent:-/}
  while [[ ! -d $d ]]; do d=${d%/*}; d=${d:-/}; done
  real=$(cd "$d" && pwd -P) || return 1
  path="$real${parent#"$d"}/${p##*/}"
}

diff_lines() { # diff_lines <top> <file> -> lines added plus deleted against HEAD; an untracked file counts whole
  if git_ -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1; then
    git_ -C "$1" diff --numstat HEAD -- "$2" 2>/dev/null | awk '{n += $1 + $2} END {print n + 0}'
  elif [[ -f $2 ]]; then
    wc -l <"$2"
  else
    echo 0
  fi
}

worker_spawned() { # true when this session spawned a named agent that can edit
  awk -F'\t' -v s="$session" '$2 == s && $3 == "spawn" && $4 != "" && $6 != "Explore" && $6 != "Plan" {found = 1; exit} END {exit !found}' "$DELEGATION_EVENTS" 2>/dev/null
}

# The policy these texts state also lives in SKILL.md, README.md, examples/CLAUDE.md and the user's
# CLAUDE.md, and the test suite pins parts of it; change them together.
delegate_how() { # delegate_how <top>
  printf '%s' "run $0 decide $1 $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill (hierarchical-implementation:hierarchical-implementation when installed as a plugin), and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a named worker with model set, including the file in this edit. Review each result critically, send numbered corrections to the same worker with SendMessage or re-brief a fresh worker, stop after three rounds, and edit here only to integrate. While a /repro gate is open here, the worker works in this worktree."
}
direct_how() { # direct_how <top>
  printf '%s' "run $0 decide $1 $session direct \"<exemption>: <why, plain words>\" and retry; a security exemption also lists every file it covers after the reason, as paths relative to $1. Write reasons in plain words, without backticks, quotes, dollar signs, exclamation marks or backslashes"
}
instead_how() { # instead_how <top> -> the ways out of a trivial exemption the task outgrew
  printf '%s' "Delegate: $(delegate_how "$1") Or record a different exemption: $(direct_how "$1")"
}
EXEMPTION_TEXT="trivial (one file, a few lines; it covers one file and at most $TRIVIAL_MAX_LINES changed lines), security (the change edits the agent's own controls: hooks, gates, agent settings or permissions, CLAUDE.md, AGENTS.md, skill or agent definitions, or it handles secret values; it is never delegated and covers only the files you name; repo ownership, CI and IAM files are not in this class), lane (a coordinator session spawned this one to execute a unit it will review, and its brief does not set Lane mode: driver), opt-out (the user or the repo's rules say not to delegate), no-subagents (this harness has no subagent tool)"

gate() { # gate <file> <changed lines it adds> -> prints a deny reason, or nothing to allow
  local base top gitdir n
  [[ -n $1 ]] || return 0
  n=$2
  [[ $n =~ $NUM ]] || n=0
  resolve "$1" "$cwd" || return 0
  [[ $path == "$root"/* ]] || return 0
  if [[ $path == *$'\n'* ]]; then
    echo "The delegation gate cannot track a path with a newline in it, so it refuses edits to such paths under $root."
    return 0
  fi
  repo_of "$real" || return 0
  base=$(state_base "$session" "$gitdir") || return 0
  mkdir -p "${base%/*}" 2>/dev/null && [[ -w ${base%/*} ]] || return 0
  if ! [[ $top =~ $PLAIN && $0 =~ $PLAIN ]]; then
    echo "hierarchical-implementation gate: not gating $top, because it or $0 has characters outside the plain set" >&2
    return 0
  fi
  if [[ ! -f $base.decision ]]; then
    echo "Implementation runs through worker subagents by default, with the user's standing authorization for editing workers, so decide before the main thread edits $top. Delegate: $(delegate_how "$top") Work directly only when the whole task is one of these exemptions: $EXEMPTION_TEXT. Then $(direct_how "$top"). Do not edit through the shell to get around this."
    return 0
  fi
  scope "$base" "$top" "$n"
}

scope() { # scope <base> <top> <changed lines> -> prints a deny reason when the recorded decision does not cover this edit
  # Side effects: a trivial decision claims the first file it sees, and an allowed driver edit under
  # delegate is appended to the budget. Both writes are safe under parallel tool calls without a
  # lock: the claim is first-writer-wins, and a parallel batch can overshoot the budget only once.
  local base=$1 top=$2 n=$3 choice why used events_dir
  IFS=$'\t' read -r choice why <"$base.decision"
  case $choice:$why in
    delegate:*)
      events_dir=$(dirname "$DELEGATION_EVENTS")
      [[ -d $events_dir && -w $events_dir ]] || return 0
      if ! worker_spawned; then
        echo "This session recorded delegate for $top but has not spawned a named worker that can edit (Explore and Plan agents do not count), so there is nothing to integrate yet. Spawn the named workers with the Agent tool and model set first, then edit here only to integrate. If the task is in fact an exemption, $(direct_how "$top")."
        return 0
      fi
      used=$(awk '{n += $1} END {print n + 0}' "$base.driver" 2>/dev/null)
      [[ $used =~ $NUM ]] || used=0
      if ((used + n > INTEGRATE_MAX_LINES)); then
        echo "Under delegate the driver's own edits in $top would reach $((used + n)) changed lines, past the integration budget of $INTEGRATE_MAX_LINES: that is authoring, not integration. Send the change to the worker that owns the file with SendMessage, or spawn a worker for it. If the user asked you to finish it yourself, run $0 decide $top $session direct \"opt-out: <what the user said>\"."
      else
        echo "$n" >>"$base.driver"
      fi
      ;;
    direct:trivial:*)
      (set -C && printf '%s\n' "$path" >"$base.trivial") 2>/dev/null
      if ! grep -qxF -- "$path" "$base.trivial"; then
        echo "The trivial exemption recorded for $top covers one file and this edit is another, so the task is not trivial. $(instead_how "$top"). Do not edit through the shell to get around this."
        return 0
      fi
      n=$(($(diff_lines "$top" "$path") + n))
      ((n <= TRIVIAL_MAX_LINES)) ||
        echo "The trivial exemption covers a few lines, and this edit brings $path to about $n changed lines, past the cap of $TRIVIAL_MAX_LINES, so the task is not trivial. $(instead_how "$top")."
      ;;
    direct:security:*)
      grep -qxF -- "$path" "$base.security" 2>/dev/null ||
        echo "The security exemption recorded for $top covers only the files named when it was recorded, and $path is not one of them. If this file also edits the agent's own controls or handles secret values, add it: run $0 decide $top $session direct \"security: <why, plain words>\" <file>. Otherwise give it to a named worker with the Agent tool and model set; subagent edits are not gated, while recording delegate here would drop the security scope."
      ;;
    direct:*) ;; # lane, opt-out, no-subagents and reasons from older versions cover the whole worktree
  esac
}

own_decide() { # own_decide <command>: true when the command is exactly this script's decide call, with inert arguments, for the calling session
  local args=${1#"$0 decide "}
  [[ $0 =~ $PLAIN && $1 == "$0 decide "* && $1 != *$'\n'* && $args =~ $DECIDE_ARGS ]] || return 1
  args=${args#* }
  [[ ${args%% *} == "$session" ]]
}

_flush() { # ends the word shell_tokens is building; it shares shell_tokens' locals through bash's dynamic scope
  if ((has)); then
    if ((want_delim)); then
      delims[${#delims[@]}]=$w
      want_delim=0
    else
      printf "w$US%s$US%s\n" "$flags" "$w"
    fi
  fi
  w="" has=0 flags=""
}

shell_tokens() { # shell_tokens <command> -> one token per line: w US flags US word, o US operator, or h US heredoc body lines
  # Quotes and backslashes are removed from words. flags holds d when the word expands a variable
  # or a command, and t when it starts with an unquoted ~. Comments are dropped. Heredoc bodies are
  # skipped and reported as a line count before the newline that ends their command line.
  local LC_ALL=C line c op w="" has=0 flags="" q="" want_delim=0 cont li=0 j total d k
  local -a lines=() delims=()
  while IFS= read -r line; do lines[${#lines[@]}]=$line; done <<<"$1"
  while ((li < ${#lines[@]})); do
    line=${lines[li]}
    li=$((li + 1))
    cont=0
    for ((j = 0; j < ${#line}; j++)); do
      c=${line:j:1}
      if [[ $q == "'" ]]; then
        if [[ $c == "'" ]]; then q=""; else w+=$c; fi
        continue
      fi
      if [[ $q == '"' ]]; then
        case $c in
          '"') q="" ;;
          \\) j=$((j + 1)); w+=${line:j:1} ;;
          '$' | '`') flags+=d; w+=$c ;;
          *) w+=$c ;;
        esac
        continue
      fi
      case $c in
        ' ' | $'\t') _flush ;;
        "'" | '"') q=$c; has=1 ;;
        \\)
          ((j + 1 < ${#line})) || { cont=1; break; }
          j=$((j + 1)); w+=${line:j:1}; has=1
          ;;
        '#') if ((has)); then w+=$c; else break; fi ;;
        '~') ((has)) || flags+=t; w+=$c; has=1 ;;
        '$' | '`') flags+=d; w+=$c; has=1 ;;
        '|' | '&' | ';' | '(' | ')' | '<' | '>')
          # digits glued to a redirect are its file descriptor, not a word
          if [[ $c == [\<\>] && $has == 1 && -z $flags && $w =~ $NUM ]]; then w="" has=0; fi
          _flush
          op=$c
          case $c${line:j+1:1} in
            '||' | '&&' | ';;' | '>>' | '>&' | '>|' | '&>' | '|&' | '<<' | '<&' | '<>' | '((' | '))') op=$c${line:j+1:1}; j=$((j + 1)) ;;
          esac
          case $op${line:j+1:1} in
            '&>>' | '<<<' | '<<-') op+=${line:j+1:1}; j=$((j + 1)) ;;
          esac
          printf "o$US%s\n" "$op"
          [[ $op == '<<' || $op == '<<-' ]] && want_delim=1
          ;;
        *) w+=$c; has=1 ;;
      esac
    done
    if [[ -n $q ]]; then # a quoted string continues on the next line
      w+=' '
      continue
    fi
    _flush
    ((cont)) && continue # a trailing backslash joins the next line
    if ((${#delims[@]})); then
      total=0
      for d in "${delims[@]}"; do
        while ((li < ${#lines[@]})); do
          k=${lines[li]}
          li=$((li + 1))
          [[ ${k#"${k%%[!$'\t']*}"} == "$d" ]] && break
          total=$((total + 1))
        done
      done
      delims=()
      printf "h$US%s\n" "$total"
    fi
    printf "o${US}nl\n"
  done
}

expand_word() { # expand_word <word> <flags>: sets expanded to the path the shell would see, expanding only ~ and $HOME; fails on any other expansion
  local v=$1
  if [[ $2 == *t* ]]; then
    # shellcheck disable=SC2088 # the word holds a literal ~ that this function expands itself
    [[ $v == '~' || $v == '~/'* ]] || return 1
    v=$HOME${v#\~}
  fi
  if [[ $2 == *d* ]]; then
    case $v in
      '$HOME' | '$HOME/'*) v=$HOME${v#\$HOME} ;;
      '${HOME}' | '${HOME}/'*) v=$HOME${v#\$\{HOME\}} ;;
      *) return 1 ;;
    esac
    [[ $v != *[\$\`]* ]] || return 1
  fi
  [[ $v == /* ]] || v=$wd/$v
  expanded=$v
}

add_target() { # add_target <word> <flags>: records a file the current command line writes, once, up to MAX_TARGETS + 1 files
  local t i
  expand_word "$1" "$2" || return 0
  t=$expanded
  for ((i = 0; i < ${#files[@]}; i++)); do
    if [[ ${files[i]} == "$t" ]]; then
      line_files[${#line_files[@]}]=$i
      return 0
    fi
  done
  ((${#files[@]} > MAX_TARGETS)) && return 0
  files[${#files[@]}]=$t
  sizes[${#sizes[@]}]=0
  line_files[${#line_files[@]}]=$((${#files[@]} - 1))
}

shell_targets() { # shell_targets <command> -> "<heredoc lines> TAB <file>" for each distinct file the command writes
  # A command word is the first word after a separator, past VAR=value assignments and wrappers
  # such as sudo or xargs. Only tee, sed and perl in that position, or a redirect anywhere, write.
  # sed and perl write in place after a -i flag (not perl's -M or -I), and then every later word
  # naming an existing file is a target, which tells files apart from the script argument.
  local kind a b cmd="" mode="" expect="" cmp="" wd=$cwd t i
  local -a files=() sizes=() line_files=()
  while IFS=$US read -r kind a b; do
    case $kind in
      h)
        for i in "${line_files[@]}"; do sizes[i]=$((sizes[i] + a)); done
        continue
        ;;
      o)
        if [[ -n $cmp ]]; then # > inside [[ ]] or (( )) compares, it does not redirect
          [[ $cmp == arith && $a == '))' ]] && cmp=""
          continue
        fi
        case $a in
          '>' | '>>' | '>|' | '&>' | '&>>') expect='file' ;;
          '>&') expect='dup' ;;
          '<' | '<&' | '<>' | '<<<') expect='skip' ;;
          '<<' | '<<-') ;;
          '((') cmp='arith' ;;
          *)
            cmd="" mode="" expect=""
            [[ $a == nl ]] && line_files=()
            ;;
        esac
        continue
        ;;
    esac
    if [[ -n $cmp ]]; then
      [[ $cmp == test && $b == ']]' ]] && cmp=""
      continue
    fi
    if [[ -n $expect ]]; then
      t=$expect
      expect=""
      [[ $t == skip || ($t == dup && $b =~ $FD_DUP) ]] || add_target "$b" "$a"
      continue
    fi
    if [[ -z $cmd ]]; then
      [[ $b =~ $ASSIGN ]] && continue
      case ${b##*/} in sudo | env | command | nohup | time | exec | xargs | builtin) continue ;; esac
      cmd=${b##*/}
      case $cmd in
        tee | sed | perl | cd) mode=$cmd ;;
        '[[') cmp='test' ;;
        *) mode="" ;;
      esac
      continue
    fi
    case $mode in
      tee) [[ $b == -* ]] || add_target "$b" "$a" ;;
      sed) [[ $b == --in-place* || $b =~ $SED_INPLACE ]] && mode=inplace ;;
      perl) [[ $b =~ $SED_INPLACE && $b != -[MI]* ]] && mode=inplace ;;
      inplace) [[ $b != -* ]] && expand_word "$b" "$a" && [[ -f $expanded ]] && add_target "$b" "$a" ;;
      cd)
        expand_word "$b" "$a" && [[ -d $expanded ]] && wd=$expanded
        mode=""
        ;;
    esac
  done < <(shell_tokens "$1")
  for ((i = 0; i < ${#files[@]}; i++)); do printf '%s\t%s\n' "${sizes[i]}" "${files[i]}"; done
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
  repo_of "$repo" || { echo "not a git worktree: $repo" >&2; exit 1; }
  base=$(state_base "$session" "$gitdir") || { echo "not a session id: $session" >&2; exit 1; }
  [[ $top =~ $PLAIN ]] || { echo "this gate never asks about $top" >&2; exit 1; }
  named=()
  for f in "${files[@]}"; do
    resolve "$f" "$top" && [[ $path == "$top"/* && $path =~ $PLAIN ]] || { echo "not a plain path inside $top: $f" >&2; exit 1; }
    named[${#named[@]}]=$path
  done
  {
    mkdir -p "${base%/*}" "$(dirname "$DELEGATION_LOG")" &&
      printf '%s\t%s\n' "$choice" "$reason" >"$base.decision.new" &&
      mv -f "$base.decision.new" "$base.decision" &&
      rm -f "$base.trivial" &&
      { ((${#named[@]} == 0)) || printf '%s\n' "${named[@]}" >>"$base.security"; } &&
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$session" "$top" "$choice" "$reason" "${named[*]}" >>"$DELEGATION_LOG"
  } || { echo "could not record the decision under $STATE_DIR" >&2; exit 1; }
  case $choice:$reason in
    delegate:*) echo "recorded delegate: spawn the named workers; after that, this session's own edits in $top are limited to integration, $INTEGRATE_MAX_LINES changed lines in all" ;;
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
  awk -F'\t' -v ex="$EXEMPTIONS" '
    FILENAME == ARGV[1] {
      k = $4
      if (k == "direct") k = match($5, "^(" ex "):") ? substr($5, 1, RLENGTH - 1) : "direct"
      if (!($2 in kinds)) { order[++n] = $2; kinds[$2] = k }
      else if (index("+" kinds[$2] "+", "+" k "+") == 0) kinds[$2] = kinds[$2] "+" k
      next
    }
    $3 == "spawn" { spawns[$2]++ }
    $3 == "message" { messages[$2]++ }
    END {
      printf "%-36s  %-24s  %6s  %8s\n", "session", "decisions", "spawns", "messages"
      for (i = 1; i <= n; i++) { s = order[i]; printf "%-36s  %-24s  %6d  %8d\n", s, kinds[s], spawns[s], messages[s] }
    }' "$DELEGATION_LOG" "$events"
  exit 0
fi

[[ ${HIERARCHICAL_GATE:-on} == off ]] && exit 0

input=$(cat)
IFS=$US read -r agent event tool session cwd < <(jq -r '[.agent_id // "", .hook_event_name // "PreToolUse", .tool_name // "", .session_id // "", .cwd // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || exit 0
[[ -z $agent ]] || exit 0
cwd=${cwd:-$PWD}

if [[ $event == PostToolUse ]]; then
  case $tool in
    Agent | Task) kind=spawn ;;
    SendMessage) kind=message ;;
    *) exit 0 ;;
  esac
  [[ $session =~ $SID ]] || exit 0
  fields=$(jq -r '.tool_input | [.name // .to // "", .model // "", .subagent_type // ""] | map(tostring | gsub("[\\t\\n\\r]"; " ")) | join("\t")' <<<"$input" 2>/dev/null) || exit 0
  mkdir -p "$(dirname "$DELEGATION_EVENTS")" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$session" "$kind" "$fields" >>"$DELEGATION_EVENTS" 2>/dev/null
  exit 0
fi

root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || exit 0
reason=""
case $tool in
  Edit | Write | MultiEdit | NotebookEdit)
    file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$input" 2>/dev/null) || exit 0
    changed=$(jq -r '[.tool_input | .old_string, .new_string, .content, .new_source, (.edits[]? | .old_string, .new_string)] | map(select(type == "string") | split("\n") | length) | add // 0' <<<"$input" 2>/dev/null) || changed=0
    # replace_all changes every occurrence, so its size is one replacement times the occurrences
    old=$(jq -j 'if .tool_input.replace_all == true then .tool_input.old_string // "" else "" end' <<<"$input" 2>/dev/null)
    if [[ -n $old ]] && resolve "$file" "$cwd"; then
      content=$(cat "$path" 2>/dev/null)
      rest=${content//"$old"/}
      hits=$(((${#content} - ${#rest}) / ${#old}))
      ((hits > 1)) && changed=$((changed * hits))
    fi
    reason=$(gate "$file" "$changed")
    ;;
  Bash | Monitor)
    cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || exit 0
    if [[ $tool == Bash ]] && own_decide "$cmd" && jq -e '.tool_input.dangerouslyDisableSandbox != true' <<<"$input" >/dev/null 2>&1; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"records a hierarchical-implementation decision"}}'
      exit 0
    fi
    case $cmd in *'>'* | *tee* | *sed* | *perl*) ;; *) exit 0 ;; esac # nothing else the tokenizer recognizes can write
    count=0
    while IFS=$'\t' read -r size target; do
      [[ -n $target ]] || continue
      count=$((count + 1))
      if ((count > MAX_TARGETS)); then
        reason="This command writes more than $MAX_TARGETS files, more than the delegation gate checks in one command. Split it into smaller commands."
        break
      fi
      reason=$(gate "$target" "$size")
      [[ -z $reason ]] || { reason="This command writes $target, which the gate treats like an edit. $reason"; break; }
    done < <(shell_targets "$cmd")
    ;;
  Agent | Task)
    [[ $session =~ $SID && -d $STATE_DIR/delegation/$session ]] || exit 0
    jq -e '(.tool_input.name // "") != "" and (.tool_input.model // "") == "" and .tool_input.subagent_type != "fork"' <<<"$input" >/dev/null 2>&1 || exit 0
    reason="Set model on every named worker: the hierarchical-implementation skill passes the worker model explicitly (sonnet for editing workers unless the user chose another) instead of inheriting the main session's. Retry this call with model set."
    ;;
esac
[[ -z $reason ]] || jq -cn --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
