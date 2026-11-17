#!/usr/bin/env bash
# Regression suite for free-models.sh: runs it against a stub opencode that fails the models
# named in STUB_FAIL, and checks rotation, cooldown, fallback, sessions and refresh.
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
export HI_FREE_REGISTRY="$T/registry.json" OPENCODE_BIN="$T/opencode" STUB_LOG="$T/calls.log" STUB_MODELS="$T/models"
mkdir -p "$T/wt"
printf 'do the unit\n' >"$T/brief.md"
printf 'opencode/a-free\nopencode/b-free\nopencode/c-free\nanthropic/paid\n' >"$STUB_MODELS"
cat >"$OPENCODE_BIN" <<'EOF'
#!/usr/bin/env bash
[[ $1 == models ]] && { cat "$STUB_MODELS"; exit 0; }
model="" session=ses_new
while (($#)); do
  case $1 in
    -m) model=$2; shift ;;
    --session) session=$2; shift ;;
    --title) shift ;;
    -*) ;;
    *) msg=$1 ;;
  esac
  shift
done
printf '%s|%s|%s|%s\n' "$model" "$session" "$PWD" "${msg//$'\n'/ }" >>"$STUB_LOG"
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

expect "refresh keeps only free models" "$(fm refresh; jq -r '.models | keys_unsorted | join(" ")' "$HI_FREE_REGISTRY")" "opencode/a-free opencode/b-free opencode/c-free"

out=$(HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit1 "$T/brief.md")
expect "a preferred model is tried first" "$(head -n 1 <<<"$out")" "model=opencode/b-free session=ses_new"
expect "the reply is the worker's last message" "$(tail -n 1 <<<"$out")" "done by opencode/b-free"
expect "the worker runs in the worktree" "$(cut -d'|' -f3 "$STUB_LOG")" "$T/wt"

: >"$STUB_LOG"
out=$(STUB_FAIL="opencode/b-free" HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit2 "$T/brief.md" 2>"$T/err")
expect "a failed model hands over to the next" "$(calls)" "opencode/b-free opencode/a-free "
expect "the run reports the model that finished" "$(head -n 1 <<<"$out")" "model=opencode/a-free session=ses_new"
grep -q 'opencode/b-free failed: rate limited' "$T/err" && pass "the failure is reported on stderr" || fail "stderr: $(cat "$T/err")"
grep -q '^opencode/a-free|.*|An earlier attempt' "$STUB_LOG" && pass "the retry tells the next model to check the worktree" || fail "retry note missing"
expect "the failed model is cooling down" "$(fm list | grep b-free | cut -f2,3)" $'cooling down\trate limited'

: >"$STUB_LOG"
HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit3 "$T/brief.md" >/dev/null
expect "a cooling model is skipped" "$(calls)" "opencode/a-free "

: >"$STUB_LOG"
STUB_FAIL="opencode/a-free opencode/c-free" fm run "$T/wt" unit4 "$T/brief.md" >/dev/null 2>"$T/err"
expect "no free model finishing exits 3" "$?" "3"
grep -q 'fall back to an Agent-tool worker' "$T/err" && pass "the fallback is named" || fail "stderr: $(cat "$T/err")"

jq '.models[].cooldown_until = 0' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"
: >"$STUB_LOG"
STUB_FAIL="opencode/a-free" fm run "$T/wt" unit5 "$T/brief.md" ses_old >/dev/null 2>&1
expect "a correction round keeps its session on every model" "$(cut -d'|' -f2 "$STUB_LOG" | tr '\n' ' ')" "ses_old ses_old "

: >"$STUB_LOG"
STUB_FAIL="opencode/x-paid" fm run --model opencode/x-paid "$T/wt" unit6 "$T/brief.md" >/dev/null 2>&1
expect "an explicit model that fails exits 1" "$?" "1"
expect "an explicit model is not rotated" "$(calls)" "opencode/x-paid "

printf 'opencode/a-free\nopencode/new-free\n' >"$STUB_MODELS"
jq '.refreshed = 0' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"
fm run "$T/wt" unit7 "$T/brief.md" >/dev/null
expect "a day-old registry refreshes before a run" "$(jq -r '.models | keys_unsorted | join(" ")' "$HI_FREE_REGISTRY")" "opencode/a-free opencode/new-free"

fm bogus >/dev/null 2>&1
expect "an unknown command exits 1" "$?" "1"

((fails == 0)) && echo "all passed" || { echo "$fails failed"; exit 1; }
