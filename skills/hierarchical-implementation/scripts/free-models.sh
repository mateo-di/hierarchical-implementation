#!/usr/bin/env bash
# Free-model workers for the hierarchical-implementation skill. Runs one unit's brief through a
# headless `opencode run` on a free model, so the worker costs no paid tokens, and keeps a registry
# of which free models work. A model that fails cools down and is tried again once the cooldown
# ends; the list refreshes itself from `opencode models` once a day. A free model is never a
# blocker: when none finishes the unit, the script exits 3 and the driver falls back to a normal
# Agent-tool worker. Written for bash 3.2, the macOS default.
#
#   free-models.sh run <worktree> <name> <brief-file> [session-id]
#   free-models.sh run --model <provider/model> <worktree> <name> <brief-file> [session-id]
#   free-models.sh list
#   free-models.sh refresh
#
# run prints `model=<id> session=<id>` and then the worker's final message. A session id continues
# that worker's session, which is how the driver sends corrections. --model runs one named model
# with no rotation and no fallback. Exit: 0 finished, 3 no free model finished (fall back),
# 1 anything else.

set -u
REGISTRY="${HI_FREE_REGISTRY:-${XDG_STATE_HOME:-$HOME/.local/state}/hierarchical-implementation/free-models.json}"
PREFER="${HI_FREE_MODELS_PREFER:-}" # space-separated model ids to try first
COOLDOWN="${HI_FREE_COOLDOWN:-3600}"
MAX_TRIES="${HI_FREE_MAX_TRIES:-3}"
TIMEOUT="${HI_FREE_TIMEOUT:-1800}"
OPENCODE="${OPENCODE_BIN:-opencode}"
REFRESH_EVERY=86400
RETRY_NOTE="An earlier attempt on another model stopped partway. Check git status and git diff in this worktree before you start, and continue from what is there."

usage() {
  sed -n '9,12p' "$0" | sed 's/^# *//' >&2
  exit 1
}

registry() { if [[ -s $REGISTRY ]]; then cat "$REGISTRY"; else echo '{"refreshed":0,"models":{}}'; fi; }

save() { # save < json: replaces the registry atomically
  local tmp="$REGISTRY.$$"
  mkdir -p "${REGISTRY%/*}" && cat >"$tmp" && mv "$tmp" "$REGISTRY"
}

refresh() { # free models opencode can reach; a model that vanished leaves the registry
  local ids tools
  ids=$("$OPENCODE" models 2>/dev/null | grep -E '(-free|:free)$')
  [[ -n $ids ]] || { echo "free-models: opencode lists no free models" >&2; return 1; }
  # OpenRouter offers free models that cannot call tools, and a worker needs tools
  if grep -q '^openrouter/' <<<"$ids"; then
    tools=$(curl -fsS https://openrouter.ai/api/v1/models 2>/dev/null |
      jq -r '.data[] | select((.supported_parameters // []) | index("tools")) | "openrouter/" + .id' 2>/dev/null)
    ids=$(grep -v '^openrouter/' <<<"$ids"; grep -Fx -f <(printf '%s\n' "$tools") <<<"$ids")
  fi
  registry | jq --arg ids "$ids" '
    .models as $m
    | .refreshed = (now | floor)
    | .models = ($ids | split("\n") | map(select(. != "")) | map({key: ., value: ($m[.] // {})}) | from_entries)' | save
}

candidates() { # candidates <registry json>: preferred models first, then the rest, skipping any still cooling down
  jq -r --arg prefer "$PREFER" '
    .models as $m
    | ($prefer | split(" ") | map(select($m[.] != null))) + ($m | keys_unsorted)
    | reduce .[] as $id ([]; if any(.[]; . == $id) then . else . + [$id] end)
    | .[] | select(($m[.].cooldown_until // 0) <= now)' <<<"$1"
}

mark() { # mark <model> ok|fail [error]
  registry | jq --arg id "$1" --arg r "$2" --arg e "${3:-}" --argjson c "$COOLDOWN" '
    (now | floor) as $t
    | .models[$id] = ((.models[$id] // {}) + if $r == "ok"
        then {last_ok: $t, cooldown_until: 0}
        else {last_fail: $t, last_error: $e, cooldown_until: ($t + $c)} end)' | save
}

attempt() { # attempt <model> <worktree> <name> <message> [session]: prints the result; sets err and fails on any provider error
  local out rc sid text
  local -a cmd=("$OPENCODE" run --auto --format json -m "$1" --title "$3")
  [[ -n ${5:-} ]] && cmd+=(--session "$5")
  command -v timeout >/dev/null 2>&1 && cmd=(timeout "$TIMEOUT" "${cmd[@]}")
  out=$(cd "$2" && "${cmd[@]}" "$4" 2>/dev/null)
  rc=$?
  err=$(jq -rR 'fromjson? | select(.type == "error") | .error.message // .error.type // "error"' <<<"$out" | head -n 1)
  sid=$(jq -rR 'fromjson? | .sessionID // empty' <<<"$out" | head -n 1)
  text=$(jq -rRs '[split("\n")[] | fromjson? | select(.type == "text")]
    | if length == 0 then "" else last.part.messageID as $m | map(select(.part.messageID == $m) | .part.text) | join("\n") end' <<<"$out")
  if ((rc == 124)); then err="timed out after ${TIMEOUT}s"; fi
  if [[ -z $err && $rc -ne 0 ]]; then err="opencode exited $rc"; fi
  if [[ -z $err && -z $text ]]; then err="no reply"; fi
  if [[ -n $err ]]; then
    echo "free-models: $1 failed: $err" >&2
    return 1
  fi
  printf 'model=%s session=%s\n%s\n' "$1" "$sid" "$text"
}

run() {
  local explicit="" model tries=0 note="" reg refreshed
  if [[ ${1:-} == --model ]]; then explicit=${2:-}; shift 2 || usage; fi
  [[ $# -ge 3 && -d $1 && -f $3 ]] || usage
  local wt=$1 name=$2 brief session=${4:-}
  brief=$(cat "$3")
  if [[ -n $explicit ]]; then
    attempt "$explicit" "$wt" "$name" "$brief" "$session"
    return
  fi
  reg=$(registry)
  refreshed=$(jq '.refreshed // 0' <<<"$reg")
  if (($(date +%s) - refreshed > REFRESH_EVERY)); then
    refresh && reg=$(registry)
  fi
  for model in $(candidates "$reg"); do
    tries=$((tries + 1))
    ((tries > MAX_TRIES)) && break
    if attempt "$model" "$wt" "$name" "$note$brief" "$session"; then
      mark "$model" ok
      return 0
    fi
    mark "$model" fail "$err"
    note="$RETRY_NOTE"$'\n\n' # a first round retries in a fresh session, a correction round in its own
  done
  echo "free-models: no free model finished the unit; fall back to an Agent-tool worker" >&2
  return 3
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
