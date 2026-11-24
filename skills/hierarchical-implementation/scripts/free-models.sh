#!/usr/bin/env bash
# Free-model workers for the hierarchical-implementation skill. Runs one unit's brief through a
# coding CLI's ACP server with the user's own configuration, on a free model, so the worker costs
# no paid tokens, and keeps a registry of which free models work. Nothing is approved without an
# answer: every permission ask stops the run and reaches the driver, which answers it. A model that
# fails or stalls cools down and is tried again once the cooldown ends. The list refreshes itself
# from `opencode models` once a day, and at once when the CLI refuses a model as unavailable.
# A free model is never a blocker: when none finishes the unit, the script exits 3 and the driver
# falls back to a normal Agent-tool worker. Written for bash 3.2, the macOS default.
#
#   free-models.sh run <worktree> <name> <brief-file> [session-id]
#   free-models.sh run --model <provider/model> <worktree> <name> <brief-file> [session-id]
#   free-models.sh list
#   free-models.sh refresh
#   free-models.sh wait <run-id>
#   free-models.sh answer <run-id> <ask-id> once|reject ["<why>"]
#   free-models.sh stop <run-id>
#
# run prints `model=<id> session=<id>` and then the worker's final message. A session id continues
# that worker's session, which is how the driver sends corrections. --model runs one named model
# with no rotation and no fallback. An ask prints an ask block and exits 4, leaving the worker
# waiting; the driver answers with `answer`, or uses `wait` to see the ask again and `stop` to end
# it. Exit: 0 finished; 3 fall back to an Agent worker; 1 a wrong call, or the --model model did not
# run or finish; 4 the worker asks for a permission, answer it with `answer`.
#
# Each run uses the opencode agent HI_FREE_AGENT. The `lane-worker` example narrows the user's own
# permissions so a unit's high-impact commands become asks. A model id agy/<model> runs through the
# Antigravity CLI's ACP server in its Auto mode, on the user's agy quota rather than a free tier, so
# the rotation tries one only when HI_FREE_MODELS_PREFER names it. Its session is printed marked
# agy:, and a correction with that session runs only on agy models.

set -u
REGISTRY="${HI_FREE_REGISTRY:-${XDG_STATE_HOME:-$HOME/.local/state}/hierarchical-implementation/free-models.json}"
RUNS="${HI_FREE_RUNS:-${XDG_STATE_HOME:-$HOME/.local/state}/hierarchical-implementation/runs}"
PREFER="${HI_FREE_MODELS_PREFER:-}" # space-separated model ids to try first
AGENT="${HI_FREE_AGENT:-lane-worker}"
COOLDOWN="${HI_FREE_COOLDOWN:-3600}" # seconds a failed model is skipped
MAX_TRIES="${HI_FREE_MAX_TRIES:-3}"  # models tried per run
TIMEOUT="${HI_FREE_TIMEOUT:-1800}"   # seconds one attempt may take
STALL="${HI_FREE_STALL:-300}"        # seconds one attempt may print nothing
ASK_TIMEOUT="${HI_FREE_ASK_TIMEOUT:-1800}" # seconds a pending ask waits for an answer
OPENCODE="${OPENCODE_BIN:-opencode}"
AGY="${AGY_BIN:-agy}"
ACP_WORKER="$(cd "$(dirname "$0")" && pwd -P)/acp-worker.mjs"
REFRESH_EVERY=86400
MESSAGE="Execute the unit in the attached brief."
RETRY_NOTE="An earlier attempt on another model stopped partway. Check git status and git diff for the files the brief names, and continue from what is there. "
EXPLICIT="" # the model --model named, which is never swapped for another
WAITING_RUN="" # the run dir this process is waiting on; a signal stops it
ASK_ID_RE='^a[0-9a-f]{16}$'
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$' # run ids and names become path components
trap '[[ -n $WAITING_RUN ]] && : >"$WAITING_RUN/stop"; exit 143' TERM INT HUP

usage() {
  cat >&2 <<'EOF'
usage: free-models.sh run [--model <provider/model> | --model agy/<model>] <worktree> <name> <brief-file> [session-id]
       free-models.sh list
       free-models.sh refresh
       free-models.sh wait <run-id>
       free-models.sh answer <run-id> <ask-id> once|reject ["<why>"]
       free-models.sh stop <run-id>
EOF
  exit 1
}

valid_name() { # valid_name <what> <value>: a wrong call unless the value is safe inside a path
  [[ $2 =~ $NAME_RE ]] || { echo "free-models: invalid $1 '$2'" >&2; return 1; }
}

clip() { # clip <text> <max>: cut text is marked, so padding cannot hide the tail of an action
  local text=$1 max=$2
  if ((${#text} > max)); then
    printf '%s [cut: %d more characters]' "${text:0:max}" $((${#text} - max))
  else
    printf '%s' "$text"
  fi
}

fallback() { # fallback <why>: exit 3 sends the driver to an Agent worker; a named model exits 1 instead
  if [[ -n $EXPLICIT ]]; then
    echo "free-models: $1; $EXPLICIT did not run" >&2
    exit 1
  fi
  echo "free-models: $1; fall back to an Agent-tool worker" >&2
  exit 3
}

registry() { # a missing or unreadable registry starts over, so the next refresh rebuilds it
  [[ -s $REGISTRY ]] && jq -c . "$REGISTRY" 2>/dev/null || echo '{"refreshed":0,"models":{}}'
}

update() { # update <jq filter> [jq options]: rewrites the registry under a lock; a failed filter leaves it as it was
  local filter=$1 lock="$REGISTRY.lock" new rc i
  shift
  mkdir -p "${REGISTRY%/*}" || return 1
  for ((i = 0; i < 50; i++)); do mkdir "$lock" 2>/dev/null && break; sleep 0.1; done
  ((i < 50)) || { rmdir "$lock" && mkdir "$lock"; } 2>/dev/null # a lock held for 5s was left by a killed run: take it over
  new=$(registry | jq "$@" "$filter") && [[ -n $new ]] && printf '%s\n' "$new" >"$REGISTRY.$$" && mv "$REGISTRY.$$" "$REGISTRY"
  rc=$?
  rm -f "$REGISTRY.$$"
  rmdir "$lock" 2>/dev/null
  return $rc
}

bounded() { # bounded <seconds> <command...>: runs the command, stopped after that many seconds
  "${@:2}" &
  local pid=$! watch rc
  (sleep "$1"; kill -KILL "$pid" 2>/dev/null) >/dev/null 2>&1 &
  watch=$!
  wait "$pid"
  rc=$?
  kill "$watch" 2>/dev/null
  return $rc
}

refresh() { # free models opencode can reach; all or nothing, so a failed lookup keeps the old list
  local ids tools
  # listed from a neutral directory: a repo's own opencode config can hide providers that runs reach
  ids=$(cd "$HOME" && bounded 60 "$OPENCODE" models 2>/dev/null | grep -E '(-free|:free)$')
  [[ -n $ids ]] || { echo "free-models: opencode lists no free models" >&2; return 1; }
  # OpenRouter offers free models that cannot call tools, and a worker needs tools
  if grep -q '^openrouter/' <<<"$ids"; then
    tools=$(curl -fsS --max-time 30 https://openrouter.ai/api/v1/models 2>/dev/null |
      jq -r '.data[] | select((.supported_parameters // []) | index("tools")) | "openrouter/" + .id' 2>/dev/null)
    [[ -n $tools ]] || { echo "free-models: cannot read OpenRouter's model list" >&2; return 1; }
    ids=$(grep -v '^openrouter/' <<<"$ids"; grep -Fx -f <(printf '%s\n' "$tools") <<<"$ids")
  fi
  # agy models are not opencode's to list, so their entries and cooldowns stay
  update '.models as $m
    | .refreshed = (now | floor)
    | .models = ($ids | split("\n") | map(select(. != "")) | map({key: ., value: ($m[.] // {})}) | from_entries)
      + ($m | with_entries(select(.key | startswith("agy/"))))' --arg ids "$ids"
}

backend() { [[ $1 == agy[/:]* ]] && echo agy || echo opencode; } # backend <model or session>: agy/<id> models and agy:<id> sessions run on agy

candidates() { # candidates <registry json>: preferred models first, then the rest, skipping any still cooling down
  local agy=""
  command -v "$AGY" >/dev/null 2>&1 && agy=1
  # an agy model runs only while it is preferred and agy is installed, whatever the registry holds
  jq -r --arg prefer "$PREFER" --arg agy "$agy" '
    .models as $m
    | ($prefer | split(" ") | map(select(if startswith("agy/") then $agy != "" else $m[.] != null end)))
      + ($m | keys_unsorted | map(select(startswith("agy/") | not)))
    | reduce .[] as $id ([]; if any(.[]; . == $id) then . else . + [$id] end)
    | .[] | select(($m[.].cooldown_until // 0) <= now)' <<<"$1"
}

mark() { # mark <model> ok|fail [error]
  update '(now | floor) as $t
    | .models[$id] = ((.models[$id] // {}) + if $r == "ok"
        then {last_ok: $t, cooldown_until: 0}
        else {last_fail: $t, last_error: $e, cooldown_until: ($t + $c)} end)' \
    --arg id "$1" --arg r "$2" --arg e "${3:-}" --argjson c "$COOLDOWN"
}

print_ask() { # print_ask <run-dir> <model> <ask-json>: prints the pending ask for the driver and returns 4
  local dir=$1 model=$2 ask=$3 id kind title input req backend sid run_id
  id=$(jq -r '.id // ""' <<<"$ask")
  [[ $id =~ $ASK_ID_RE ]] || { fail_run "$model" "invalid ask id" "$dir"; return 1; }
  # a model-supplied title can contain newlines that look like lines of this block
  kind=$(jq -r '.kind // "" | gsub("[\u0000-\u001f\u007f]+"; " ")' <<<"$ask")
  title=$(clip "$(jq -r '.title // "" | gsub("[\u0000-\u001f\u007f]+"; " ")' <<<"$ask")" 300)
  input=$(clip "$(jq -c '.rawInput // {}' <<<"$ask")" 2000)
  req=$(cat "$dir/request.json")
  backend=$(jq -r '.backend // "opencode"' <<<"$req")
  sid=$(cat "$dir/session" 2>/dev/null || jq -r '.session // ""' <<<"$req")
  [[ $backend == agy && -n $sid ]] && sid="agy:$sid"
  run_id=${dir##*/}
  printf 'ask=%s run=%s model=%s session=%s\n' "$id" "$run_id" "$model" "$sid"
  printf 'action: %s\n' "$kind"
  printf 'title: %s\n' "$title"
  printf 'input: %s\n' "$input"
  printf 'answer: free-models.sh answer %s %s once|reject ["<why>"]\n' "$run_id" "$id"
  return 4
}

worker_gone() { # worker_gone <run-dir>: true when the acp worker died without writing a result
  local pid
  [[ -f $1/result.json || ! -f $1/pid ]] && return 1
  pid=$(cat "$1/pid")
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

stopped_run() { # stopped_run <run-id>: a stopped run ends every waiter with code 5
  echo "free-models: run $1 stopped" >&2
  err=stopped
  WAITING_RUN=""
  return 5
}

fail_run() { # fail_run <model> <message> <run-dir>: reports a run failure, sets err and removes the run
  err=$2
  echo "free-models: $1 failed: $err" >&2
  WAITING_RUN=""
  : >"$3/stop"
  rm -rf "$3"
  return 1
}

wait_run() { # wait_run <run-dir> <model>: polls one run; 0 done, 1 failure, 2 setup, 4 ask, 5 stopped
  local dir=$1 model=$2 state="" req backend result kind sid text ask
  local started=$(date +%s)
  req=$(jq -c . "$dir/request.json")
  backend=$(jq -r '.backend // "opencode"' <<<"$req")
  err=""
  WAITING_RUN=$dir
  while :; do
    [[ -d $dir ]] || { stopped_run "${dir##*/}"; return 5; }
    # the worker writes the result before the state, so a result is final whatever the state says
    if [[ -f $dir/result.json ]]; then
      result=$(cat "$dir/result.json")
      err=$(jq -r '.error // ""' <<<"$result")
      [[ $err == stopped ]] && { stopped_run "${dir##*/}"; return 5; }
      kind=$(jq -r '.kind // ""' <<<"$result")
      text=$(jq -r '.text // ""' <<<"$result")
      if [[ -n $err ]]; then
        WAITING_RUN=""
        rm -rf "$dir"
        if [[ $kind == setup ]]; then
          if [[ $backend == opencode && $err == "mode "*" is not offered" ]]; then
            err="opencode has no agent named $AGENT; install the worker agent from the plugin's examples"
          fi
          return 2
        fi
        echo "free-models: $model failed: $err" >&2
        return 1
      fi
      sid=$(cat "$dir/session" 2>/dev/null || true)
      [[ $backend == agy && -n $sid ]] && sid="agy:$sid"
      WAITING_RUN=""
      rm -rf "$dir"
      printf 'model=%s session=%s\n%s\n' "$model" "$sid" "$text"
      return 0
    fi
    if [[ ! -f $dir/state ]]; then
      if worker_gone "$dir"; then fail_run "$model" "acp worker exited without a result" "$dir"; return 1; fi
      if (( $(date +%s) - started >= 30 )); then fail_run "$model" "acp worker did not start" "$dir"; return 1; fi
      sleep 1
      continue
    fi
    state=$(cat "$dir/state" 2>/dev/null || true)
    if worker_gone "$dir"; then fail_run "$model" "acp worker exited without a result" "$dir"; return 1; fi
    if [[ $state == ask ]]; then
      # the worker removes ask.json just before it leaves the ask state, and stop removes the dir
      if ask=$(cat "$dir/ask.json" 2>/dev/null); then
        print_ask "$dir" "$model" "$ask"
        return $?
      fi
    fi
    sleep 1
  done
}

attempt() { # attempt <model> <worktree> <name> <brief-file> <note> [session]: launches a run and reports it
  local tool cmd mode model session cwd run_dir explicit
  tool=$(backend "$1")
  if [[ $tool == agy ]]; then
    command -v "$AGY" >/dev/null 2>&1 || { err="agy is not installed"; return 2; }
    cmd=$AGY mode=auto model=${1#agy/}
  else
    cmd=$OPENCODE mode=$AGENT model=$1
  fi
  session=${6:-}
  session=${session#agy:}
  cwd=$(cd "$2" && pwd -P) || { err="cannot enter the worktree"; return 2; }
  if [[ -n $EXPLICIT ]]; then explicit=true; else explicit=false; fi
  mkdir -p "$RUNS" || { err="cannot create the runs directory"; return 2; }
  run_dir=$(mktemp -d "$RUNS/$3-XXXXXX") || { err="cannot create a run directory"; return 2; }
  jq -n \
    --arg cmd "$cmd" --arg mode "$mode" --arg model "$model" \
    --arg cwd "$cwd" --arg brief "$4" --arg message "$5$MESSAGE" \
    --arg session "$session" --argjson timeout "$TIMEOUT" --argjson stall "$STALL" \
    --argjson askTimeout "$ASK_TIMEOUT" --argjson explicit "$explicit" --arg backend "$tool" \
    '{command: [$cmd, "acp"], cwd: $cwd, model: $model, mode: $mode, brief: $brief,
      message: $message, session: $session, timeout: $timeout, stall: $stall,
      askTimeout: $askTimeout, explicit: $explicit, backend: $backend}' >"$run_dir/request.json" || {
      err="cannot write the request"; rm -rf "$run_dir"; return 2;
    }
  node "$ACP_WORKER" launch "$run_dir" >/dev/null || {
    err="cannot start the acp worker"; rm -rf "$run_dir"; return 2;
  }
  wait_run "$run_dir" "$1"
}

run() {
  local model tries=0 note="" reg refreshed v relisted=""
  if [[ ${1:-} == --model ]]; then
    EXPLICIT=${2:-}
    [[ -n $EXPLICIT && $EXPLICIT != agy/ ]] || usage
    shift 2
  fi
  for v in COOLDOWN MAX_TRIES TIMEOUT STALL ASK_TIMEOUT; do
    [[ ${!v} =~ ^[0-9]+$ ]] || fallback "HI_FREE_$v must be a whole number, not '${!v}'"
  done
  [[ $# -ge 3 && $# -le 4 && -d $1 && -f $3 ]] || usage
  valid_name "run name" "$2" || exit 1
  [[ $(backend "$EXPLICIT") == agy ]] || command -v "$OPENCODE" >/dev/null 2>&1 || fallback "opencode is not installed"
  command -v node >/dev/null 2>&1 || fallback "node is not installed"
  local wt=$1 name=$2 brief session=${4:-}
  brief="$(cd "$(dirname "$3")" && pwd -P)/$(basename "$3")" # the worker runs in the worktree
  if [[ -n $EXPLICIT ]]; then
    if [[ -n $session && $(backend "$EXPLICIT") != $(backend "$session") ]]; then
      echo "free-models: session $session belongs to $(backend "$session"), not $(backend "$EXPLICIT"); $EXPLICIT did not run" >&2
      exit 1
    fi
    attempt "$EXPLICIT" "$wt" "$name" "$brief" "" "$session"
    case $? in
      0) return 0 ;;
      2) fallback "$err" ;;
      4) exit 4 ;;
      5) exit 3 ;; # a stopped run ends this run with no rotation and no fallback message
    esac
    return 1
  fi
  reg=$(registry)
  refreshed=$(jq '.refreshed // 0' <<<"$reg")
  if (($(date +%s) - refreshed > REFRESH_EVERY)); then
    refresh && reg=$(registry)
  fi
  set -f # model ids are split on whitespace, never globbed
  for model in $(candidates "$reg"); do
    # a session continues only on the backend that started it
    [[ -n $session && $(backend "$model") != $(backend "$session") ]] && continue
    # skip, unstarted, a stale model that this run's refresh already dropped
    [[ -n $relisted && $(backend "$model") == opencode && $(registry | jq --arg id "$model" '.models | has($id)') == false ]] && continue
    tries=$((tries + 1))
    ((tries > MAX_TRIES)) && break
    attempt "$model" "$wt" "$name" "$brief" "$note" "$session"
    case $? in
      0) mark "$model" ok; return 0 ;;
      2) fallback "$err" ;;
      4) exit 4 ;;
      5) exit 3 ;;
    esac
    # opencode refused the model before it ran, so its list may have changed since the daily
    # refresh: re-read it, once per run even when the read fails. A model it no longer offers leaves
    # the registry, with no retry note since nothing ran; one it still lists cools down like any failure.
    if [[ $err == "Model unavailable: $model"* && -z $relisted ]]; then
      relisted=1
      refresh 2>/dev/null && [[ $(registry | jq --arg id "$model" '.models | has($id)') == false ]] && continue
    fi
    mark "$model" fail "$err"
    note=$RETRY_NOTE
  done
  ((tries > 0)) || [[ -z $session ]] || fallback "no $(backend "$session") model is preferred and ready to continue session $session"
  fallback "no free model finished the unit"
}

wait_cmd() { # wait_cmd <run-id>: continues a run; sets the registry from its result
  local id=${1:-} dir req model backend explicit
  [[ -n $id ]] || usage
  valid_name "run id" "$id" || return 1
  dir="$RUNS/$id"
  [[ -d $dir ]] || { echo "free-models: no run $id" >&2; return 1; }
  req=$(cat "$dir/request.json")
  model=$(jq -r '.model // ""' <<<"$req")
  backend=$(jq -r '.backend // "opencode"' <<<"$req")
  [[ $backend == agy ]] && model="agy/$model"
  explicit=$(jq -r '.explicit // false' <<<"$req")
  [[ $explicit == true ]] && EXPLICIT=$model
  wait_run "$dir" "$model"
  case $? in
    0) [[ $explicit == true ]] || mark "$model" ok; return 0 ;;
    1) [[ $explicit == true ]] || mark "$model" fail "$err"; fallback "$err" ;;
    2) fallback "$err" ;;
    4) return 4 ;;
    5) exit 3 ;;
  esac
}

answer_cmd() { # answer_cmd <run-id> <ask-id> once|reject [message]: answers a pending ask, then continues like wait
  local id=${1:-} ask_id=${2:-} decision=${3:-} message=${4:-} dir state tmp
  [[ -n $id && -n $ask_id && ( $decision == once || $decision == reject ) ]] || usage
  valid_name "run id" "$id" || return 1
  [[ $ask_id =~ $ASK_ID_RE ]] || { echo "free-models: invalid ask id '$ask_id'" >&2; return 1; }
  dir="$RUNS/$id"
  [[ -d $dir ]] || { echo "free-models: no run $id" >&2; return 1; }
  state=$(cat "$dir/state" 2>/dev/null || true)
  [[ $state == ask ]] || { echo "free-models: run $id has no pending ask" >&2; return 1; }
  [[ -f $dir/ask.json && $(jq -r '.id // ""' "$dir/ask.json") == "$ask_id" ]] || {
    echo "free-models: run $id has no ask $ask_id" >&2; return 1;
  }
  tmp=$(mktemp "$dir/answer.XXXXXX") || { echo "free-models: cannot write the answer" >&2; return 1; }
  if jq -n --arg id "$ask_id" --arg decision "$decision" --arg message "$message" \
    '{id: $id, decision: $decision, message: $message}' >"$tmp" && mv "$tmp" "$dir/answer.json"; then
    :
  else
    rm -f "$tmp"
    echo "free-models: cannot write the answer" >&2
    return 1
  fi
  while :; do
    [[ -d $dir ]] || { stopped_run "$id"; exit 3; }
    worker_gone "$dir" && break # wait_cmd reports the dead worker
    [[ -f $dir/state ]] || break
    state=$(cat "$dir/state")
    [[ $state != ask ]] && break
    [[ -f $dir/ask.json && $(jq -r '.id // ""' "$dir/ask.json") != "$ask_id" ]] && break
    sleep 1
  done
  wait_cmd "$id"
}

stop_cmd() { # stop_cmd <run-id>: stops a pending run and removes its dir, without marking a model
  local id=${1:-} dir i
  [[ -n $id ]] || usage
  valid_name "run id" "$id" || return 1
  dir="$RUNS/$id"
  [[ -d $dir ]] || { echo "free-models: no run $id" >&2; return 1; }
  : >"$dir/stop"
  for ((i = 0; i < 20; i++)); do
    [[ -f $dir/result.json ]] && break
    worker_gone "$dir" && break
    sleep 1
  done
  rm -rf "$dir"
  echo "free-models: run $id stopped" >&2
  return 0
}

list() {
  registry | jq -r '.models | to_entries[]
    | [.key, (if (.value.cooldown_until // 0) > now then "cooling down" else "ready" end), (.value.last_error // "")]
    | @tsv'
}

case ${1:-} in
  run) shift; run "$@" ;;
  list) list ;;
  refresh) refresh ;;
  wait) shift; wait_cmd "$@" ;;
  answer) shift; answer_cmd "$@" ;;
  stop) shift; stop_cmd "$@" ;;
  *) usage ;;
esac
