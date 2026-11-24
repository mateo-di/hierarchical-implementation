#!/usr/bin/env bash
# Regression suite for free-models.sh. The stub opencode answers `opencode models` from a list and
# execs test/fake-acp-agent.mjs for `opencode acp`; the stub agy does the same with FAKE_ACP_STYLE=agy.
# Every stub call appends its argv to STUB_LOG and the fake agent appends its ACP traffic to
# STUB_AGENT_LOG. STUB_FAIL, STUB_STALL, STUB_ASK and STUB_GONE select the fake agent's behaviour.
# Covers rotation, stalls, asks, answers, stop, cooldown, fallback, sessions, refresh and the
# registry's integrity.
#   bash skills/hierarchical-implementation/scripts/free-models.test.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT="${SCRIPT:-$HERE/free-models.sh}"
ACP_AGENT="${ACP_AGENT:-$HERE/test/fake-acp-agent.mjs}"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { # expect <label> <got> <want>
  [[ $2 == "$3" ]] && pass "$1" || fail "$1 (got '$2', wanted '$3')"
}

T=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$T"' EXIT
export HI_FREE_REGISTRY="$T/registry.json" HI_FREE_RUNS="$T/runs" HI_FREE_STALL=10 HI_FREE_TIMEOUT=30 OPENCODE_BIN="$T/opencode" AGY_BIN="$T/agy" ACP_AGENT STUB_LOG="$T/calls.log" STUB_AGENT_LOG="$T/agent.log" STUB_MODELS="$T/models" STUB_MODELS_LOG="$T/models.log" STUB_UMASK_LOG="$T/umask.log"
mkdir -p "$T/wt" "$T/home" "$T/runs"
printf 'do the unit\n' >"$T/brief.md"
printf 'opencode/a-free\nopencode/b-free\nopencode/c-free\nanthropic/paid\n' >"$STUB_MODELS"
cat >"$OPENCODE_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'opencode %s\n' "$*" >>"$STUB_LOG"
umask >>"$STUB_UMASK_LOG"
if [[ $1 == models ]]; then
  echo "$PWD" >>"$STUB_MODELS_LOG"
  cat "$STUB_MODELS"
  exit 0
fi
models=$(tr '\n' ' ' <"$STUB_MODELS")
for m in ${STUB_GONE:-}; do
  models=$(for x in $models; do [[ $x != "$m" ]] && printf '%s\n' "$x"; done | tr '\n' ' ')
done
export FAKE_ACP_MODELS="$models"
export FAKE_ACP_MODES="${STUB_MODES:-build lane-worker}"
export FAKE_ACP_FAIL="${STUB_FAIL:-}"
export FAKE_ACP_STALL="${STUB_STALL:-}"
export FAKE_ACP_ASK="${STUB_ASK:-}"
export FAKE_ACP_ASK_TITLE="${STUB_ASK_TITLE:-}"
export FAKE_ACP_ASK_COMMAND="${STUB_ASK_COMMAND:-}"
export FAKE_ACP_LOG="$STUB_AGENT_LOG"
exec node "$ACP_AGENT"
EOF
chmod +x "$OPENCODE_BIN"
cat >"$AGY_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'agy %s\n' "$*" >>"$STUB_LOG"
export FAKE_ACP_STYLE=agy
export FAKE_ACP_MODELS="${STUB_AGY_MODELS:-m1}"
export FAKE_ACP_MODES="${STUB_AGY_MODES:-default auto plan}"
export FAKE_ACP_FAIL="${STUB_FAIL:-}"
export FAKE_ACP_ASK="${STUB_ASK:-}"
export FAKE_ACP_ASK_TITLE="${STUB_ASK_TITLE:-}"
export FAKE_ACP_LOG="$STUB_AGENT_LOG"
exec node "$ACP_AGENT"
EOF
chmod +x "$AGY_BIN"
fm() { bash "$SCRIPT" "$@"; }
clear_logs() { : >"$STUB_LOG"; : >"$STUB_AGENT_LOG"; }
cool() { jq '.models[].cooldown_until = 0' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"; }
used_models() {
  jq -r 'if .method == "session/set_model" then .params.modelId
         elif .method == "session/set_config_option" and .params.configId == "model" then .params.value
         else empty end' "$STUB_AGENT_LOG" 2>/dev/null
}
calls() { used_models | tr '\n' ' '; }
new_sessions() { grep -c '"method":"session/new"' "$STUB_AGENT_LOG"; }
brief_text() { jq -r 'select(.method == "session/prompt") | .params.prompt[1].resource.text' "$STUB_AGENT_LOG" 2>/dev/null | tr -d '\n'; }
ask_id_of() { local line=${1%%$'\n'*}; line=${line#ask=}; printf '%s' "${line%% *}"; }
run_id_of() { local line=${1%%$'\n'*}; line=${line#* run=}; printf '%s' "${line%% *}"; }

expect "refresh keeps only free models" "$(fm refresh; jq -r '.models | keys_unsorted | join(" ")' "$HI_FREE_REGISTRY")" "opencode/a-free opencode/b-free opencode/c-free"

clear_logs
out=$(HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit1 "$T/brief.md")
expect "a preferred model is tried first" "$(head -n 1 <<<"$out" | cut -d' ' -f1)" "model=opencode/b-free"
expect "the run reports the worker's session" "$(head -n 1 <<<"$out" | cut -d' ' -f2)" "session=fake-session-1"
expect "the reply is the worker's last message" "$(tail -n 1 <<<"$out")" "done by opencode/b-free"
expect "the worker runs in the worktree" "$(jq -r 'select(.method == "session/new") | .params.cwd' "$STUB_AGENT_LOG")" "$T/wt"
expect "the brief is attached as a file" "$(brief_text)" "do the unit"
expect "the worker runs as the restricted agent" "$(jq -r 'select(.method == "session/set_config_option" and .params.configId == "mode") | .params.value' "$STUB_AGENT_LOG")" "lane-worker"
expect "the run uses the ACP server" "$(cat "$STUB_LOG")" "opencode acp"
expect "no bypass flags are used" "$(grep -c -e '--auto' -e ' run ' -e ' -p' -e '--dangerously' "$STUB_LOG")" "0"

clear_logs
out=$(STUB_FAIL="opencode/b-free" HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit2 "$T/brief.md" 2>"$T/err")
expect "a failed model hands over to the next" "$(calls)" "opencode/b-free opencode/a-free "
expect "the run reports the model that finished" "$(head -n 1 <<<"$out" | cut -d' ' -f1)" "model=opencode/a-free"
expect "each attempt opens its own session" "$(new_sessions)" "2"
grep -q 'opencode/b-free failed: rate limited' "$T/err" && pass "the failure is reported on stderr" || fail "stderr: $(cat "$T/err")"
grep -q 'An earlier attempt' "$STUB_AGENT_LOG" && pass "the retry tells the next model to check the worktree" || fail "retry note missing"
expect "the failed model is cooling down" "$(fm list | grep b-free | cut -f2,3)" $'cooling down\trate limited'

clear_logs
HI_FREE_MODELS_PREFER="opencode/b-free" fm run "$T/wt" unit3 "$T/brief.md" >/dev/null
expect "a cooling model is skipped" "$(calls)" "opencode/a-free "

clear_logs
STUB_FAIL="opencode/a-free opencode/c-free" fm run "$T/wt" unit4 "$T/brief.md" >/dev/null 2>"$T/err"
expect "no free model finishing exits 3" "$?" "3"
grep -q 'fall back to an Agent-tool worker' "$T/err" && pass "the fallback is named" || fail "stderr: $(cat "$T/err")"

cool
clear_logs
out=$(STUB_STALL="opencode/a-free" HI_FREE_STALL=1 fm run "$T/wt" unit5 "$T/brief.md" 2>"$T/err")
expect "a silent model hands over to the next" "$(calls)" "opencode/a-free opencode/b-free "
grep -q 'opencode/a-free failed: printed nothing for 1s (rate limited or stuck)' "$T/err" && pass "the stall is reported" || fail "stderr: $(cat "$T/err")"
grep -q '"method":"session/cancel"' "$STUB_AGENT_LOG" && pass "the stalled worker is stopped" || fail "no cancel in the agent log"
expect "a stalled run leaves no run dir" "$(find "$HI_FREE_RUNS" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0"

cool
clear_logs
STUB_FAIL="opencode/a-free" fm run "$T/wt" unit6 "$T/brief.md" ses_old >/dev/null 2>&1
expect "a correction round keeps its session on every model" "$(jq -r 'select(.method == "session/resume") | .params.sessionId' "$STUB_AGENT_LOG" | tr '\n' ' ')" "ses_old ses_old "

clear_logs
STUB_FAIL="opencode/a-free" fm run --model opencode/a-free "$T/wt" unit7 "$T/brief.md" >/dev/null 2>&1
expect "an explicit model that fails exits 1" "$?" "1"
expect "an explicit model is not rotated" "$(calls)" "opencode/a-free "
fm run --model "" "$T/wt" unit7 "$T/brief.md" >/dev/null 2>&1
expect "an empty explicit model is a wrong call, not a rotation" "$?" "1"
OPENCODE_BIN="$T/missing" fm run --model opencode/a-free "$T/wt" unit7 "$T/brief.md" >/dev/null 2>&1
expect "an explicit model without opencode exits 1, never a fallback" "$?" "1"
HI_FREE_STALL=abc fm run --model opencode/a-free "$T/wt" unit7 "$T/brief.md" >/dev/null 2>&1
expect "an explicit model with a malformed setting exits 1" "$?" "1"
clear_logs
STUB_MODES="build" fm run --model opencode/a-free "$T/wt" unit7 "$T/brief.md" >/dev/null 2>"$T/err"
expect "an explicit model without the restricted agent exits 1" "$?" "1"
grep -q 'no agent named lane-worker.*opencode/a-free did not run' "$T/err" && pass "the explicit failure names the model" || fail "stderr: $(cat "$T/err")"

cool
cp "$HI_FREE_REGISTRY" "$T/before.json"
clear_logs
STUB_MODES="build" fm run "$T/wt" unit8 "$T/brief.md" >/dev/null 2>"$T/err"
expect "a missing restricted agent exits 3" "$?" "3"
grep -q 'install the worker agent from the plugin' "$T/err" && pass "the install message is named" || fail "stderr: $(cat "$T/err")"
cmp -s "$T/before.json" "$HI_FREE_REGISTRY" && pass "a missing agent marks no model" || fail "registry changed"
HI_FREE_COOLDOWN=1h fm run "$T/wt" unit9 "$T/brief.md" >/dev/null 2>"$T/err"
expect "a malformed setting exits 3" "$?" "3"
cmp -s "$T/before.json" "$HI_FREE_REGISTRY" && pass "a malformed setting leaves the registry as it was" || fail "registry changed"
OPENCODE_BIN="$T/missing" fm run "$T/wt" unit10 "$T/brief.md" >/dev/null 2>&1
expect "a missing opencode exits 3" "$?" "3"
HI_FREE_ASK_TIMEOUT=1h fm run "$T/wt" unit10 "$T/brief.md" >/dev/null 2>&1
expect "a malformed ask timeout exits 3" "$?" "3"

clear_logs
printf -- '- fix the parser\n' >"$T/dash.md"
(cd "$T" && HI_FREE_MODELS_PREFER="opencode/a-free" bash "$SCRIPT" run wt unit11 dash.md >/dev/null)
expect "a relative brief that starts with a dash still reaches the worker" "$(brief_text)" "- fix the parser"

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

clear_logs; : >"$STUB_MODELS_LOG"
jq '.models += {"opencode/gone1-free": {}, "opencode/gone2-free": {}}' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"
out=$(HOME="$T/home" STUB_GONE="opencode/gone1-free opencode/gone2-free" HI_FREE_MODELS_PREFER="opencode/gone1-free opencode/gone2-free" fm run "$T/wt" unit15 "$T/brief.md" 2>"$T/err")
expect "an unavailable model hands over, and the other stale one is skipped unstarted" "$(new_sessions):$(head -n 1 <<<"$out" | cut -d' ' -f1)" "2:model=opencode/a-free"
expect "models opencode no longer lists leave the registry" "$(jq -r '.models | keys_unsorted | join(" ")' "$HI_FREE_REGISTRY")" "opencode/a-free opencode/new-free"
expect "the run re-reads opencode's list once, from the home directory" "$(cat "$STUB_MODELS_LOG")" "$T/home"
grep -q 'An earlier attempt' "$STUB_AGENT_LOG" && fail "a model that never ran sent the retry note" || pass "a model that never ran sends no retry note"

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

printf 'opencode/a-free\n' >"$STUB_MODELS"
fm refresh
clear_logs
out=$(fm run --model agy/m1 "$T/wt" ua1 "$T/brief.md")
expect "an agy model runs through agy's ACP server" "$(cat "$STUB_LOG")" "agy acp"
expect "no bypass flags reach agy" "$(grep -c -e '--auto' -e ' -p' -e '--dangerously' "$STUB_LOG")" "0"
expect "agy runs in Auto mode" "$(jq -r 'select(.method == "session/set_config_option" and .params.configId == "mode") | .params.value' "$STUB_AGENT_LOG")" "auto"
expect "agy runs in the worktree" "$(jq -r 'select(.method == "session/new") | .params.cwd' "$STUB_AGENT_LOG")" "$T/wt"
expect "agy gets the brief attached" "$(brief_text)" "do the unit"
expect "agy reports its conversation, marked agy:, as the session" "$(head -n 1 <<<"$out")" "model=agy/m1 session=agy:fake-session-1"
expect "agy's reply is its last message" "$(tail -n 1 <<<"$out")" "done by m1"
clear_logs
out=$(fm run --model agy/m1 "$T/wt" ua1 "$T/brief.md" agy:conv_old)
expect "an agy correction continues its conversation" "$(jq -r 'select(.method == "session/resume") | .params.sessionId' "$STUB_AGENT_LOG"):$(head -n 1 <<<"$out" | cut -d' ' -f2)" "conv_old:session=agy:conv_old"
fm run --model agy/ "$T/wt" ua1 "$T/brief.md" >/dev/null 2>&1
expect "an agy model with no id is a wrong call" "$?" "1"
OPENCODE_BIN="$T/missing" fm run --model agy/m1 "$T/wt" ua1 "$T/brief.md" >/dev/null 2>&1
expect "an explicit agy model needs no opencode" "$?" "0"
AGY_BIN="$T/missing" fm run --model agy/m1 "$T/wt" ua1 "$T/brief.md" >/dev/null 2>"$T/err"
expect "an explicit agy model without agy exits 1" "$?" "1"
grep -q 'agy is not installed; agy/m1 did not run' "$T/err" && pass "the missing agy is named" || fail "stderr: $(cat "$T/err")"
STUB_FAIL="m1" fm run --model agy/m1 "$T/wt" ua1 "$T/brief.md" >/dev/null 2>"$T/err"
expect "an agy failure exits 1" "$?" "1"
grep -q 'agy/m1 failed: rate limited' "$T/err" && pass "the agy error is reported" || fail "stderr: $(cat "$T/err")"

: >"$STUB_MODELS"
printf 'opencode/a-free\n' >"$STUB_MODELS"
fm refresh
clear_logs
STUB_FAIL="m1" HI_FREE_MODELS_PREFER="agy/m1 opencode/a-free" fm run "$T/wt" ua2 "$T/brief.md" >/dev/null 2>&1
expect "a preferred agy model is tried first, then the rotation" "$(grep -c 'agy acp' "$STUB_LOG"):$(used_models | tr '\n' ' ')" "1:m1 opencode/a-free "
expect "a failed agy model cools down" "$(fm list | grep agy/m1 | cut -f2)" "cooling down"
fm refresh
expect "a refresh keeps an agy model's cooldown" "$(fm list | grep agy/m1 | cut -f2)" "cooling down"
cool
clear_logs
HI_FREE_MODELS_PREFER="agy/m1 opencode/a-free" fm run "$T/wt" ua5 "$T/brief.md" ses_x >/dev/null 2>&1
expect "an opencode session is not sent to agy" "$(grep -c 'agy acp' "$STUB_LOG"):$(jq -r 'select(.method == "session/resume") | .params.sessionId' "$STUB_AGENT_LOG")" "0:ses_x"
clear_logs
HI_FREE_MODELS_PREFER="agy/m1 opencode/a-free" fm run "$T/wt" ua6 "$T/brief.md" agy:c1 >/dev/null 2>&1
expect "an agy session is not sent to opencode" "$(grep -c 'agy acp' "$STUB_LOG"):$(new_sessions)" "1:0"
fm run "$T/wt" ua8 "$T/brief.md" agy:c1 >/dev/null 2>"$T/err"
expect "an agy session with no agy model preferred falls back" "$?" "3"
grep -q 'no agy model is preferred and ready to continue session agy:c1' "$T/err" && pass "the fallback names the session's backend" || fail "stderr: $(cat "$T/err")"
clear_logs
fm run --model opencode/a-free "$T/wt" ua9 "$T/brief.md" agy:c1 >/dev/null 2>"$T/err"
expect "an explicit model with another backend's session is a wrong call" "$?:$(new_sessions)" "1:0"
grep -q 'session agy:c1 belongs to agy, not opencode' "$T/err" && pass "the session mismatch is named" || fail "stderr: $(cat "$T/err")"
fm run --model agy/m1 "$T/wt" ua9 "$T/brief.md" ses_x >/dev/null 2>&1
expect "an explicit agy model with an opencode session is a wrong call" "$?:$(grep -c 'agy acp' "$STUB_LOG")" "1:0"
clear_logs
fm run "$T/wt" ua3 "$T/brief.md" >/dev/null 2>&1
expect "an agy model the registry holds but no one prefers is not tried" "$(grep -c 'agy acp' "$STUB_LOG"):$(used_models | tr '\n' ' ')" "0:opencode/a-free "
AGY_BIN="$T/missing" HI_FREE_MODELS_PREFER="agy/m1" fm run "$T/wt" ua4 "$T/brief.md" >/dev/null 2>&1
expect "a preferred agy model is skipped when agy is not installed" "$?:$(grep -c 'agy acp' "$STUB_LOG")" "0:0"

# An ask stops a run, and the driver answers it from the run directory.
cool
clear_logs
out=$(STUB_ASK="opencode/a-free" HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" ask1 "$T/brief.md" 2>"$T/err")
expect "a pending ask exits 4" "$?" "4"
grep -Eq '^ask=a[0-9a-f]{16} run=' <<<"$out" && pass "the ask block names the ask and the run" || fail "stdout: $out"
grep -q '^action: execute$' <<<"$out" && pass "the ask names the action" || fail "stdout: $out"
grep -q '^title: uname -a$' <<<"$out" && pass "the ask names the title" || fail "stdout: $out"
grep -q '^input: {"command":"uname -a"}$' <<<"$out" && pass "the ask shows the compact input" || fail "stdout: $out"
grep -q '^answer: free-models.sh answer ' <<<"$out" && pass "the ask shows how to answer" || fail "stdout: $out"
expect "an ask leaves the worker waiting" "$(find "$HI_FREE_RUNS" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "1"
run1=$(run_id_of "$out")
expect "a run dir is private to the user" "$(ls -ld "$HI_FREE_RUNS/$run1" | cut -c1-10)" "drwx------"
out=$(fm answer "$run1" "$(ask_id_of "$out")" once)
expect "answering once finishes the worker" "$?" "0"
expect "the answer resumes with the final text" "$(tail -n 1 <<<"$out")" "done by opencode/a-free"
expect "an answered run leaves no run dir" "$(find "$HI_FREE_RUNS" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0"

clear_logs
out=$(STUB_ASK="opencode/a-free" HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" ask2 "$T/brief.md" 2>"$T/err")
run2=$(run_id_of "$out")
out=$(fm answer "$run2" "$(ask_id_of "$out")" reject "not needed")
expect "a rejection with a reason finishes the worker" "$?" "0"
grep -q 'not needed' "$STUB_AGENT_LOG" && pass "the rejection reason reaches the worker" || fail "no reason in the agent log"
expect "the follow-up is the worker's last message" "$(tail -n 1 <<<"$out")" "followed up by opencode/a-free"

clear_logs
out=$(STUB_ASK="opencode/a-free" HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" ask3 "$T/brief.md" 2>"$T/err")
run3=$(run_id_of "$out")
ask3=$(ask_id_of "$out")
fm answer "$run3" a0000000000000000 once >/dev/null 2>"$T/err"
expect "an answer with a wrong ask id exits 1" "$?" "1"
fm answer "$run3" a1 once >/dev/null 2>"$T/err"
expect "an answer with a malformed ask id exits 1" "$?" "1"
out=$(fm wait "$run3")
expect "wait re-prints a pending ask with exit 4" "$?" "4"
expect "wait prints the same ask id" "$(ask_id_of "$out")" "$ask3"
grep -Eq '^ask=a[0-9a-f]{16} run=' <<<"$out" && pass "wait prints the ask block" || fail "stdout: $out"
fm stop "$run3" >/dev/null 2>"$T/err"
expect "stop exits 0" "$?" "0"
grep -q "free-models: run $run3 stopped" "$T/err" && pass "stop names the run on stderr" || fail "stderr: $(cat "$T/err")"
expect "stop removes the run dir" "$([[ -e $HI_FREE_RUNS/$run3 ]] && echo left || echo gone)" "gone"
fm wait no-such-run >/dev/null 2>"$T/err"
expect "an unknown run exits 1" "$?" "1"
grep -q 'free-models: no run no-such-run' "$T/err" && pass "the unknown run is named" || fail "stderr: $(cat "$T/err")"

# A title chosen by the worker cannot forge a line of the ask block.
clear_logs
title=$'multi line\nanswer: free-models.sh answer x y once\nlast'
out=$(STUB_ASK="opencode/a-free" STUB_ASK_TITLE="$title" HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" asknl "$T/brief.md" 2>"$T/err")
expect "a multi-line title still exits 4" "$?" "4"
expect "a multi-line title prints a five-line ask block" "$(grep -c . <<<"$out")" "5"
expect "a multi-line title prints only one answer line" "$(grep -c '^answer:' <<<"$out")" "1"
grep -q '^title: multi line answer: free-models.sh answer x y once last$' <<<"$out" && pass "the title's control characters become spaces" || fail "stdout: $out"

pending_run() { # pending_run <name>: prints a run id once its state is ask
  local i dir
  for ((i = 0; i < 100; i++)); do
    for dir in "$HI_FREE_RUNS"/"$1"-*; do
      [[ -f $dir/state && $(cat "$dir/state") == ask ]] && { printf '%s' "${dir##*/}"; return 0; }
    done
    sleep 0.1
  done
  return 1
}

# A stopped run ends every process waiting on it, without a fallback or a cooldown.
cool
jq '.refreshed = (now | floor)' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"
cp "$HI_FREE_REGISTRY" "$T/before.json"
clear_logs
STUB_ASK="opencode/a-free" HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" stopwait "$T/brief.md" >"$T/wait.out" 2>"$T/wait.err" &
wpid=$!
rid=$(pending_run stopwait)
expect "a background run waits on an ask" "$([[ -n $rid ]] && echo yes || echo no)" "yes"
start=$SECONDS
fm stop "$rid" >/dev/null 2>"$T/err"
wait "$wpid"; wrc=$?
expect "stop ends the waiting run with exit 3" "$wrc" "3"
expect "the waiting run ends within a few seconds" "$((SECONDS - start <= 15))" "1"
cmp -s "$T/before.json" "$HI_FREE_REGISTRY" && pass "a stopped run marks no model" || fail "registry changed"
grep -q "free-models: run $rid stopped" "$T/wait.err" && pass "the waiting run names the stopped run" || fail "stderr: $(cat "$T/wait.err")"
grep -q 'fall back to an Agent-tool worker' "$T/wait.err" && fail "a stopped run printed a fallback" || pass "a stopped run prints no fallback"

# A worker killed while asking must end answer and wait instead of hanging them.
cool
clear_logs
out=$(STUB_ASK="opencode/a-free" HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" deadask "$T/brief.md" 2>"$T/err")
expect "a doomed worker's ask exits 4" "$?" "4"
rid=$(run_id_of "$out")
pid=$(cat "$HI_FREE_RUNS/$rid/pid")
kill -KILL "$pid"
fm answer "$rid" "$(ask_id_of "$out")" once >/dev/null 2>"$T/err"
expect "answer exits when the worker dies" "$?" "3"
grep -q 'acp worker exited without a result' "$T/err" && pass "answer reports the dead worker" || fail "stderr: $(cat "$T/err")"
expect "a dead worker's run dir is removed" "$([[ -e $HI_FREE_RUNS/$rid ]] && echo left || echo gone)" "gone"
cool
out=$(STUB_ASK="opencode/a-free" HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" deadask2 "$T/brief.md" 2>"$T/err")
rid=$(run_id_of "$out")
kill -KILL "$(cat "$HI_FREE_RUNS/$rid/pid")"
fm wait "$rid" >/dev/null 2>"$T/err"
expect "wait exits when the worker dies" "$?" "3"
grep -q 'acp worker exited without a result' "$T/err" && pass "wait reports the dead worker" || fail "stderr: $(cat "$T/err")"

# wait continues an explicit run without giving it a cooldown.
cool
jq '.refreshed = (now | floor)' "$HI_FREE_REGISTRY" >"$T/r" && mv "$T/r" "$HI_FREE_REGISTRY"
cp "$HI_FREE_REGISTRY" "$T/before.json"
clear_logs
out=$(STUB_ASK="opencode/a-free" fm run --model opencode/a-free "$T/wt" expwait "$T/brief.md" 2>"$T/err")
expect "an explicit run exits 4 on an ask" "$?" "4"
rid=$(run_id_of "$out")
jq -n --arg id "$(ask_id_of "$out")" '{id: $id, decision: "once", message: ""}' >"$HI_FREE_RUNS/$rid/answer.json"
for ((i = 0; i < 50; i++)); do
  [[ -f $HI_FREE_RUNS/$rid/state && $(cat "$HI_FREE_RUNS/$rid/state") == done ]] && break
  sleep 0.2
done
out=$(fm wait "$rid")
expect "wait finishes an explicit run" "$?" "0"
expect "wait reports the explicit worker's message" "$(tail -n 1 <<<"$out")" "done by opencode/a-free"
cmp -s "$T/before.json" "$HI_FREE_REGISTRY" && pass "wait on an explicit run leaves the registry untouched" || fail "registry changed"

# Run ids and names reach paths, so only plain names are accepted.
mkdir "$T/victim"
fm stop ../victim >/dev/null 2>"$T/err"
expect "stop of a path-like run id exits 1" "$?" "1"
expect "stop of a path-like run id touches nothing" "$([[ -d $T/victim ]] && echo kept || echo gone)" "kept"
fm wait ../victim >/dev/null 2>&1
expect "wait of a path-like run id exits 1" "$?" "1"
fm answer ../victim a0000000000000000 once >/dev/null 2>&1
expect "answer of a path-like run id exits 1" "$?" "1"
clear_logs
fm run "$T/wt" 'a/b' "$T/brief.md" >/dev/null 2>"$T/err"
expect "a run name holding a slash exits 1" "$?:$(new_sessions)" "1:0"
grep -q "invalid run name 'a/b'" "$T/err" && pass "the invalid name is reported" || fail "stderr: $(cat "$T/err")"
fm run --model opencode/a-free "$T/wt" '..' "$T/brief.md" >/dev/null 2>&1
expect "a dot-dot run name exits 1" "$?" "1"

# A result is final whatever the state says, so a worker that dies between the two cannot hang wait.
mkdir "$HI_FREE_RUNS/orphan-1"
jq -n '{model: "opencode/a-free", backend: "opencode", explicit: true}' >"$HI_FREE_RUNS/orphan-1/request.json"
jq -n '{session: "s", text: "hello", stopReason: "end_turn", error: "", kind: "", denied: []}' >"$HI_FREE_RUNS/orphan-1/result.json"
printf running >"$HI_FREE_RUNS/orphan-1/state"
sleep 0 & dead=$!; wait "$dead"
printf '%s' "$dead" >"$HI_FREE_RUNS/orphan-1/pid"
fm wait orphan-1 >"$T/orphan.out" 2>&1 &
wpid=$!
for ((i = 0; i < 50; i++)); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$wpid" 2>/dev/null; then kill "$wpid"; fail "wait did not end on a result with state running"; else wait "$wpid"; expect "wait ends on a result whose state still says running" "$?:$(tail -n 1 "$T/orphan.out")" "0:hello"; fi

# An ask id that is not 16 hex digits is refused rather than printed.
mkdir "$HI_FREE_RUNS/badask-1"
jq -n '{model: "opencode/a-free", backend: "opencode", explicit: true}' >"$HI_FREE_RUNS/badask-1/request.json"
jq -n '{id: "a1", title: "x", kind: "execute", rawInput: {}}' >"$HI_FREE_RUNS/badask-1/ask.json"
printf ask >"$HI_FREE_RUNS/badask-1/state"
printf '%s' "$$" >"$HI_FREE_RUNS/badask-1/pid"
fm wait badask-1 >"$T/badask.out" 2>"$T/err"
expect "an invalid ask id fails the run and prints no ask" "$?:$(grep -c "^ask=" "$T/badask.out")" "1:0"
grep -q 'invalid ask id' "$T/err" && pass "the invalid ask id is reported" || fail "stderr: $(cat "$T/err")"

# The CLI child keeps the caller's umask, so files a worker writes in the worktree are not private.
: >"$T/umask.log"
cool
(umask 022; HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" umask1 "$T/brief.md" >/dev/null 2>&1)
expect "the worker's CLI keeps the caller's umask" "$(tail -n 1 "$T/umask.log")" "0022"

# An ask whose file is gone for a moment is not an invalid ask.
mkdir "$HI_FREE_RUNS/racy-1"
jq -n '{model: "opencode/a-free", backend: "opencode", explicit: true}' >"$HI_FREE_RUNS/racy-1/request.json"
printf ask >"$HI_FREE_RUNS/racy-1/state"
printf '%s' "$$" >"$HI_FREE_RUNS/racy-1/pid"
fm wait racy-1 >"$T/racy.out" 2>"$T/racy.err" &
wpid=$!
sleep 2
expect "a missing ask file does not fail a healthy run" "$(kill -0 "$wpid" 2>/dev/null && echo waiting || echo ended)" "waiting"
jq -n '{session: "s", text: "hello", stopReason: "end_turn", error: "", kind: "", denied: []}' >"$HI_FREE_RUNS/racy-1/result.json"
for ((i = 0; i < 50; i++)); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$wpid" 2>/dev/null; then kill "$wpid"; fail "wait did not end once the result appeared"; else wait "$wpid"; expect "wait finishes once the result appears" "$?:$(tail -n 1 "$T/racy.out")" "0:hello"; fi

# stop does not wait for a worker that is already dead.
mkdir "$HI_FREE_RUNS/dead-1"
printf running >"$HI_FREE_RUNS/dead-1/state"
sleep 0 & dead=$!; wait "$dead"
printf '%s' "$dead" >"$HI_FREE_RUNS/dead-1/pid"
start=$SECONDS
fm stop dead-1 >/dev/null 2>&1
expect "stop on a dead worker returns at once and removes the run" "$((SECONDS - start <= 5)):$([[ -e $HI_FREE_RUNS/dead-1 ]] && echo left || echo gone)" "1:gone"

# A cut field says how much was cut.
cool
out=$(STUB_ASK="opencode/a-free" STUB_ASK_COMMAND="$(printf 'x%.0s' $(seq 1 2500))" HI_FREE_MODELS_PREFER="opencode/a-free" fm run "$T/wt" askcut "$T/brief.md" 2>/dev/null)
expect "a long input shows how many characters were cut" "$(grep '^input: ' <<<"$out" | grep -o '\[cut: [0-9]* more characters\]')" "[cut: 514 more characters]"
fm stop "$(run_id_of "$out")" >/dev/null 2>&1

mkdir -p "$T/nonode"
for tool in bash env jq date curl mkdir sleep rm rmdir mv grep cut head tail wc sort tr mktemp basename dirname pwd chmod cp find touch cat; do
  p=$(command -v "$tool") && ln -s "$p" "$T/nonode/$tool"
done
PATH="$T/nonode" fm run "$T/wt" nonode "$T/brief.md" >/dev/null 2>"$T/err"
expect "node missing exits 3" "$?" "3"
grep -q 'node is not installed' "$T/err" && pass "the missing node is named" || fail "stderr: $(cat "$T/err")"

fm bogus >/dev/null 2>&1
expect "an unknown command exits 1" "$?" "1"

((fails == 0)) && echo "all passed" || { echo "$fails failed"; exit 1; }
