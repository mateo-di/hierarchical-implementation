#!/usr/bin/env bash
# Hook and decision CLI behind the hierarchical-implementation skill. Implementation runs through
# worker subagents by default: the main thread briefs, reviews, sends corrections and integrates.
# So its first edit in a worktree under the implementation root is denied until the session records
# a decision: delegate, or direct with one of EXEMPTIONS. So is its first worker (the plugin's worker
# agent or a free-model run) while it works in such a worktree, since a driver that only reviews
# may never edit. Coupling is not an exemption: a coupled change goes whole to one worker.
# Subagents are never gated (their hook input carries agent_id).
#
# Each decision is judged before the task's size shows, so each one is held to what it claims:
#   delegate   the driver edits only after it spawned a worker (a named agent of WORKER_TYPES, or a
#              free-models.sh run) since its first delegate decision in the worktree, and only up to
#              an integration budget of changed lines per worktree; past that it is authoring
#   trivial    up to TRIVIAL_MAX_FILES files and a cap of changed lines in all
#   security   only the files named when it was recorded, each an agent-control or secrets path,
#              checked again at each edit because decide runs in an environment the model sets
#   lane       the whole worktree, only in a session started with LANE_MODE=unit
#   opt-out, no-subagents   the whole worktree
# Both line caps sum the lines the driver's own edits change, so neither a commit nor recording
# again resets them; an edit that later fails still counts. Trivial also reads git's diff of its files and takes
# the larger count, which catches shell writes whose size the hook cannot see. Delegate cannot use
# the diff, because workers edit the same worktree and git cannot tell their lines apart.
#
# Before a tool runs (hooks/hooks.json lists which), the hook gates file edits and the shell writes
# shell_targets recognizes, approves this script's own decide command so recording costs no
# permission prompt, holds worker spawns to a decision, and requires a model on named workers in
# sessions it has seen, unless CLAUDE_CODE_SUBAGENT_MODEL_FORCE is on: then the harness picks every
# subagent's model and the Agent tool takes none. With HI_FREE_WORKERS=1 it holds the plugin's
# worker on sonnet until a free-model run for its unit was logged, and at SessionStart it tells the
# session that free-model workers are on. After an agent spawn or a message, or a Bash call that
# runs the skill's free-model worker (free-models.sh run), it logs the event to DELEGATION_EVENTS,
# with the model the spawn resolved to when the harness reports one, which delegate and report
# read; each denial is logged there too, with the tool and a kind.
#
# It is a speed bump that makes skipping delegation a deliberate, logged act, not a barrier: a model
# set on getting around it can write files in ways it does not see.
#
# Only paths under HIERARCHICAL_GATE_ROOT (~/vscode, where implementation repos live) are gated.
# State lives under <state dir>/delegation/<session>/<digest of the worktree's git dir>, in files
# with the suffixes .decision (choice and reason), .trivial.<n> (one file each that a trivial
# decision covers), .trivial-lines (its changed lines), .security (the files security decisions
# named), .since (when delegate was first recorded) and .driver (the driver's changed lines under
# delegate). Recording again frees the .trivial.<n> files for a new task, adds to .security and
# keeps the rest, so it refills no line count. Each decision is appended to DELEGATION_LOG. The
# deny reason hands the model a command that contains the worktree path, so paths outside a plain
# character set are never gated. Fails open on any resolution error, including state it cannot
# write. HIERARCHICAL_GATE=off disables it. Written for bash 3.2, the macOS default.
#
#   hierarchical-implementation-gate.sh [--harness <claude|agy|codex|gemini|cursor|opencode|omp|pi|generic>]
#   hierarchical-implementation-gate.sh decide <worktree> <session> delegate "<units>"
#   hierarchical-implementation-gate.sh decide <worktree> <session> direct "<exemption>: <why>"
#   hierarchical-implementation-gate.sh decide <worktree> <session> direct "security: <why>" <file>...
#   hierarchical-implementation-gate.sh report

HARNESS="${HIERARCHICAL_GATE_HARNESS:-claude}"
if [[ ${1:-} == --harness ]]; then
  HARNESS="${2:-claude}"
  shift 2 2>/dev/null || shift $#
fi
SELF=$0
SELF_ABS=$(cd "$(dirname "$0")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$0")") || SELF_ABS=$0
if [[ $HARNESS != claude && $SELF != /* && -n $SELF_ABS ]]; then
  SELF=$SELF_ABS
fi

GIT_BIN="${GIT_BIN:-git}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-gates"
DELEGATION_LOG="${DELEGATION_LOG:-$STATE_DIR/delegation-decisions.tsv}"
DELEGATION_EVENTS="${DELEGATION_EVENTS:-$STATE_DIR/delegation-events.tsv}"
# A trivial change is one a driver would not brief a worker for: a worker starts with tens of
# thousands of tokens of context and rereads what the driver already read, which a change of a few
# files and lines never repays. Integration leaves room for review fixups and merge resolution, not
# for a unit's worth of new code.
TRIVIAL_MAX_LINES="${TRIVIAL_MAX_LINES:-60}"
TRIVIAL_MAX_FILES="${TRIVIAL_MAX_FILES:-3}"
INTEGRATE_MAX_LINES="${INTEGRATE_MAX_LINES:-60}"
# The limits reach bash arithmetic, which would run a command substitution inside a variable's value
# and read a leading zero as octal. The file count is kept small: each file costs forks per edit.
[[ $TRIVIAL_MAX_LINES =~ ^(0|[1-9][0-9]{0,4})$ ]] || TRIVIAL_MAX_LINES=60
[[ $TRIVIAL_MAX_FILES =~ ^[1-9][0-9]?$ ]] || TRIVIAL_MAX_FILES=3
[[ $INTEGRATE_MAX_LINES =~ ^(0|[1-9][0-9]{0,4})$ ]] || INTEGRATE_MAX_LINES=60
# Paths, relative to the worktree, a security decision may name: the agent's instructions, settings
# and hooks (also as chezmoi sources, with chezmoi's exact_, private_ and readonly_ prefixes), skill
# definitions, and files that hold secrets: data and config files whose name or directory says so,
# not the code that handles them. CI, ownership and IAM files are not among them. A plugin's hooks,
# skills, agents, commands and adapters are controls too; security_path checks those in code.
SECURITY_PATHS="${SECURITY_PATHS:-(^|/)(CLAUDE|AGENTS|GEMINI)(\.local)?\.md(\.tmpl)?$|(^|/)SKILL\.md$|(^|/)((exact|private|readonly)_)*(dot_|\.)(claude|claude-plugin|codex|codex-plugin|opencode|cursor|cursor-plugin|gemini|gemini-plugin|antigravity-plugin|omp|omp-plugin|pi|agents)(/|$)|(^|/)((exact|private|readonly)_)*(dot_config|\.config)/((exact|private|readonly)_)*(claude|codex|opencode|omp|pi|cursor|gemini)(/|$)|(^|/)\.chezmoitemplates/[^/]*(claude|codex|opencode|omp|gemini)|(^|/)(opencode\.jsonc?|\.mcp\.json|gemini-extension\.json)$|(^|/)\.env(\.[^/]*)?$|(^|/)([^/]*[._-])?(secrets?|credentials?|keychain)([_-][^/.]*)?(\.(ya?ml|json|toml|ini|conf|cfg|properties|txt|enc|age|gpg))?$|(^|/)(secrets?|credentials?)/([^/]+/)*[^/]+\.(ya?ml|json|toml|ini|conf|cfg|properties|txt|enc|age|gpg)$|\.(pem|key|p12)$}"
# Agent types that count as an editing worker under delegate; a named agent with no type is the
# default general-purpose agent. worker is the plugin's agent copied into ~/.claude/agents, and
# free-models is the type this hook logs for a free-models.sh run, so an override keeps it.
# Specialists that only read, plan or keep records do not count.
WORKER_TYPES="${WORKER_TYPES:-general-purpose|worker|hierarchical-implementation:worker|fork|free-models|self|general|task|subagent|coding|default|swarm}"
# The worker types that exist only to edit a unit, so a spawn of one starts a delegated task and
# needs a decision first; general-purpose agents and forks also research and review. Written
# folded the way Claude Code matches a subagent_type: lowercase, without spaces, dashes or
# underscores.
UNIT_WORKER_TYPES='worker|hierarchicalimplementation:worker'
MAX_TARGETS=20 # distinct files one shell command may write; more is denied, which bounds the hook's run time
EXEMPTIONS='trivial|security|lane|opt-out|no-subagents'
PLAIN_SET='[A-Za-z0-9._/@+-]'
SID_SET='[A-Za-z0-9_-]'
PLAIN='^'$PLAIN_SET'+$'
SID='^'$SID_SET'+$'
NUM='^[0-9]+$'
WORDS='^[^[:space:]]+([[:space:]]+[^[:space:]]+){2,}'
# The only Bash command the hook approves: a decide call whose paths and ids use plain characters and
# whose reason is double-quoted text with nothing bash expands or ends a string on inside quotes.
DECIDE_ARGS='^'$PLAIN_SET'+ '$SID_SET'+ (delegate|direct) "[^"`$\\!]*"( '$PLAIN_SET'+)*$'
ASSIGN='^[A-Za-z_][A-Za-z0-9_]*='
# The skill's free-model worker as the whole command:
#   [VAR=value ...] ["][dir/]free-models.sh["] run [--model <id>] <worktree> <name> <brief> [session] [redirections]
# Anchored at both ends, with no ; & | < > ( ) or backtick inside an argument, so a mention of the
# script (echo, grep, a commit message), a chained command or a substitution is not read as a spawn.
# Groups: 4 model, 5 name, 7 session.
FREE_ARG='[^[:space:];&|<>()`]+'
FREE_RUN='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*='$FREE_ARG'[[:space:]]+)*"?([^[:space:]";&|<>]*/)?free-models\.sh"?[[:space:]]+run([[:space:]]+--model[[:space:]]+('$FREE_ARG'))?[[:space:]]+'$FREE_ARG'[[:space:]]+('$FREE_ARG')[[:space:]]+'$FREE_ARG'([[:space:]]+('$FREE_ARG'))?([[:space:]]+[0-9]*>>?[[:space:]]*(&[0-9]+|'$FREE_ARG'))*[[:space:]]*$'
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

worker_spawned() { # worker_spawned <base> -> true when this session spawned a worker since it first recorded delegate for that worktree
  local since
  since=$(cat "$1.since" 2>/dev/null) # empty for a delegate an older version recorded: then any spawn counts
  awk -F'\t' -v s="$session" -v t="$since" -v w="^($WORKER_TYPES)$" '$2 == s && $3 == "spawn" && $4 != "" && $1 >= t && ($6 == "" || $6 ~ w) {found = 1; exit} END {exit !found}' "$DELEGATION_EVENTS" 2>/dev/null
}

total() { # total <file> -> the sum of the numbers it holds, one per line; anything else reads as 0
  local n
  n=$(awk '{n += $1} END {print n + 0}' "$1" 2>/dev/null)
  [[ $n =~ $NUM ]] || n=0
  echo "$n"
}

claim() { # claim <base> <path>: true when the path is one of the files the trivial decision covers, taking a free one of its TRIVIAL_MAX_FILES slots if needed
  # A slot appears with its content in one step (a hard link to a written file), so parallel calls
  # never claim more files than there are slots, nor one file twice.
  local i tmp=$1.claim.$$
  for ((i = 1; i <= TRIVIAL_MAX_FILES; i++)); do
    [[ $(cat "$1.trivial.$i" 2>/dev/null) == "$2" ]] && return 0
  done
  printf '%s\n' "$2" >"$tmp" 2>/dev/null || return 1
  for ((i = 1; i <= TRIVIAL_MAX_FILES; i++)); do
    if ln "$tmp" "$1.trivial.$i" 2>/dev/null || [[ $(cat "$1.trivial.$i" 2>/dev/null) == "$2" ]]; then
      rm -f "$tmp"
      return 0
    fi
  done
  rm -f "$tmp"
  return 1
}

has_plugin_manifest() { # has_plugin_manifest <top> <prefix>: true when a tracked plugin manifest marks <prefix>
  local top=$1 p=$2 m
  for m in .claude-plugin/plugin.json .antigravity-plugin/plugin.json .omp-plugin/marketplace.json .codex-plugin/plugin.json .cursor-plugin/plugin.json gemini-extension.json; do
    git_ -C "$top" ls-files --error-unmatch -- "${p}${m}" >/dev/null 2>&1 && return 0
  done
  return 1
}

security_path() { # security_path <top> <path> -> true for an agent-control or secrets path inside top
  local rel=${2#"$1"/} dir parent
  [[ $rel =~ $SECURITY_PATHS ]] && return 0
  # A plugin's hooks, skills, agents, commands and adapters are controls too. A tracked manifest
  # marks the plugin, since a bare .claude-plugin directory costs one mkdir the hook does not see.
  if [[ $rel == hooks.json || $rel == */hooks.json ]]; then
    parent=${rel%hooks.json}
    has_plugin_manifest "$1" "$parent" && return 0
  fi
  dir=$rel
  while [[ $dir == */* ]]; do
    dir=${dir%/*}
    case /$dir in */hooks | */skills | */agents | */commands | */adapters) ;; *) continue ;; esac
    parent=${dir%/*}
    [[ $parent == "$dir" ]] && parent="" || parent=$parent/
    has_plugin_manifest "$1" "$parent" && return 0
  done
  return 1
}

deny() { # deny <kind> <reason>: what gate and scope print to deny an edit; the kind goes to the events log
  printf '%s%s%s' "$1" "$US" "$2"
}

record() { # record <base> <top> <choice> <reason> [named file...]: writes a decision's state and appends it to DELEGATION_LOG
  local base=$1 top=$2 choice=$3 reason=$4
  shift 4
  mkdir -p "${base%/*}" "$(dirname "$DELEGATION_LOG")" &&
    printf '%s\t%s\n' "$choice" "$reason" >"$base.decision.new" &&
    mv -f "$base.decision.new" "$base.decision" &&
    rm -f "$base.trivial" "$base".trivial.[0-9]* && # .trivial is the one slot older versions wrote
    { (($# == 0)) || printf '%s\n' "$@" >>"$base.security"; } &&
    { [[ $choice != delegate || -f $base.since ]] || date -u +%FT%TZ >"$base.since"; } &&
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$session" "$top" "$choice" "$reason" "$*" >>"$DELEGATION_LOG"
}

# The policy these texts and undecided_spawn's deny state also lives in SKILL.md, README.md,
# examples/CLAUDE.md, examples/AGENTS.md and the user's CLAUDE.md, and the test suite pins parts of
# it; change them together.
delegate_how() { # delegate_how <top>
  case $HARNESS in
    claude)
      printf '%s' "run $SELF decide $1 $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill (hierarchical-implementation:hierarchical-implementation when installed as a plugin), and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a named worker (subagent_type hierarchical-implementation:worker, or general-purpose) with model set, including the file in this edit. Review each result critically, send numbered corrections to the same worker with SendMessage or re-brief a fresh worker, stop after three rounds, and edit here only to integrate. While a /repro gate is open here, the worker works in this worktree."
      ;;
    agy)
      printf '%s' "run $SELF decide $1 $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill, and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a worker subagent via invoke_subagent (or swarm) with a clear role/name, including the file in this edit. Review each result critically, send numbered corrections to the same worker with send_message or re-brief a fresh worker, stop after three rounds, and edit here only to integrate."
      ;;
    opencode)
      printf '%s' "run $SELF decide $1 $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill, and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a worker via the subagent tool, including the file in this edit. Review each result critically, send numbered corrections to the same child session or re-brief a fresh worker, stop after three rounds, and edit here only to integrate."
      ;;
    omp)
      printf '%s' "run $SELF decide $1 $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill, and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a named worker via the task tool (agent worker or task), including the file in this edit. Review each result critically, send numbered corrections or re-brief a fresh worker, stop after three rounds, and edit here only to integrate."
      ;;
    codex)
      printf '%s' "run $SELF decide $1 $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill, and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a worker via spawn_agent, including the file in this edit. Review each result critically, send numbered corrections with send_input or re-brief a fresh worker, stop after three rounds, and edit here only to integrate."
      ;;
    *)
      printf '%s' "run $SELF decide $1 $session delegate \"<the units, plain words>\", load the hierarchical-implementation skill, and give each unit (disjoint files, separate tests, no shared interface change; a coupled change is one unit) to a worker subagent or free-models.sh run, including the file in this edit. Review each result critically, send numbered corrections or re-brief a fresh worker, stop after three rounds, and edit here only to integrate."
      ;;
  esac
}
direct_how() { # direct_how <top>
  printf '%s' "run $SELF decide $1 $session direct \"<exemption>: <why, plain words>\" and retry; a security exemption also lists every file it covers after the reason, as paths relative to $1. Write reasons in plain words, without backticks, quotes, dollar signs, exclamation marks or backslashes"
}
instead_how() { # instead_how <top> -> the ways out of a trivial exemption the task outgrew
  printf '%s' "Delegate: $(delegate_how "$1") Or record a different exemption: $(direct_how "$1")"
}
EXEMPTION_TEXT="trivial (a small change: it covers up to $TRIVIAL_MAX_FILES files and $TRIVIAL_MAX_LINES changed lines in all, which neither a commit nor recording again resets), security (the change edits the agent's own controls: hooks, gates, agent settings or permissions, CLAUDE.md, AGENTS.md, skill or agent definitions, or data and config files that hold secrets, not code that handles them; it is never delegated and covers only the files you name, and decide refuses other paths; repo ownership, CI and IAM files are not in this class), lane (only in a session a lane spawner started with LANE_MODE=unit to execute a unit its coordinator reviews), opt-out (the user or the repo's rules say not to delegate), no-subagents (this harness has no subagent tool)"
# A spawner that starts lanes (herdr-spawn --lane) exports LANE_MODE, which outranks the brief's
# Lane mode line: a brief can be misread or lost to compaction, the environment cannot. So the lane
# exemption needs LANE_MODE=unit, and a lane started without it follows this gate like any driver.
# The session still records lane itself: the variable outlives the lane in its pane's shell, so a
# later session there must not be exempted without a decision of its own.
case ${LANE_MODE:-} in
  driver) LANE_HINT=" This session was spawned as a driver lane (LANE_MODE=driver), so the lane exemption does not apply: delegate." ;;
  unit) LANE_HINT=" This session was spawned as a unit lane (LANE_MODE=unit): if it executes a unit a coordinator reviews, record direct with the lane exemption." ;;
  *) LANE_HINT="" ;;
esac

gate() { # gate <file> <changed lines it adds> -> prints a deny (kind and reason), or nothing to allow
  local base top gitdir n
  [[ -n $1 ]] || return 0
  n=$2
  [[ $n =~ $NUM ]] || n=0
  resolve "$1" "$cwd" || return 0
  [[ $path == "$root"/* ]] || return 0
  if [[ $path == *$'\n'* ]]; then
    deny newline "The delegation gate cannot track a path with a newline in it, so it refuses edits to such paths under $root."
    return 0
  fi
  repo_of "$real" || return 0
  base=$(state_base "$session" "$gitdir") || return 0
  mkdir -p "${base%/*}" 2>/dev/null && [[ -w ${base%/*} ]] || return 0
  if ! [[ $top =~ $PLAIN && $SELF =~ $PLAIN ]]; then
    echo "hierarchical-implementation gate: not gating $top, because it or $SELF has characters outside the plain set" >&2
    return 0
  fi
  if [[ ! -f $base.decision ]]; then
    deny undecided "Implementation runs through worker subagents by default, with the user's standing authorization for editing workers, so decide before the main thread edits $top. Delegate: $(delegate_how "$top") Work directly only when the whole task is one of these exemptions: $EXEMPTION_TEXT. Then $(direct_how "$top").$LANE_HINT Do not edit through the shell to get around this."
    return 0
  fi
  scope "$base" "$top" "$n"
}

scope() { # scope <base> <top> <changed lines> -> prints a deny when the recorded decision does not cover this edit
  # Side effects: a trivial decision claims the files it sees, and an allowed driver edit under
  # delegate or trivial is added to its line count. These writes are safe under parallel tool calls
  # without a lock: claims take exclusive slots, and a parallel batch can overshoot a count only once.
  local base=$1 top=$2 n=$3 choice why used dirty f i events_dir
  IFS=$'\t' read -r choice why <"$base.decision"
  case $choice:$why in
    delegate:*)
      events_dir=$(dirname "$DELEGATION_EVENTS")
      [[ -d $events_dir && -w $events_dir ]] || return 0
      if ! worker_spawned "$base"; then
        if [[ $HARNESS == claude ]]; then
          deny no-worker "This session recorded delegate for $top but has not spawned a named worker since then (an Agent call with subagent_type hierarchical-implementation:worker or general-purpose, or a free-models.sh run; read-only and bookkeeping agents do not count), so there is nothing to integrate yet. Spawn the named workers with the Agent tool and model set first, or start the skill's free-models.sh run for a free-model worker, then edit here only to integrate. If the task is in fact an exemption, $(direct_how "$top")."
        else
          deny no-worker "This session recorded delegate for $top but has not spawned a worker since then (a worker subagent call or a free-models.sh run; read-only and bookkeeping agents do not count), so there is nothing to integrate yet. Spawn the workers first, then edit here only to integrate. If the task is in fact an exemption, $(direct_how "$top")."
        fi
        return 0
      fi
      used=$(total "$base.driver")
      if ((used + n > INTEGRATE_MAX_LINES)); then
        if [[ $HARNESS == claude ]]; then
          deny budget "Under delegate the driver's own edits in $top would reach $((used + n)) changed lines, past the integration budget of $INTEGRATE_MAX_LINES: that is authoring, not integration. Send the change to the worker that owns the file with SendMessage, or spawn a worker for it. If the user asked you to finish it yourself, run $SELF decide $top $session direct \"opt-out: <what the user said>\"."
        else
          deny budget "Under delegate the driver's own edits in $top would reach $((used + n)) changed lines, past the integration budget of $INTEGRATE_MAX_LINES: that is authoring, not integration. Send the change to the worker that owns the file, or spawn a worker for it. If the user asked you to finish it yourself, run $SELF decide $top $session direct \"opt-out: <what the user said>\"."
        fi
      else
        echo "$n" >>"$base.driver"
      fi
      ;;
    direct:trivial:*)
      if ! claim "$base" "$path"; then
        deny trivial-files "The trivial exemption recorded for $top covers up to $TRIVIAL_MAX_FILES files and this edit is another, so the task is not trivial. $(instead_how "$top"). Do not edit through the shell to get around this."
        return 0
      fi
      used=$(total "$base.trivial-lines")
      dirty=0
      for ((i = 1; i <= TRIVIAL_MAX_FILES; i++)); do
        f=$(cat "$base.trivial.$i" 2>/dev/null) && [[ -n $f ]] && dirty=$((dirty + $(diff_lines "$top" "$f")))
      done
      ((dirty > used)) && used=$dirty
      if ((used + n > TRIVIAL_MAX_LINES)); then
        deny trivial-lines "The trivial exemption covers $TRIVIAL_MAX_LINES changed lines in all, and this edit brings this session's direct edits in $top to about $((used + n)), so the task is not trivial. $(instead_how "$top")."
      else
        echo "$n" >>"$base.trivial-lines"
      fi
      ;;
    direct:security:*)
      grep -qxF -- "$path" "$base.security" 2>/dev/null && security_path "$top" "$path" ||
        deny security "The security exemption recorded for $top covers only the agent-control or secrets files named when it was recorded, and $path is not one of them. If this file also edits the agent's own controls or holds secrets, add it: run $SELF decide $top $session direct \"security: <why, plain words>\" <file>. Otherwise give it to a named worker with the Agent tool and model set; subagent edits are not gated, while recording delegate here would drop the security scope."
      ;;
    direct:lane:*)
      [[ ${LANE_MODE:-} == unit ]] ||
        deny lane "The lane exemption recorded for $top applies only in a session a lane spawner started with LANE_MODE=unit, and this one has LANE_MODE=${LANE_MODE:-unset}. Delegate: $(delegate_how "$top")"
      ;;
    direct:*) ;; # opt-out, no-subagents and reasons from older versions cover the whole worktree
  esac
}

undecided_spawn() { # undecided_spawn -> prints a deny when the session, working in a worktree under the root, starts a worker before recording any decision
  # A driver that only reviews never edits, so without this a fully delegated task leaves no
  # decision behind. The callers decide what counts as a worker (UNIT_WORKER_TYPES, or the skill's
  # free-model run). Any decision of the session counts, since its workers may edit another
  # worktree than the one it runs in.
  local here top gitdir f dir=$STATE_DIR/delegation/$session
  [[ $session =~ $SID ]] || return 0
  here=$(cd "$cwd" 2>/dev/null && pwd -P) && [[ $here == "$root"/* ]] || return 0
  repo_of "$here" && [[ $top =~ $PLAIN && $SELF =~ $PLAIN ]] || return 0
  mkdir -p "$dir" 2>/dev/null && [[ -w $dir ]] || return 0 # decide could not record here, so it could never clear the deny
  for f in "$dir"/*.decision; do [[ -f $f ]] && return 0; done # the quoted prefix is matched literally
  deny undecided "Record the decision before the first worker, as before the first edit, so every delegated task leaves one in the log: run $SELF decide $top $session delegate \"<the units, plain words>\", naming the worktree the workers will edit if it is not $top, then retry this call. If the task is in fact one of the exemptions (${EXEMPTIONS//|/, }), $(direct_how "$top").$LANE_HINT An agent that only reads, reviews or researches needs no decision: spawn it as Explore."
}

free_first() { # free_first [worker_name] [worker_model] -> prints a deny when free-model workers are on and the plugin's worker starts on sonnet before a free-model run for its unit
  # With HI_FREE_WORKERS=1 the skill tries each editing unit on a free model and falls back to an
  # Agent worker when the run exits 3. Drivers skipped that prose, so the spawn waits for a logged
  # run whose name is the worker's name, or its prefix before a dash (a redo or a best-of-N attempt
  # of that unit). A worker on another model passes, since the user may have named it, and driver
  # lanes never use free models.
  local name=${1:-} model=${2:-} here script named="If the user named this worker's model, pass that model instead."
  [[ ${HI_FREE_WORKERS:-} == 1 && ${LANE_MODE:-} != driver && $session =~ $SID ]] || return 0
  command -v "${OPENCODE_BIN:-opencode}" >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$DELEGATION_EVENTS")" 2>/dev/null && [[ -w $(dirname "$DELEGATION_EVENTS") ]] || return 0 # a run could not be logged here, so it could never clear the deny
  here=$(cd "$cwd" 2>/dev/null && pwd -P) && [[ $here == "$root"/* ]] || return 0
  if (($# == 0)); then
    IFS=$US read -r name model < <(jq -r '[.tool_input.name // "", .tool_input.model // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null)
  fi
  case $model in '' | *[Ss][Oo][Nn][Nn][Ee][Tt]*) ;; *) return 0 ;; esac
  [[ -n $name ]] && S=$session N=$name awk -F'\t' '
    $2 == ENVIRON["S"] && $3 == "spawn" && $6 == "free-models" && (ENVIRON["N"] == $4 || index(ENVIRON["N"], $4 "-") == 1) { f = 1; exit }
    END { exit !f }' "$DELEGATION_EVENTS" 2>/dev/null && return 0
  script=${SELF%/hooks/*}/skills/hierarchical-implementation/scripts/free-models.sh
  [[ -f $script ]] || script="the skill's scripts/free-models.sh"
  subagent_model_forced && named="If the user named this worker's model, tell them it is not available while CLAUDE_CODE_SUBAGENT_MODEL_FORCE is on."
  deny free-first "Free-model workers are on (HI_FREE_WORKERS=1), so each editing unit tries a free model before an Agent worker. Read references/free-models.md in the hierarchical-implementation skill, write the brief to a file outside the worktree, and run $script run <worktree> ${name:-<unit name>} <brief-file> with run_in_background. If it exits 3, retry this spawn with name set to the same unit name, or that name plus a dash and a suffix for a redo. $named"
}

subagent_model_forced() { # true when CLAUDE_CODE_SUBAGENT_MODEL_FORCE holds a value Claude Code reads as on
  case ${CLAUDE_CODE_SUBAGENT_MODEL_FORCE:-} in 1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) return 0 ;; esac
  return 1
}

own_decide() { # own_decide <command>: true when the command is exactly this script's decide call, with inert arguments, for the calling session
  local prefix args=""
  [[ $1 != *$'\n'* ]] || return 1
  for prefix in "$SELF" "$0" "$SELF_ABS"; do
    [[ -n $prefix && $prefix =~ $PLAIN && $1 == "$prefix decide "* ]] || continue
    args=${1#"$prefix decide "}
    break
  done
  [[ -n $args && $args =~ $DECIDE_ARGS ]] || return 1
  args=${args#* }
  [[ ${args%% *} == "$session" ]]
}

patch_targets() { # patch_targets <patch text> -> "<changed lines> TAB <file>" for each file in a *** Begin Patch block
  awk '
    function flush() {
      if (cur != "") {
        printf "%d\t%s\n", count, cur
        if (move != "") printf "%d\t%s\n", 0, move
      }
      cur = ""; move = ""; count = 0
    }
    { sub(/\r$/, "") }
    /^\*\*\* Add File: / { flush(); cur = substr($0, 15); next }
    /^\*\*\* Update File: / { flush(); cur = substr($0, 18); next }
    /^\*\*\* Delete File: / { flush(); cur = substr($0, 18); next }
    /^\*\*\* Move to: / { move = substr($0, 14); next }
    /^\*\*\* End Patch/ { flush(); next }
    cur != "" && (/^[+-]/) && !/^\+\+\+/ && !/^---/ { count++ }
    END { flush() }
  ' <<<"$1"
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
  if [[ $choice == direct && $reason == lane:* && ${LANE_MODE:-} != unit ]]; then
    echo "the lane exemption needs LANE_MODE=unit, which a lane spawner such as herdr-spawn --lane unit exports, and this session has LANE_MODE=${LANE_MODE:-unset}: record delegate, or another exemption that applies" >&2
    exit 1
  fi
  repo_of "$repo" || { echo "not a git worktree: $repo" >&2; exit 1; }
  base=$(state_base "$session" "$gitdir") || { echo "not a session id: $session" >&2; exit 1; }
  [[ $top =~ $PLAIN ]] || { echo "this gate never asks about $top" >&2; exit 1; }
  named=()
  for f in "${files[@]}"; do
    resolve "$f" "$top" && [[ $path == "$top"/* && $path =~ $PLAIN ]] || { echo "not a plain path inside $top: $f" >&2; exit 1; }
    security_path "$top" "$path" || {
      echo "not an agent-control or secrets path: $f. security covers hooks, gates, agent settings and permissions, CLAUDE.md, AGENTS.md, skill and agent definitions and data or config files that hold secrets; give other files to a worker, or record trivial for a small change" >&2
      exit 1
    }
    named[${#named[@]}]=$path
  done
  record "$base" "$top" "$choice" "$reason" "${named[@]}" || { echo "could not record the decision under $STATE_DIR" >&2; exit 1; }
  case $choice:$reason in
    delegate:*) echo "recorded delegate: spawn the named workers; after that, this session's own edits in $top are limited to integration, $INTEGRATE_MAX_LINES changed lines in all" ;;
    direct:trivial:*)
      used=$(total "$base.trivial-lines")
      ((used < TRIVIAL_MAX_LINES)) || used=$TRIVIAL_MAX_LINES
      echo "recorded direct (trivial): up to $TRIVIAL_MAX_FILES files in $top are no longer gated, for $((TRIVIAL_MAX_LINES - used)) more changed lines of the $TRIVIAL_MAX_LINES this session gets here"
      ;;
    direct:security:*) echo "recorded direct (security): ${#named[@]} named file(s) in $top are no longer gated" ;;
    *) echo "recorded $choice: this session's edits in $top are no longer gated" ;;
  esac
  exit 0
fi

if [[ ${1:-} == report ]]; then
  [[ -f $DELEGATION_LOG ]] || { echo "no decisions recorded in $DELEGATION_LOG" >&2; exit 1; }
  events=$DELEGATION_EVENTS
  [[ -f $events ]] || events=/dev/null
  # Only workers and the messages sent to them count: sessions also spawn specialists and message
  # teammates, which say nothing about the review loop.
  awk -F'\t' -v ex="$EXEMPTIONS" -v w="^($WORKER_TYPES)$" '
    FILENAME == ARGV[1] {
      k = $4
      if (k == "direct") k = match($5, "^(" ex "):") ? substr($5, 1, RLENGTH - 1) : "direct"
      if (!($2 in kinds)) { order[++n] = $2; kinds[$2] = k }
      else if (index("+" kinds[$2] "+", "+" k "+") == 0) kinds[$2] = kinds[$2] "+" k
      next
    }
    $3 == "spawn" && $4 != "" && ($6 == "" || $6 ~ w) { workers[$2]++; named[$2, $4] = 1 }
    $3 == "message" && (($2, $4) in named) { messages[$2]++ }
    $3 == "deny" { denies[$2]++; if (!($2 in kinds)) { order[++n] = $2; kinds[$2] = "undecided" } }
    END {
      printf "%-36s  %-24s  %7s  %8s  %6s\n", "session", "decisions", "workers", "messages", "denies"
      for (i = 1; i <= n; i++) { s = order[i]; printf "%-36s  %-24s  %7d  %8d  %6d\n", s, kinds[s], workers[s], messages[s], denies[s] }
    }' "$DELEGATION_LOG" "$events"
  exit 0
fi

case $HARNESS in
  claude | agy | codex | gemini | cursor) PROTO=$HARNESS ;;
  *) PROTO=generic ;;
esac

emit_pass() {
  case $PROTO in
    claude | codex) ;;
    agy | gemini | cursor) printf '{}\n' ;;
    generic) printf '{"decision":"passthrough"}\n' ;;
  esac
}

emit_allow() { # emit_allow <reason>
  case $PROTO in
    claude | codex) jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r}}' ;;
    agy | gemini) jq -cn --arg r "$1" '{decision:"allow",reason:$r}' ;;
    cursor) printf '{"permission":"allow"}\n' ;;
    generic) jq -cn --arg r "$1" '{decision:"allow",reason:$r}' ;;
  esac
}

emit_deny() { # emit_deny <kind> <reason>
  local k=$1 r=$2
  if [[ $session =~ $SID ]]; then
    mkdir -p "$(dirname "$DELEGATION_EVENTS")" 2>/dev/null
    printf '%s\t%s\tdeny\t%s\t\t%s\n' "$(date -u +%FT%TZ)" "$session" "$tool" "$k" >>"$DELEGATION_EVENTS" 2>/dev/null
  fi
  case $PROTO in
    claude | codex) jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;;
    agy | gemini) jq -cn --arg r "$r" '{decision:"deny",reason:$r}' ;;
    cursor) jq -cn --arg r "$r" '{permission:"deny",userMessage:$r,agentMessage:$r}' ;;
    generic) jq -cn --arg k "$k" --arg r "$r" '{decision:"deny",kind:$k,reason:$r}' ;;
  esac
}

emit_session_context() { # emit_session_context <text>
  case $PROTO in
    claude | codex | gemini) jq -cn --arg t "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$t}}' ;;
    agy) jq -cn --arg t "$1" '{injectSteps:[{systemMessage:{systemMessage:$t}}]}' ;;
    cursor) jq -cn --arg t "$1" '{additional_context:$t}' ;;
    generic) jq -cn --arg t "$1" '{decision:"passthrough",additionalContext:$t}' ;;
  esac
}

handle_session_start() {
  # A session cannot see HI_FREE_WORKERS without running a command, so the skill's free-model rule
  # never fired; this note states it at every start, including after compaction.
  if [[ ${HI_FREE_WORKERS:-} == 1 && ${LANE_MODE:-} != driver ]] && command -v "${OPENCODE_BIN:-opencode}" >/dev/null 2>&1; then
    emit_session_context "Free-model workers are on (HI_FREE_WORKERS=1, opencode installed). When the hierarchical-implementation skill delegates an editing unit, read its references/free-models.md and run free-models.sh for the unit before an Agent worker. The delegation gate refuses the plugin worker on sonnet until a free-model run under the unit name was tried."
  else
    emit_pass
  fi
  exit 0
}

log_event() { # log_event <kind> <target> <model> <type>
  local k=$1 t=$2 m=$3 ty=$4
  [[ $session =~ $SID ]] || return 0
  t=${t//$'\t'/ }; t=${t//$'\n'/ }; t=${t//$'\r'/ }
  m=${m//$'\t'/ }; m=${m//$'\n'/ }; m=${m//$'\r'/ }
  ty=${ty//$'\t'/ }; ty=${ty//$'\n'/ }; ty=${ty//$'\r'/ }
  mkdir -p "$(dirname "$DELEGATION_EVENTS")" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$session" "$k" "$t" "$m" "$ty" >>"$DELEGATION_EVENTS" 2>/dev/null
}

check_post_shell() { # check_post_shell <cmd>
  local cmd=$1 k unit
  [[ $cmd =~ $FREE_RUN ]] || return 0
  k=spawn unit=${BASH_REMATCH[5]}
  [[ -n ${BASH_REMATCH[7]} ]] && k=message
  case $unit in \"*\" | \'*\') unit=${unit:1:${#unit}-2} ;; esac # the shell drops quotes around the unit name, and free_first compares it with the worker's name
  log_event "$k" "$unit" "${BASH_REMATCH[4]:-free}" "free-models"
}

check_shell_cmd() { # check_shell_cmd <cmd> <allow_decide: 0|1> -> sets kind and reason, or emits allow and exits
  local cmd=$1 allow_decide=$2 out count size target
  if [[ $allow_decide == 1 ]] && own_decide "$cmd"; then
    emit_allow "records a hierarchical-implementation decision"
    exit 0
  fi
  if [[ $allow_decide == 1 && $cmd =~ $FREE_RUN && -z ${BASH_REMATCH[7]} ]] && out=$(undecided_spawn) && [[ -n $out ]]; then
    kind=${out%%"$US"*} reason=${out#*"$US"}
    return 0
  fi
  case $cmd in *'>'* | *tee* | *sed* | *perl*) ;; *) return 0 ;; esac # nothing else the tokenizer recognizes can write
  count=0
  while IFS=$'\t' read -r size target; do
    [[ -n $target ]] || continue
    count=$((count + 1))
    if ((count > MAX_TARGETS)); then
      kind=too-many-files reason="This command writes more than $MAX_TARGETS files, more than the delegation gate checks in one command. Split it into smaller commands."
      break
    fi
    out=$(gate "$target" "$size")
    [[ -z $out ]] || { kind=${out%%"$US"*} reason="This command writes $target, which the gate treats like an edit. ${out#*"$US"}"; break; }
  done < <(shell_targets "$cmd")
}

check_patch_text() { # check_patch_text <patch> -> sets kind and reason
  local size target out count=0
  while IFS=$'\t' read -r size target; do
    [[ -n $target ]] || continue
    count=$((count + 1))
    if ((count > MAX_TARGETS)); then
      kind=too-many-files reason="This patch writes more than $MAX_TARGETS files, more than the delegation gate checks in one command. Split it into smaller patches."
      break
    fi
    out=$(gate "$target" "$size")
    [[ -z $out ]] || { kind=${out%%"$US"*} reason=${out#*"$US"}; break; }
  done < <(patch_targets "$1")
}

# shellcheck disable=SC2016 # jq program variables are literal
edit_delta_jq='
  def delta($o; $n): ($o | split("\n")) as $a | ($n | split("\n")) as $b | ([$a, $b] | map(length) | min) as $m |
    (first(range($m) | select($a[.] != $b[.])) // $m) as $p |
    (first(range($m - $p) | select($a[-1 - .] != $b[-1 - .])) // ($m - $p)) as $s |
    ($a | length) + ($b | length) - 2 * ($p + $s);
  def str: if type == "string" then . else "" end;
'

check_edit_payload() { # check_edit_payload <file> <changed> <replace_all_old> -> sets kind and reason
  local file=$1 changed=$2 old=${3:-} content rest hits out
  [[ $changed =~ $NUM ]] || changed=0
  if [[ -n $old ]] && resolve "$file" "$cwd"; then
    content=$(cat "$path" 2>/dev/null)
    rest=${content//"$old"/}
    hits=$(((${#content} - ${#rest}) / ${#old}))
    ((hits > 1)) && changed=$((changed * hits))
  fi
  out=$(gate "$file" "$changed")
  [[ -z $out ]] || { kind=${out%%"$US"*} reason=${out#*"$US"}; }
}

agy_is_subagent() { # agy_is_subagent <parent_or_agent> <is_sub> <transcript_path>
  [[ -n $1 || $2 == true || ${HIERARCHICAL_GATE_SUBAGENT:-0} == 1 ]] && return 0
  if [[ -n $3 && -r $3 ]]; then
    head -n 1 "$3" 2>/dev/null | jq -e 'objects | .source == "SYSTEM" and .type == "SYSTEM_MESSAGE" and ((.content // "") | tostring | contains("sender="))' >/dev/null 2>&1 && return 0
  fi
  return 1
}

[[ ${HIERARCHICAL_GATE:-on} == off ]] && { emit_pass; exit 0; }

input=$(cat)
reason="" kind=""

case $PROTO in
  claude)
    IFS=$US read -r agent event tool session cwd < <(jq -r '[.agent_id // "", .hook_event_name // "PreToolUse", .tool_name // "", .session_id // "", .cwd // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || exit 0
    [[ -z $agent ]] || exit 0
    cwd=${cwd:-$PWD}

    [[ $event == SessionStart ]] && handle_session_start

    if [[ $event == PostToolUse ]]; then
      fields=""
      case $tool in
        Agent | Task) kind=spawn ;;
        SendMessage) kind=message ;;
        Bash) # a free-model worker counts like an Agent worker; continuing its session is a message
          cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || exit 0
          check_post_shell "$cmd"
          exit 0
          ;;
        *) exit 0 ;;
      esac
      [[ $session =~ $SID ]] || exit 0
      fields=$(jq -r '[.tool_input.name // .tool_input.to // "", ((.tool_response | objects | .resolvedModel) // .tool_input.model // ""), .tool_input.subagent_type // ""] | map(tostring | gsub("[\\t\\n\\r]"; " ")) | join("\t")' <<<"$input" 2>/dev/null) || exit 0
      mkdir -p "$(dirname "$DELEGATION_EVENTS")" 2>/dev/null
      printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$session" "$kind" "$fields" >>"$DELEGATION_EVENTS" 2>/dev/null
      exit 0
    fi

    root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || exit 0
    case $tool in
      Edit | Write | MultiEdit | NotebookEdit)
        file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$input" 2>/dev/null) || exit 0
        # An edit's size is the lines it changes: old and new lose the lines they share at both ends,
        # so context around a one-line fix does not count. Whole-file contents count whole.
        changed=$(jq -r "$edit_delta_jq"'
          [.tool_input | ((.content, .new_source) | select(type == "string") | split("\n") | length),
            (select(.old_string != null or .new_string != null) | delta(.old_string | str; .new_string | str)),
            (.edits[]? | delta(.old_string | str; .new_string | str))] | add // 0' <<<"$input" 2>/dev/null) || changed=0
        old=$(jq -j 'if .tool_input.replace_all == true then .tool_input.old_string // "" else "" end' <<<"$input" 2>/dev/null)
        check_edit_payload "$file" "$changed" "$old"
        ;;
      Bash | Monitor)
        cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || exit 0
        allow_d=0
        [[ $tool == Bash ]] && jq -e '.tool_input.dangerouslyDisableSandbox != true' <<<"$input" >/dev/null 2>&1 && allow_d=1
        check_shell_cmd "$cmd" "$allow_d"
        ;;
      Agent | Task)
        type=$(jq -r '.tool_input.subagent_type // "" | tostring | ascii_downcase | gsub("[\\s_-]"; "")' <<<"$input" 2>/dev/null)
        if [[ $type =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(undecided_spawn) && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        elif ! subagent_model_forced && [[ $session =~ $SID && -d $STATE_DIR/delegation/$session ]] &&
          jq -e '(.tool_input.name // "") != "" and (.tool_input.model // "") == "" and .tool_input.subagent_type != "fork"' <<<"$input" >/dev/null 2>&1; then
          kind=model reason="Set model on every named worker: the hierarchical-implementation skill passes the worker model explicitly (sonnet for editing workers unless the user chose another) instead of inheriting the main session's. Retry this call with model set."
        elif [[ $type =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(free_first) && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        fi
        ;;
    esac
    ;;

  agy)
    IFS=$US read -r agent is_sub transcript event tool session cwd < <(jq -r '[.parentConversationId // .agentId // "", (.isSubagent // false | tostring), .transcriptPath // "", .hookEventName // "PreToolUse", .toolCall.name // "", .conversationId // "", .cwd // (.workspacePaths[0]? // "")] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
    agy_is_subagent "$agent" "$is_sub" "$transcript" && { emit_pass; exit 0; }
    cwd=${cwd:-$PWD}

    [[ $event == SessionStart ]] && handle_session_start

    if [[ $event == PostToolUse ]]; then
      case $tool in
        invoke_subagent)
          IFS=$US read -r wname wmodel wtype < <(jq -r '[.toolCall.args.Role // .toolCall.args.TypeName // "", .toolCall.args.Model // "", .toolCall.args.TypeName // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
          log_event spawn "$wname" "$wmodel" "$wtype"
          ;;
        swarm)
          IFS=$US read -r action wname wmodel < <(jq -r '[.toolCall.args.action // "", .toolCall.args.name // "", .toolCall.args.model // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
          [[ $action == add ]] && log_event spawn "${wname:-swarm}" "$wmodel" "swarm"
          ;;
        send_message)
          wname=$(jq -r '.toolCall.args.Recipient // ""' <<<"$input" 2>/dev/null) || wname=""
          log_event message "$wname" "" ""
          ;;
        run_command)
          cmd=$(jq -r '.toolCall.args.CommandLine // ""' <<<"$input" 2>/dev/null) || cmd=""
          check_post_shell "$cmd"
          ;;
      esac
      emit_pass
      exit 0
    fi

    root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || { emit_pass; exit 0; }
    case $tool in
      edit_file | write_file)
        file=$(jq -r '.toolCall.args.Path // .toolCall.args.path // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
        changed=$(jq -r "$edit_delta_jq"'
          [.toolCall.args | ((.Content, .content) | select(type == "string") | split("\n") | length),
            (select(.Target != null or .Replacement != null) | delta(.Target | str; .Replacement | str))] | add // 0' <<<"$input" 2>/dev/null) || changed=0
        check_edit_payload "$file" "$changed"
        ;;
      run_command)
        cmd=$(jq -r '.toolCall.args.CommandLine // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
        check_shell_cmd "$cmd" 1
        ;;
      invoke_subagent)
        IFS=$US read -r wname wmodel wtype < <(jq -r '[.toolCall.args.Role // "", .toolCall.args.Model // "", .toolCall.args.TypeName // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
        folded=$(printf '%s' "$wtype" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')
        if [[ $folded =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(undecided_spawn) && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        elif [[ $folded =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(free_first "$wname" "$wmodel") && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        fi
        ;;
      swarm)
        action=$(jq -r '.toolCall.args.action // ""' <<<"$input" 2>/dev/null) || action=""
        if [[ $action == add ]] && out=$(undecided_spawn) && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        fi
        ;;
    esac
    ;;

  codex)
    IFS=$US read -r agent event tool session cwd < <(jq -r '[.agent_id // "", .hook_event_name // "PreToolUse", .tool_name // "", .session_id // "", .cwd // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || exit 0
    [[ -z $agent ]] || exit 0
    cwd=${cwd:-$PWD}

    [[ $event == SessionStart ]] && handle_session_start
    [[ $event == UserPromptSubmit ]] && exit 0

    if [[ $event == PostToolUse ]]; then
      case $tool in
        spawn_agent | Agent | Task)
          IFS=$US read -r wname wmodel wtype < <(jq -r '[.tool_input.name // .tool_input.role // .tool_input.nickname // "worker", .tool_input.model // "", .tool_input.agent_type // .tool_input.subagent_type // "worker"] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
          log_event spawn "$wname" "$wmodel" "$wtype"
          ;;
        send_input | SendMessage)
          wname=$(jq -r '.tool_input.id // .tool_input.to // .tool_input.name // ""' <<<"$input" 2>/dev/null) || wname=""
          log_event message "$wname" "" ""
          ;;
        Bash | shell_command | exec_command | shell)
          cmd=$(jq -r '.tool_input.command // .tool_input.cmd // ""' <<<"$input" 2>/dev/null) || cmd=""
          check_post_shell "$cmd"
          ;;
      esac
      exit 0
    fi

    root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || exit 0
    case $tool in
      apply_patch)
        patch=$(jq -r 'if (.tool_input | type) == "string" then .tool_input else (.tool_input.input // .tool_input.patch // .tool_input.patchText // "") end' <<<"$input" 2>/dev/null) || exit 0
        check_patch_text "$patch"
        ;;
      Edit | Write | MultiEdit | NotebookEdit | edit_file | write_file)
        file=$(jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // ""' <<<"$input" 2>/dev/null) || exit 0
        changed=$(jq -r "$edit_delta_jq"'
          [.tool_input | ((.content, .new_source) | select(type == "string") | split("\n") | length),
            (select(.old_string != null or .new_string != null) | delta(.old_string | str; .new_string | str)),
            (.edits[]? | delta(.old_string | str; .new_string | str))] | add // 0' <<<"$input" 2>/dev/null) || changed=0
        old=$(jq -j 'if .tool_input.replace_all == true then .tool_input.old_string // "" else "" end' <<<"$input" 2>/dev/null)
        check_edit_payload "$file" "$changed" "$old"
        ;;
      Bash | shell_command | exec_command | shell)
        cmd=$(jq -r '.tool_input.command // .tool_input.cmd // ""' <<<"$input" 2>/dev/null) || exit 0
        check_shell_cmd "$cmd" 1
        ;;
      spawn_agent | Agent | Task)
        IFS=$US read -r wname wmodel wtype < <(jq -r '[.tool_input.name // .tool_input.role // "", .tool_input.model // "", .tool_input.agent_type // .tool_input.subagent_type // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
        folded=$(printf '%s' "$wtype" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')
        if [[ $folded =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(undecided_spawn) && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        elif [[ $folded =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(free_first "$wname" "$wmodel") && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        fi
        ;;
    esac
    ;;

  gemini)
    IFS=$US read -r agent event tool session cwd < <(jq -r '[.agent_id // .subagent_id // "", .hook_event_name // "BeforeTool", .tool_name // "", .session_id // "", .cwd // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
    [[ -z $agent ]] || { emit_pass; exit 0; }
    cwd=${cwd:-$PWD}

    [[ $event == SessionStart ]] && handle_session_start

    if [[ $event == AfterTool ]]; then
      case $tool in
        run_shell_command)
          cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || cmd=""
          check_post_shell "$cmd"
          ;;
        delegate_to_agent | subagent | invoke_subagent | Agent | Task)
          IFS=$US read -r wname wmodel wtype < <(jq -r '[.tool_input.name // .tool_input.agent_name // "worker", .tool_input.model // "", .tool_input.agent_name // .tool_input.subagent_type // "worker"] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
          log_event spawn "$wname" "$wmodel" "$wtype"
          ;;
      esac
      emit_pass
      exit 0
    fi

    root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || { emit_pass; exit 0; }
    case $tool in
      write_file | replace)
        file=$(jq -r '.tool_input.file_path // .tool_input.path // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
        changed=$(jq -r "$edit_delta_jq"'
          [.tool_input | (.content | select(type == "string") | split("\n") | length),
            (select(.old_string != null or .new_string != null) | delta(.old_string | str; .new_string | str))] | add // 0' <<<"$input" 2>/dev/null) || changed=0
        check_edit_payload "$file" "$changed"
        ;;
      run_shell_command)
        cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
        check_shell_cmd "$cmd" 1
        ;;
      delegate_to_agent | subagent | invoke_subagent | Agent | Task)
        IFS=$US read -r wname wmodel wtype < <(jq -r '[.tool_input.name // .tool_input.agent_name // "", .tool_input.model // "", .tool_input.agent_name // .tool_input.subagent_type // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
        folded=$(printf '%s' "$wtype" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')
        if [[ $folded =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(undecided_spawn) && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        elif [[ $folded =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(free_first "$wname" "$wmodel") && [[ -n $out ]]; then
          kind=${out%%"$US"*} reason=${out#*"$US"}
        fi
        ;;
    esac
    ;;

  cursor)
    IFS=$US read -r agent event tool session cwd < <(jq -r '[.agent_id // .subagent_id // "", .hook_event_name // .event // "preToolUse", .tool_name // "", .conversation_id // .session_id // "", .cwd // (.workspace_roots[0]? // "")] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
    [[ -z $agent ]] || { emit_pass; exit 0; }
    cwd=${cwd:-$PWD}

    [[ $event == sessionStart || $event == SessionStart ]] && handle_session_start

    if [[ $event == postToolUse || $event == afterShellExecution || $event == PostToolUse ]]; then
      case $event:$tool in
        afterShellExecution:* | *:Shell | *:Bash | *:run_terminal_cmd)
          cmd=$(jq -r '.command // .tool_input.command // ""' <<<"$input" 2>/dev/null) || cmd=""
          check_post_shell "$cmd"
          ;;
        *:Task | *:Agent | *:subagent)
          IFS=$US read -r wname wmodel wtype < <(jq -r '[.tool_input.name // .tool_input.description // "worker", .tool_input.model // "", .tool_input.subagent_type // "worker"] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
          log_event spawn "$wname" "$wmodel" "$wtype"
          ;;
      esac
      emit_pass
      exit 0
    fi

    root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || { emit_pass; exit 0; }
    if [[ $event == beforeShellExecution ]]; then
      tool=${tool:-Shell}
      cmd=$(jq -r '.command // .tool_input.command // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
      check_shell_cmd "$cmd" 1
    else
      case $tool in
        Edit | Write | StrReplace | MultiEdit | NotebookEdit | edit_file | write_file)
          file=$(jq -r '.tool_input.file_path // .tool_input.path // .tool_input.target_file // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
          changed=$(jq -r "$edit_delta_jq"'
            [.tool_input | ((.content, .contents, .new_source) | select(type == "string") | split("\n") | length),
              (select(.old_string != null or .new_string != null) | delta(.old_string | str; .new_string | str)),
              (.edits[]? | delta(.old_string | str; .new_string | str))] | add // 0' <<<"$input" 2>/dev/null) || changed=0
          old=$(jq -j 'if .tool_input.replace_all == true then .tool_input.old_string // "" else "" end' <<<"$input" 2>/dev/null)
          check_edit_payload "$file" "$changed" "$old"
          ;;
        Shell | Bash | run_terminal_cmd)
          cmd=$(jq -r '.tool_input.command // .command // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
          check_shell_cmd "$cmd" 1
          ;;
        Task | Agent | subagent)
          IFS=$US read -r wname wmodel wtype < <(jq -r '[.tool_input.name // "", .tool_input.model // "", .tool_input.subagent_type // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
          folded=$(printf '%s' "$wtype" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')
          if [[ $folded =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(undecided_spawn) && [[ -n $out ]]; then
            kind=${out%%"$US"*} reason=${out#*"$US"}
          elif [[ $folded =~ ^($UNIT_WORKER_TYPES)$ ]] && out=$(free_first "$wname" "$wmodel") && [[ -n $out ]]; then
            kind=${out%%"$US"*} reason=${out#*"$US"}
          fi
          ;;
      esac
    fi
    ;;

  generic)
    IFS=$US read -r in_harness agent event action tool session cwd < <(jq -r '[.harness // "", .agent_id // "", .event // "pre_tool", .action // "", .tool // "", .session_id // "", .cwd // ""] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
    [[ -n $in_harness ]] && HARNESS=$in_harness
    [[ -z $agent ]] || { emit_pass; exit 0; }
    cwd=${cwd:-$PWD}

    [[ $event == session_start ]] && handle_session_start

    if [[ $event == post_tool ]]; then
      case $action in
        shell)
          cmd=$(jq -r '.command // ""' <<<"$input" 2>/dev/null) || cmd=""
          check_post_shell "$cmd"
          ;;
        spawn)
          IFS=$US read -r wname wmodel wtype < <(jq -r '[.worker.name // "worker", .worker.model // "", .worker.type // "worker"] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
          log_event spawn "$wname" "$wmodel" "$wtype"
          ;;
        message)
          wname=$(jq -r '.worker.name // ""' <<<"$input" 2>/dev/null) || wname=""
          log_event message "$wname" "" ""
          ;;
      esac
      emit_pass
      exit 0
    fi

    root=$(cd "${HIERARCHICAL_GATE_ROOT:-$HOME/vscode}" 2>/dev/null && pwd -P) || { emit_pass; exit 0; }
    case $action in
      edit)
        count=0
        while IFS=$US read -r fpath fchanged; do
          [[ -n $fpath ]] || continue
          count=$((count + 1))
          if ((count > MAX_TARGETS)); then
            kind=too-many-files reason="This edit writes more than $MAX_TARGETS files, more than the delegation gate checks in one call. Split it into smaller edits."
            break
          fi
          check_edit_payload "$fpath" "$fchanged"
          [[ -z $reason ]] || break
        done < <(jq -r '(.files // [])[] | [(.path // ""), ((.changed // 0) | tostring)] | join("\u001f")' <<<"$input" 2>/dev/null)
        ;;
      patch)
        patch=$(jq -r '.patch // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
        check_patch_text "$patch"
        ;;
      shell)
        cmd=$(jq -r '.command // ""' <<<"$input" 2>/dev/null) || { emit_pass; exit 0; }
        check_shell_cmd "$cmd" 1
        ;;
      spawn)
        IFS=$US read -r wname wmodel wtype wunit < <(jq -r '[.worker.name // "", .worker.model // "", .worker.type // "", (.worker.unit // false | tostring)] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null) || true
        folded=$(printf '%s' "$wtype" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')
        if [[ $wunit == true || $folded =~ ^($UNIT_WORKER_TYPES)$ ]]; then
          if out=$(undecided_spawn) && [[ -n $out ]]; then
            kind=${out%%"$US"*} reason=${out#*"$US"}
          elif out=$(free_first "$wname" "$wmodel") && [[ -n $out ]]; then
            kind=${out%%"$US"*} reason=${out#*"$US"}
          fi
        fi
        ;;
    esac
    ;;
esac

if [[ -n $reason ]]; then
  emit_deny "$kind" "$reason"
else
  emit_pass
fi
