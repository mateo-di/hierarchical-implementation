#!/usr/bin/env bash
# Regression suite for free-models.sh: runs it against a stub opencode that fails the models named
# in STUB_FAIL, hangs silently on the ones in STUB_STALL, refuses the ones in STUB_GONE as
# unavailable, and knows no agent named in STUB_NO_AGENT.
# Checks rotation, stalls, cooldown, fallback, sessions, refresh and the registry's integrity.
#   bash skills/hierarchical-implementation/scripts/free-models.test.sh
set -u

SCRIPT="${SCRIPT:-$(dirname "$0")/free-models.sh}"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { # expect <label> <got> <want>
  [[ $2 == "$3" ]] && pass "$1" || fail "$1 (got '$2', wanted '$3')"
}

T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HI_FREE_REGISTRY="$T/registry.json" OPENCODE_BIN="$T/opencode" STUB_LOG="$T/calls.log" STUB_MODELS="$T/models" STUB_MODELS_LOG="$T/models.log" STUB_PIDS="$T/pids" STUB_INTERRUPTS="$T/interrupts"
mkdir -p "$T/wt" "$T/home"
printf 'do the unit\n' >"$T/brief.md"
printf 'opencode/a-free\nopencode/b-free\nopencode/c-free\nanthropic/paid\n' >"$STUB_MODELS"
cat >"$OPENCODE_BIN" <<'EOF'
#!/usr/bin/env bash
[[ $1 == models ]] && { echo "$PWD" >>"$STUB_MODELS_LOG"; cat "$STUB_MODELS"; exit 0; }
[[ $1 == api ]] && { echo "$2 ${4#sessionID=}" >>"$STUB_INTERRUPTS"; exit 0; }
model="" session="" agent="" file=""
while (($#)); do
  case $1 in
    -m) model=$2; shift ;;
    --session) session=$2; shift ;;
    --agent) agent=$2; shift ;;
    -f) file=$2; shift ;;
    --title) shift ;;
    -*) ;;
    *) msg=$1 ;;
  esac
  shift
done
echo $$ >>"$STUB_PIDS"
session=${session:-ses_stub$$}
brief=$(cat "$file")
printf '%s|%s|%s|%s|%s|%s\n' "$model" "$session" "$PWD" "$msg" "${brief//$'\n'/ }" "$agent" >>"$STUB_LOG"
if [[ $agent == "${STUB_NO_AGENT:-}" ]]; then
  printf '{"type":"error","error":{"type":"unknown","message":"Agent not found: \\"%s\\""}}\n' "$agent"
  exit 1
fi
if [[ " ${STUB_STALL:-} " == *" $model "* ]]; then # opencode starts the step, then retries silently
  printf '{"type":"step_start","sessionID":"%s"}\n' "$session"
  sleep 60
  exit 0
fi
if [[ " ${STUB_GONE:-} " == *" $model "* ]]; then # opencode no longer offers the model
  printf '{"type":"error","error":{"type":"unknown","message":"Model unavailable: %s"}}\n' "$model"
  exit 1
fi
if [[ " ${STUB_FAIL:-} " == *" $model "* ]]; then
  printf '{"type":"error","sessionID":"%s","error":{"type":"rate-limit","message":"rate limited"}}\n' "$session"
  exit 1
fi
printf '{"type":"text","sessionID":"%s","part":{"messageID":"m1","text":"narration"}}\n' "$session"
printf '{"type":"text","sessionID":"%s","part":{"messageID":"m2","text":"done by %s"}}\n' "$session" "$model"
EOF
chmod +x "$OPENCODE_BIN"
fm() { bash "$SCRIPT" "$@"; }
calls() { cut -d'|' -f1 "$STUB_LOG" | tr '\n' ' '; }
cool() { jq '.models[].cooldown_until = 0' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"; }

expect "refresh keeps only free models" "$(fm refresh; jq -r '.models | keys_unsorted | join(" ")' "$HI_FREE_REGISTRY")" "opencode/a-free opencode/b-free opencode/c-free"

out=$(HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit1 "$T/brief.md")
expect "a preferred model is tried first" "$(head -n 1 <<<"$out" | cut -d' ' -f1)" "model=opencode/b-free"
expect "the run reports the worker's session" "$(head -n 1 <<<"$out" | cut -d' ' -f2)" "session=$(cut -d'|' -f2 "$STUB_LOG")"
expect "the reply is the worker's last message" "$(tail -n 1 <<<"$out")" "done by opencode/b-free"
expect "the worker runs in the worktree" "$(cut -d'|' -f3 "$STUB_LOG")" "$T/wt"
expect "the brief is attached as a file" "$(cut -d'|' -f5 "$STUB_LOG")" "do the unit"
expect "the worker runs as the restricted agent" "$(cut -d'|' -f6 "$STUB_LOG")" "lane-worker"

: >"$STUB_LOG"
out=$(STUB_FAIL="opencode/b-free" HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit2 "$T/brief.md" 2>"$T/err")
expect "a failed model hands over to the next" "$(calls)" "opencode/b-free opencode/a-free "
expect "the run reports the model that finished" "$(head -n 1 <<<"$out" | cut -d' ' -f1)" "model=opencode/a-free"
expect "each model of a first round gets its own session" "$(cut -d'|' -f2 "$STUB_LOG" | sort -u | grep -c '^ses_stub')" "2"
grep -q 'opencode/b-free failed: rate limited' "$T/err" && pass "the failure is reported on stderr" || fail "stderr: $(cat "$T/err")"
grep -q '^opencode/a-free|[^|]*|[^|]*|An earlier attempt' "$STUB_LOG" && pass "the retry tells the next model to check the worktree" || fail "retry note missing"
expect "the failed model is cooling down" "$(fm list | grep b-free | cut -f2,3)" $'cooling down\trate limited'

: >"$STUB_LOG"
HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit3 "$T/brief.md" >/dev/null
expect "a cooling model is skipped" "$(calls)" "opencode/a-free "

: >"$STUB_LOG"
STUB_FAIL="opencode/a-free opencode/c-free" fm run "$T/wt" unit4 "$T/brief.md" >/dev/null 2>"$T/err"
expect "no free model finishing exits 3" "$?" "3"
grep -q 'fall back to an Agent-tool worker' "$T/err" && pass "the fallback is named" || fail "stderr: $(cat "$T/err")"

cool
: >"$STUB_LOG" && : >"$STUB_PIDS" && : >"$STUB_INTERRUPTS"
out=$(STUB_STALL="opencode/a-free" HI_FREE_STALL=2 fm run "$T/wt" unit5 "$T/brief.md" 2>"$T/err")
expect "a silent model hands over to the next" "$(calls)" "opencode/a-free opencode/b-free "
grep -q 'opencode/a-free failed: printed nothing for 2s' "$T/err" && pass "the stall is reported" || fail "stderr: $(cat "$T/err")"
kill -0 "$(head -n 1 "$STUB_PIDS")" 2>/dev/null && fail "the stalled worker still runs" || pass "the stalled worker is stopped"
expect "the stalled session is interrupted on the service" "$(cat "$STUB_INTERRUPTS")" "session.interrupt $(head -n 1 "$STUB_LOG" | cut -d'|' -f2)"

cool
: >"$STUB_LOG"
STUB_FAIL="opencode/a-free" fm run "$T/wt" unit6 "$T/brief.md" ses_old >/dev/null 2>&1
expect "a correction round keeps its session on every model" "$(cut -d'|' -f2 "$STUB_LOG" | tr '\n' ' ')" "ses_old ses_old "

: >"$STUB_LOG"
STUB_FAIL="opencode/x-paid" fm run --model opencode/x-paid "$T/wt" unit7 "$T/brief.md" >/dev/null 2>&1
expect "an explicit model that fails exits 1" "$?" "1"
expect "an explicit model is not rotated" "$(calls)" "opencode/x-paid "
fm run --model "" "$T/wt" unit7 "$T/brief.md" >/dev/null 2>&1
expect "an empty explicit model is a wrong call, not a rotation" "$?" "1"
OPENCODE_BIN="$T/missing" fm run --model opencode/x-paid "$T/wt" unit7 "$T/brief.md" >/dev/null 2>&1
expect "an explicit model without opencode exits 1, never a fallback" "$?" "1"
HI_FREE_STALL=abc fm run --model opencode/x-paid "$T/wt" unit7 "$T/brief.md" >/dev/null 2>&1
expect "an explicit model with a malformed setting exits 1" "$?" "1"
STUB_NO_AGENT=lane-worker fm run --model opencode/x-paid "$T/wt" unit7 "$T/brief.md" >/dev/null 2>"$T/err"
expect "an explicit model without the restricted agent exits 1" "$?" "1"
grep -q 'no agent named lane-worker.*opencode/x-paid did not run' "$T/err" && pass "the explicit failure names the model" || fail "stderr: $(cat "$T/err")"

cool
cp "$HI_FREE_REGISTRY" "$T/before.json"
STUB_NO_AGENT=lane-worker fm run "$T/wt" unit8 "$T/brief.md" >/dev/null 2>"$T/err"
expect "a missing restricted agent exits 3" "$?" "3"
grep -q 'no agent named lane-worker' "$T/err" && pass "the missing agent is named" || fail "stderr: $(cat "$T/err")"
cmp -s "$T/before.json" "$HI_FREE_REGISTRY" && pass "a missing agent marks no model" || fail "registry changed"
HI_FREE_COOLDOWN=1h fm run "$T/wt" unit9 "$T/brief.md" >/dev/null 2>"$T/err"
expect "a malformed setting exits 3" "$?" "3"
cmp -s "$T/before.json" "$HI_FREE_REGISTRY" && pass "a malformed setting leaves the registry as it was" || fail "registry changed"
OPENCODE_BIN="$T/missing" fm run "$T/wt" unit10 "$T/brief.md" >/dev/null 2>&1
expect "a missing opencode exits 3" "$?" "3"

: >"$STUB_LOG"
printf -- '- fix the parser\n' >"$T/dash.md"
(cd "$T" && HI_FREE_MODELS_PREFER="opencode/a-free" bash "$SCRIPT" run wt unit11 dash.md >/dev/null)
expect "a relative brief that starts with a dash still reaches the worker" "$(cut -d'|' -f5 "$STUB_LOG")" "- fix the parser"

ok=0
for _ in 1 2 3 4 5; do
  cool
  STUB_FAIL="opencode/a-free opencode/b-free" HI_FREE_MAX_TRIES=1 HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" p1 "$T/brief.md" >/dev/null 2>&1 &
  STUB_FAIL="opencode/a-free opencode/b-free" HI_FREE_MAX_TRIES=1 HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" p2 "$T/brief.md" >/dev/null 2>&1 &
  wait
  [[ $(fm list | grep -c 'cooling down') == 2 ]] && ok=$((ok + 1))
done
expect "parallel failures keep both cooldowns" "$ok" "5"

cool
mkdir "$HI_FREE_REGISTRY.lock"
STUB_FAIL="opencode/a-free" HI_FREE_MAX_TRIES=1 HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" unit14 "$T/brief.md" >/dev/null 2>&1
expect "a stale lock is taken over and released" "$(fm list | grep -c 'cooling down'):$([[ -d $HI_FREE_REGISTRY.lock ]] && echo held || echo free)" "1:free"

printf '{"refreshed": 9999999999, "models": {' >"$HI_FREE_REGISTRY"
fm run "$T/wt" unit13 "$T/brief.md" >/dev/null 2>&1
expect "a corrupt registry is rebuilt by the next run" "$?:$(jq -r '.models | keys_unsorted | join(" ")' "$HI_FREE_REGISTRY")" "0:opencode/a-free opencode/b-free opencode/c-free"

cp "$HI_FREE_REGISTRY" "$T/before.json"
: >"$STUB_MODELS"
fm refresh 2>/dev/null
expect "a refresh that finds no models fails" "$?" "1"
cmp -s "$T/before.json" "$HI_FREE_REGISTRY" && pass "a failed refresh keeps the old list" || fail "registry changed"

printf 'opencode/a-free\nopencode/new-free\n' >"$STUB_MODELS"
jq '.refreshed = 0' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"
fm run "$T/wt" unit12 "$T/brief.md" >/dev/null
expect "a day-old registry refreshes before a run" "$(jq -r '.models | keys_unsorted | join(" ")' "$HI_FREE_REGISTRY")" "opencode/a-free opencode/new-free"

: >"$STUB_LOG" && : >"$STUB_MODELS_LOG"
jq '.models += {"opencode/gone1-free": {}, "opencode/gone2-free": {}}' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"
HOME="$T/home" STUB_GONE="opencode/gone1-free opencode/gone2-free" HI_FREE_MODELS_PREFER="opencode/gone1-free opencode/gone2-free" fm run "$T/wt" unit15 "$T/brief.md" >/dev/null 2>&1
expect "an unavailable model hands over, and the other stale one is skipped unstarted" "$(calls)" "opencode/gone1-free opencode/a-free "
expect "models opencode no longer lists leave the registry" "$(jq -r '.models | keys_unsorted | join(" ")' "$HI_FREE_REGISTRY")" "opencode/a-free opencode/new-free"
expect "the run re-reads opencode's list once, from the home directory" "$(cat "$STUB_MODELS_LOG")" "$T/home"
grep -q '^opencode/a-free|[^|]*|[^|]*|An earlier attempt' "$STUB_LOG" && fail "a model that never ran sent the retry note" || pass "a model that never ran sends no retry note"

printf 'opencode/a-free\nopencode/b-free\n' >"$STUB_MODELS"
fm refresh
STUB_GONE="opencode/b-free" HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit16 "$T/brief.md" >/dev/null 2>&1
expect "an unavailable model opencode still lists stays and cools down" "$(fm list | grep b-free | cut -f2,3)" $'cooling down\tModel unavailable: opencode/b-free'

printf 'opencode/c-free\nopencode/d-free\n' >"$STUB_MODELS"
fm refresh
printf 'anthropic/paid\n' >"$STUB_MODELS" && : >"$STUB_MODELS_LOG"
STUB_GONE="opencode/c-free opencode/d-free" fm run "$T/wt" unit17 "$T/brief.md" >/dev/null 2>&1
expect "a failed re-read is not retried for the next unavailable model" "$(grep -c . "$STUB_MODELS_LOG")" "1"
expect "a failed re-read keeps the old list, and its models cool down" "$(fm list | grep -c 'cooling down')" "2"

fm bogus >/dev/null 2>&1
expect "an unknown command exits 1" "$?" "1"

((fails == 0)) && echo "all passed" || { echo "$fails failed"; exit 1; }
