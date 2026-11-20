#!/usr/bin/env bash
# Free-model workers for the hierarchical-implementation skill. Runs one unit's brief through a
# headless `opencode run` on a free model, so the worker costs no paid tokens, and keeps a registry
# of which free models work. A model that fails or stalls cools down and is tried again once the
# cooldown ends. The list refreshes itself from `opencode models` once a day, and at once when
# opencode refuses a model as unavailable. A free model is never a blocker: when none finishes
# the unit, the script exits 3 and the driver falls back to a normal Agent-tool worker. Written
# for bash 3.2, the macOS default.
#
#   free-models.sh run <worktree> <name> <brief-file> [session-id]
#   free-models.sh run --model <provider/model> <worktree> <name> <brief-file> [session-id]
#   free-models.sh list
#   free-models.sh refresh
#
# run prints `model=<id> session=<id>` and then the worker's final message. A session id continues
# that worker's session, which is how the driver sends corrections. --model runs one named model
# with no rotation and no fallback. Exit: 0 finished; 3 fall back to an Agent worker (no free model
# finished, or the free path is not set up); 1 a wrong call, or the --model model did not run or
# finish for any reason, since falling back would swap it for another model.
#
# Each run uses the opencode agent HI_FREE_AGENT, which has to deny what a unit does not need:
# --auto approves everything that agent leaves at "ask". A session on the opencode service keeps
# working after its client exits, so stopping an attempt interrupts its session through the service
# API (the id comes from the run's first event) before it stops the client. The id cannot be chosen
# up front: OpenCode Zen refuses free models with a usage-limit error for an id it did not issue.
# opencode retries a rate limit without printing anything, so a run silent for HI_FREE_STALL
# seconds counts as failed.
#
# A model id agy/<model> runs through the Antigravity CLI instead, as a headless `agy -p` on that
# model. It spends the user's agy quota, not a free tier, so the rotation tries one only when
# HI_FREE_MODELS_PREFER names it. agy runs with the user's own agy settings and no restricted agent:
# in Auto mode, its default for headless runs, it approves the commands it judges safe, so the
# brief's limits are instructions there, not rules. The session it prints is its conversation id
# marked agy:, and a correction with that session runs only on agy models.

set -u
REGISTRY="${HI_FREE_REGISTRY:-${XDG_STATE_HOME:-$HOME/.local/state}/hierarchical-implementation/free-models.json}"
PREFER="${HI_FREE_MODELS_PREFER:-}" # space-separated model ids to try first
AGENT="${HI_FREE_AGENT:-lane-worker}"
COOLDOWN="${HI_FREE_COOLDOWN:-3600}" # seconds a failed model is skipped
MAX_TRIES="${HI_FREE_MAX_TRIES:-3}"  # models tried per run
TIMEOUT="${HI_FREE_TIMEOUT:-1800}"   # seconds one attempt may take
STALL="${HI_FREE_STALL:-300}"        # seconds one attempt may print nothing
OPENCODE="${OPENCODE_BIN:-opencode}"
AGY="${AGY_BIN:-agy}"
REFRESH_EVERY=86400
MESSAGE="Execute the unit in the attached brief."
RETRY_NOTE="An earlier attempt on another model stopped partway. Check git status and git diff for the files the brief names, and continue from what is there. "
CHILD="" OUT="" # the running attempt's client pid and its event output
trap '[[ -n $CHILD ]] && halt; exit 143' TERM INT HUP

usage() {
  cat >&2 <<'EOF'
usage: free-models.sh run [--model <provider/model> | --model agy/<model>] <worktree> <name> <brief-file> [session-id]
       free-models.sh list
       free-models.sh refresh
EOF
  exit 1
}

EXPLICIT="" # the model --model named, which is never swapped for another

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

session_id() { jq -rR 'fromjson? | .sessionID // empty' <"$OUT" | head -n 1; }

# interrupts the running attempt's session on the opencode service, then stops its client (KILL after
# 10s). agy has no service: stopping its client stopped the command it was running, when tried.
halt() {
  local i sid
  sid=$(session_id)
  [[ -n $sid ]] && bounded 15 "$OPENCODE" api session.interrupt --param sessionID="$sid" >/dev/null 2>&1
  kill -TERM "$CHILD" 2>/dev/null
  for ((i = 0; i < 10; i++)); do
    kill -0 "$CHILD" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "$CHILD" 2>/dev/null
}

attempt() { # attempt <model> <worktree> <name> <brief-file> <note> [session]: prints the result, or sets err and returns 1 (the model failed) or 2 (a local problem)
  local log rc size=0 now started=$SECONDS last=$SECONDS sid text att="" tool
  local -a cmd
  tool=$(backend "$1")
  if [[ $tool == agy ]]; then
    command -v "$AGY" >/dev/null 2>&1 || { err="agy is not installed"; return 2; }
    # @<path> in the prompt attaches a file but ends at whitespace, so agy gets a copy at a plain path
    att=$(mktemp /tmp/free-models-brief.XXXXXX) && cp "$4" "$att" || { rm -f "$att"; err="cannot copy the brief for agy"; return 2; }
    # the prompt runs as written, with no slash command or skill expansion
    cmd=("$AGY" --model "${1#agy/}" --disable-slash-commands --output-format stream-json)
    [[ -n ${6:-} ]] && cmd+=(--conversation "${6#agy:}")
    cmd+=(-p "$5$MESSAGE @$att")
  else
    cmd=("$OPENCODE" run --auto --agent "$AGENT" --format json -m "$1" --title "$3" -f "$4")
    [[ -n ${6:-} ]] && cmd+=(--session "$6")
    cmd+=("$5$MESSAGE")
  fi
  OUT=$(mktemp) log=$(mktemp)
  (cd "$2" && exec "${cmd[@]}") >"$OUT" 2>"$log" </dev/null &
  CHILD=$!
  err=""
  while kill -0 "$CHILD" 2>/dev/null; do
    sleep 1
    now=$(wc -c <"$OUT")
    if ((now != size)); then size=$now last=$SECONDS; fi
    if ((SECONDS - started >= TIMEOUT)); then
      err="timed out after ${TIMEOUT}s"
    elif ((SECONDS - last >= STALL)); then
      err="printed nothing for ${STALL}s (rate limited or stuck)"
    else
      continue
    fi
    halt
    break
  done
  wait "$CHILD"
  rc=$?
  CHILD=""
  if [[ $tool == agy ]]; then # an init event with the conversation id, step updates, then one result
    sid=$(jq -rR 'fromjson? | .conversation_id // empty' <"$OUT" | head -n 1)
    [[ -n $sid ]] && sid="agy:$sid" # marks the session as agy's, so a correction stays on agy
    [[ -n $err ]] || err=$(jq -rR 'fromjson? | .result // empty
      | select(.status != "SUCCESS" or .finished_reason) | .error // .finished_reason // .status // "no status"' <"$OUT" | head -n 1)
    text=$(jq -rR 'fromjson? | .result.response // empty' <"$OUT")
  else
    sid=$(session_id)
    [[ -n $err ]] || err=$(jq -rR 'fromjson? | select(.type == "error") | .error.message // .error.type // "error"' <"$OUT" | head -n 1)
    text=$(jq -rRs '[split("\n")[] | fromjson? | select(.type == "text")]
      | if length == 0 then "" else last.part.messageID as $m | map(select(.part.messageID == $m) | .part.text) | join("\n") end' <"$OUT")
  fi
  if [[ -z $err && $rc -ne 0 ]]; then err=$(tail -n 1 "$log"); fi
  if [[ -z $err && $rc -ne 0 ]]; then err="$tool exited $rc"; fi
  if [[ -z $err && -z $text ]]; then err="no reply"; fi
  rm -f "$OUT" "$log" "$att"
  if [[ $err == *"Agent not found"* ]]; then
    err="opencode has no agent named $AGENT; install the restricted agent from the plugin's examples"
    return 2
  fi
  if [[ -n $err ]]; then
    echo "free-models: $1 failed: $err" >&2
    return 1
  fi
  printf 'model=%s session=%s\n%s\n' "$1" "$sid" "$text"
}

run() {
  local model tries=0 note="" reg refreshed v relisted=""
  if [[ ${1:-} == --model ]]; then
    EXPLICIT=${2:-}
    [[ -n $EXPLICIT && $EXPLICIT != agy/ ]] || usage
    shift 2
  fi
  for v in COOLDOWN MAX_TRIES TIMEOUT STALL; do
    [[ ${!v} =~ ^[0-9]+$ ]] || fallback "HI_FREE_$v must be a whole number, not '${!v}'"
  done
  [[ $# -ge 3 && $# -le 4 && -d $1 && -f $3 ]] || usage
  [[ $(backend "$EXPLICIT") == agy ]] || command -v "$OPENCODE" >/dev/null 2>&1 || fallback "opencode is not installed"
  local wt=$1 name=$2 brief session=${4:-}
  brief="$(cd "$(dirname "$3")" && pwd -P)/$(basename "$3")" # the worker runs in the worktree
  if [[ -n $EXPLICIT ]]; then
    attempt "$EXPLICIT" "$wt" "$name" "$brief" "" "$session"
    case $? in
      0) return 0 ;;
      2) fallback "$err" ;;
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
    [[ -n $relisted && $model != agy/* && $(registry | jq --arg id "$model" '.models | has($id)') == false ]] && continue
    tries=$((tries + 1))
    ((tries > MAX_TRIES)) && break
    attempt "$model" "$wt" "$name" "$brief" "$note" "$session"
    case $? in
      0) mark "$model" ok; return 0 ;;
      2) fallback "$err" ;;
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
  fallback "no free model finished the unit"
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
  *) usage ;;
esac
