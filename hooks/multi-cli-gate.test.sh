#!/usr/bin/env bash
# Regression suite for multi-CLI harness protocols in hierarchical-implementation-gate.sh:
# covers agy (Antigravity CLI), codex, gemini, cursor, generic, patch_targets, subagent bypasses,
# adapter wrappers and multi-CLI security paths.
#   bash hooks/multi-cli-gate.test.sh
set -u

DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$DIR/.." && pwd -P)
HOOK="${HOOK:-$DIR/hierarchical-implementation-gate.sh}"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

T=$(cd "$(mktemp -d)" && pwd -P)
export XDG_STATE_HOME="$T/state" HIERARCHICAL_GATE_ROOT="$T/vscode" DELEGATION_LOG="$T/decisions.tsv" DELEGATION_EVENTS="$T/events.tsv"
unset LANE_MODE HI_FREE_WORKERS OPENCODE_BIN HIERARCHICAL_GATE
trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT

W="$T/vscode/repo"
git init -q -b main "$W"
mkdir -p "$W/src"
printf 'one\ntwo\nthree\n' >"$W/src/a.ts"
git -C "$W" add src/a.ts
git -C "$W" -c user.email=t@t -c user.name=t commit -q -m init

FAKE_BIN="$T/bin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nexit 0\n' >"$FAKE_BIN/opencode"
chmod +x "$FAKE_BIN/opencode"

assert_eq() {
  if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
assert_contains() {
  if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3' in '$2')"; fi
}

# --- AGY (Antigravity CLI) ---
agy_run() { bash "$HOOK" --harness agy <<<"$1"; }

agy_edit=$(jq -cn --arg p "$W/src/a.ts" --arg c "$W" '{
  hookEventName:"PreToolUse",
  conversationId:"agy-main-1",
  cwd:$c,
  toolCall:{id:"tc1",name:"edit_file",args:{Path:$p,Target:"one",Replacement:"uno"}}
}')
out=$(agy_run "$agy_edit")
assert_eq "agy: first edit_file is denied" "$(jq -r '.decision' <<<"$out")" "deny"
assert_contains "agy: deny names invoke_subagent and decide command" "$(jq -r '.reason' <<<"$out")" "invoke_subagent"
assert_contains "agy: deny uses absolute script path in decide command" "$(jq -r '.reason' <<<"$out")" "$HOOK decide $W agy-main-1 delegate"

# Subagent detection via AGY transcript line 1
sub_tr="$T/sub-transcript.jsonl"
jq -cn '{step_index:0,source:"SYSTEM",type:"SYSTEM_MESSAGE",content:"<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-20T00:00:00Z sender=agy-main-1"}' >"$sub_tr"
agy_sub_edit=$(jq -cn --arg p "$W/src/a.ts" --arg c "$W" --arg t "$sub_tr" '{
  hookEventName:"PreToolUse",
  conversationId:"agy-sub-1",
  transcriptPath:$t,
  cwd:$c,
  toolCall:{id:"tc2",name:"edit_file",args:{Path:$p,Target:"one",Replacement:"uno"}}
}')
out=$(agy_run "$agy_sub_edit")
assert_eq "agy: subagent detected via transcriptPath is never gated" "$out" "{}"

# Subagent detection via explicit parentConversationId
agy_sub_parent=$(jq -cn --arg p "$W/src/a.ts" --arg c "$W" '{
  hookEventName:"PreToolUse",
  conversationId:"agy-sub-2",
  parentConversationId:"agy-main-1",
  cwd:$c,
  toolCall:{id:"tc3",name:"write_file",args:{Path:$p,Content:"hello\n"}}
}')
assert_eq "agy: subagent detected via parentConversationId is never gated" "$(agy_run "$agy_sub_parent")" "{}"

# HIERARCHICAL_GATE=off still emits valid JSON for AGY
out=$(HIERARCHICAL_GATE=off bash "$HOOK" --harness agy <<<"$agy_edit")
assert_eq "agy: HIERARCHICAL_GATE=off returns empty JSON object" "$out" "{}"

# AGY decide auto-approval on run_command
agy_decide_cmd=$(jq -cn --arg cmd "$HOOK decide $W agy-main-1 delegate \"parser and cli units\"" --arg c "$W" '{
  hookEventName:"PreToolUse",
  conversationId:"agy-main-1",
  cwd:$c,
  toolCall:{id:"tc4",name:"run_command",args:{CommandLine:$cmd}}
}')
out=$(agy_run "$agy_decide_cmd")
assert_eq "agy: own decide run_command is auto-allowed" "$(jq -r '.decision' <<<"$out")" "allow"

# AGY undecided worker spawn is denied, read-only research is allowed
agy_worker_pre=$(jq -cn --arg c "$W" '{
  hookEventName:"PreToolUse",
  conversationId:"agy-main-1",
  cwd:$c,
  toolCall:{id:"tc5",name:"invoke_subagent",args:{TypeName:"worker",Role:"parser",Prompt:"implement parser"}}
}')
assert_eq "agy: worker invoke_subagent before decision is denied" "$(agy_run "$agy_worker_pre" | jq -r '.decision')" "deny"

agy_research_pre=$(jq -cn --arg c "$W" '{
  hookEventName:"PreToolUse",
  conversationId:"agy-main-1",
  cwd:$c,
  toolCall:{id:"tc6",name:"invoke_subagent",args:{TypeName:"research",Role:"explorer",Prompt:"read code"}}
}')
assert_eq "agy: research invoke_subagent before decision passes through" "$(agy_run "$agy_research_pre")" "{}"

# Record delegate, verify no-worker deny, log PostToolUse spawn + message, then allow integration edit
bash "$HOOK" decide "$W" agy-main-1 delegate "parser and cli units" >/dev/null
out=$(agy_run "$agy_edit")
assert_eq "agy: delegate without worker spawn denies driver edit" "$(jq -r '.decision' <<<"$out")" "deny"

agy_post_spawn=$(jq -cn --arg c "$W" '{
  hookEventName:"PostToolUse",
  conversationId:"agy-main-1",
  cwd:$c,
  toolCall:{id:"tc7",name:"invoke_subagent",args:{TypeName:"worker",Role:"parser",Model:"inherit"}}
}')
assert_eq "agy: PostToolUse invoke_subagent returns {}" "$(agy_run "$agy_post_spawn")" "{}"
assert_eq "agy: driver edit allowed after worker spawn" "$(agy_run "$agy_edit")" "{}"

# AGY SessionStart injects systemMessage when HI_FREE_WORKERS=1
agy_ss=$(jq -cn --arg c "$W" '{hookEventName:"SessionStart",conversationId:"agy-main-1",cwd:$c}')
out=$(HI_FREE_WORKERS=1 OPENCODE_BIN="$FAKE_BIN/opencode" bash "$HOOK" --harness agy <<<"$agy_ss")
assert_contains "agy: SessionStart injects free-model note" "$(jq -r '.injectSteps[0].systemMessage.systemMessage' <<<"$out")" "HI_FREE_WORKERS=1"
assert_eq "agy: SessionStart without HI_FREE_WORKERS returns {}" "$(agy_run "$agy_ss")" "{}"

# AGY wrapper script works end-to-end
out=$(bash "$ROOT/adapters/agy/gate.sh" <<<"$agy_edit")
assert_eq "agy: adapters/agy/gate.sh wrapper passes allowed edit" "$out" "{}"

# --- CODEX ---
codex_run() { bash "$HOOK" --harness codex <<<"$1"; }

patch_body=$'*** Begin Patch\n*** Update File: src/a.ts\n@@\n-one\n+uno\n*** Add File: src/b.ts\n+export const b = 1\n*** End Patch'
codex_patch=$(jq -cn --arg p "$patch_body" --arg c "$W" '{
  hook_event_name:"PreToolUse",
  tool_name:"apply_patch",
  session_id:"codex_sess_1",
  cwd:$c,
  tool_input:{input:$p}
}')
out=$(codex_run "$codex_patch")
assert_eq "codex: undecided apply_patch is denied" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" "deny"
assert_contains "codex: deny names spawn_agent" "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")" "spawn_agent"

codex_sub=$(jq -cn --arg p "$patch_body" --arg c "$W" '{
  hook_event_name:"PreToolUse",
  tool_name:"apply_patch",
  session_id:"codex_sess_1",
  agent_id:"codex-worker-1",
  cwd:$c,
  tool_input:{input:$p}
}')
assert_eq "codex: subagent apply_patch is never gated" "$(codex_run "$codex_sub")" ""

codex_decide_shell=$(jq -cn --arg cmd "$HOOK decide $W codex_sess_1 direct \"trivial: small two file fix\"" --arg c "$W" '{
  hook_event_name:"PreToolUse",
  tool_name:"shell_command",
  session_id:"codex_sess_1",
  cwd:$c,
  tool_input:{command:$cmd}
}')
assert_eq "codex: own decide on shell_command is approved" "$(codex_run "$codex_decide_shell" | jq -r '.hookSpecificOutput.permissionDecision')" "allow"

bash "$HOOK" decide "$W" codex_sess_1 direct "trivial: small two file fix" >/dev/null
assert_eq "codex: apply_patch within trivial cap passes" "$(codex_run "$codex_patch")" ""

over_patch=$'*** Begin Patch\n*** Add File: src/c.ts\n+c\n*** Add File: src/d.ts\n+d\n*** End Patch'
codex_over=$(jq -cn --arg p "$over_patch" --arg c "$W" '{
  hook_event_name:"PreToolUse",
  tool_name:"apply_patch",
  session_id:"codex_sess_1",
  cwd:$c,
  tool_input:{input:$p}
}')
assert_eq "codex: apply_patch exceeding 3 trivial files is denied" "$(codex_run "$codex_over" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"

# --- GEMINI CLI ---
gemini_run() { bash "$HOOK" --harness gemini <<<"$1"; }

gem_replace=$(jq -cn --arg p "$W/src/a.ts" --arg c "$W" '{
  hook_event_name:"BeforeTool",
  tool_name:"replace",
  session_id:"gem_sess_1",
  cwd:$c,
  tool_input:{file_path:$p,old_string:"one",new_string:"uno"}
}')
out=$(gemini_run "$gem_replace")
assert_eq "gemini: undecided replace is denied" "$(jq -r '.decision' <<<"$out")" "deny"

gem_decide=$(jq -cn --arg cmd "$HOOK decide $W gem_sess_1 direct \"trivial: small single file fix\"" --arg c "$W" '{
  hook_event_name:"BeforeTool",
  tool_name:"run_shell_command",
  session_id:"gem_sess_1",
  cwd:$c,
  tool_input:{command:$cmd}
}')
assert_eq "gemini: own decide on run_shell_command is allowed" "$(gemini_run "$gem_decide" | jq -r '.decision')" "allow"

bash "$HOOK" decide "$W" gem_sess_1 direct "trivial: small single file fix" >/dev/null
assert_eq "gemini: replace allowed after trivial decision" "$(bash "$ROOT/adapters/gemini/gate.sh" <<<"$gem_replace")" "{}"

gem_ss=$(jq -cn --arg c "$W" '{hook_event_name:"SessionStart",session_id:"gem_sess_1",cwd:$c}')
out=$(HI_FREE_WORKERS=1 OPENCODE_BIN="$FAKE_BIN/opencode" bash "$HOOK" --harness gemini <<<"$gem_ss")
assert_contains "gemini: SessionStart adds free-model context" "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")" "HI_FREE_WORKERS=1"

# --- CURSOR ---
cursor_run() { bash "$HOOK" --harness cursor <<<"$1"; }

cur_edit=$(jq -cn --arg p "$W/src/a.ts" --arg c "$W" '{
  hook_event_name:"preToolUse",
  tool_name:"StrReplace",
  conversation_id:"cur_sess_1",
  cwd:$c,
  tool_input:{path:$p,old_string:"one",new_string:"uno"}
}')
out=$(cursor_run "$cur_edit")
assert_eq "cursor: undecided StrReplace is denied" "$(jq -r '.permission' <<<"$out")" "deny"
assert_contains "cursor: deny populates agentMessage" "$(jq -r '.agentMessage' <<<"$out")" "decide $W cur_sess_1 delegate"

cur_shell_write=$(jq -cn --arg c "$W" '{
  hook_event_name:"beforeShellExecution",
  conversation_id:"cur_sess_1",
  cwd:$c,
  command:"echo hi > src/a.ts"
}')
assert_eq "cursor: beforeShellExecution redirect is denied" "$(cursor_run "$cur_shell_write" | jq -r '.permission')" "deny"

bash "$HOOK" decide "$W" cur_sess_1 delegate "parser unit on free model" >/dev/null
cur_after_shell=$(jq -cn --arg c "$W" --arg cmd "free-models.sh run $W parser /tmp/brief.md" '{
  hook_event_name:"afterShellExecution",
  conversation_id:"cur_sess_1",
  cwd:$c,
  command:$cmd
}')
assert_eq "cursor: afterShellExecution free-models run returns {}" "$(cursor_run "$cur_after_shell")" "{}"
assert_eq "cursor: StrReplace passes after free-models worker spawn" "$(cursor_run "$cur_edit")" "{}"

# --- MULTI-CLI SECURITY PATHS & REPORT ---
P="$T/vscode/plugin"
git init -q -b main "$P"
mkdir -p "$P/.omp-plugin" "$P/adapters/agy"
printf '{}\n' >"$P/.omp-plugin/marketplace.json"
printf '{}\n' >"$P/adapters/agy/hooks.json"
git -C "$P" add .omp-plugin/marketplace.json adapters/agy/hooks.json
git -C "$P" -c user.email=t@t -c user.name=t commit -q -m init

for f in .omp/agent/extensions/gate.ts .pi/agent/settings.json .codex-plugin/plugin.json .cursor-plugin/plugin.json adapters/agy/hooks.json; do
  if bash "$HOOK" decide "$P" sec_sess_1 direct "security: multi cli control path" "$f" >/dev/null 2>&1; then
    pass "security accepts $f"
  else
    fail "security refused $f"
  fi
done

report=$(bash "$HOOK" report)
assert_contains "report includes agy session" "$report" "agy-main-1"
assert_contains "report includes codex session with underscores" "$report" "codex_sess_1"
assert_contains "report includes cursor session with underscores" "$report" "cur_sess_1"

if ((fails)); then
  printf '\n%d failed\n' "$fails"
  exit 1
fi
printf '\nall passed\n'
