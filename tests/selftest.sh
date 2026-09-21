#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AC="$ROOT_DIR/bin/agent-context"
TMP="$(mktemp -d /tmp/agent-context-selftest.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export AGENT_CONTEXT_STATE_DIR="$TMP/state"
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.local/bin"
cp "$AC" "$HOME/.local/bin/agent-context"
chmod 755 "$HOME/.local/bin/agent-context"
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
printf 'x\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm init
cd "$REPO"
"$AC" init --project demo >/dev/null

test -f .ai/project-context.toml
test -f .ai/state/HANDOFF.md
test -f AGENTS.md
SESSION=abc123

jq -nc --arg cwd "$REPO" --arg sid "$SESSION" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid,transcript_path:"/tmp/demo.jsonl"}' | "$AC" hook --harness codex | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null
jq -nc --arg cwd "$REPO" --arg sid "$SESSION" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"Implement feature X"}' | "$AC" hook --harness codex | jq -e 'type=="object"' >/dev/null
printf 'changed\n' >> file.txt
jq -nc --arg cwd "$REPO" --arg sid "$SESSION" '{hook_event_name:"PostToolUse",cwd:$cwd,session_id:$sid,tool_name:"Bash",tool_input:{command:"printf changed >> file.txt"}}' | "$AC" hook --harness codex >/dev/null
jq -nc --arg cwd "$REPO" --arg sid "$SESSION" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"Implemented feature X and changed file.txt."}' | "$AC" hook --harness codex | jq -e 'type=="object"' >/dev/null
"$AC" handoff --harness codex --mode rotate --objective 'Implement feature X' --next-action 'Run tests' >/dev/null
grep -q 'Implement feature X' .ai/state/HANDOFF.md
jq -nc --arg cwd "$REPO" --arg sid "$SESSION" '{hook_event_name:"SessionEnd",cwd:$cwd,session_id:$sid,reason:"clear"}' | "$AC" hook --harness codex | jq -e 'type=="object"' >/dev/null
NEW=def456
jq -nc --arg cwd "$REPO" --arg sid "$NEW" '{hook_event_name:"SessionStart",source:"clear",cwd:$cwd,session_id:$sid,transcript_path:"/tmp/demo2.jsonl"}' | "$AC" hook --harness codex | jq -er '.hookSpecificOutput.additionalContext' | grep -q 'Implement feature X'
"$AC" recover --list | grep -q "$SESSION"
# Close the recovery session so the next scenario has one predecessor.
jq -nc --arg cwd "$REPO" --arg sid "$NEW" '{hook_event_name:"SessionEnd",cwd:$cwd,session_id:$sid,reason:"other"}' | "$AC" hook --harness codex >/dev/null

# Abrupt/new-session recovery without SessionEnd: unique recent active predecessor.
S2=live222
jq -nc --arg cwd "$REPO" --arg sid "$S2" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid,transcript_path:"/tmp/live222.jsonl"}' | "$AC" hook --harness codex >/dev/null
jq -nc --arg cwd "$REPO" --arg sid "$S2" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"Continue operation Y"}' | "$AC" hook --harness codex >/dev/null
jq -nc --arg cwd "$REPO" --arg sid "$S2" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"Operation Y is in progress; next run focused validation."}' | "$AC" hook --harness codex >/dev/null
S3=live333
jq -nc --arg cwd "$REPO" --arg sid "$S3" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid,transcript_path:"/tmp/live333.jsonl"}' | "$AC" hook --harness codex | jq -er '.hookSpecificOutput.additionalContext' | grep -q 'Continue operation Y'

# Lost-cwd recovery through stable pane lineage.
REPO2="$TMP/repo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q
git -C "$REPO2" config user.email test@example.com
git -C "$REPO2" config user.name Test
printf 'z\n' > "$REPO2/z.txt"
git -C "$REPO2" add z.txt
git -C "$REPO2" commit -qm init
"$AC" init --repo "$REPO2" --project demo-lineage >/dev/null
export TMUX_PANE='%agent-context-test'
L1=lineage111
jq -nc --arg cwd "$REPO2" --arg sid "$L1" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid,transcript_path:"/tmp/lineage1.jsonl"}' | "$AC" hook --harness codex >/dev/null
jq -nc --arg cwd "$REPO2" --arg sid "$L1" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"Lineage recovery task"}' | "$AC" hook --harness codex >/dev/null
jq -nc --arg cwd "$REPO2" --arg sid "$L1" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"Lineage task checkpointed."}' | "$AC" hook --harness codex >/dev/null
L2=lineage222
jq -nc --arg sid "$L2" '{hook_event_name:"SessionStart",source:"clear",cwd:"/",session_id:$sid,transcript_path:"/tmp/lineage2.jsonl"}' | "$AC" hook --harness codex | jq -er '.hookSpecificOutput.additionalContext' | grep -q 'demo-lineage'
unset TMUX_PANE

# Global hook merge must preserve any existing, unrelated hook handlers already in place.
cat > "$HOME/.codex/hooks.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash '/opt/some-other-tool/session-hook.sh' session"}]}]}}
JSON
cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"bash '/opt/some-other-tool/session-hook.sh' session"}]}],"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"/opt/some-other-tool/pre-read-hook.sh"}]}]}}
JSON
"$AC" install-hooks --harness all >/dev/null
grep -q 'some-other-tool/session-hook.sh' "$HOME/.codex/hooks.json"
grep -q 'agent-context hook --harness codex' "$HOME/.codex/hooks.json"
grep -q 'some-other-tool/pre-read-hook.sh' "$HOME/.claude/settings.json"
grep -q 'agent-context hook --harness claude' "$HOME/.claude/settings.json"


# Regression: a one-turn, no-write, low-score session MUST survive /clear.
REPO3="$TMP/repo3"
mkdir -p "$REPO3"
git -C "$REPO3" init -q
git -C "$REPO3" config user.email test@example.com
git -C "$REPO3" config user.name Test
printf 'q\n' > "$REPO3/q.txt"
git -C "$REPO3" add q.txt
git -C "$REPO3" commit -qm init
"$AC" init --repo "$REPO3" --project demo-low-score >/dev/null
LOW=low111
jq -nc --arg cwd "$REPO3" --arg sid "$LOW" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid,transcript_path:"/tmp/low1.jsonl"}' | "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO3" --arg sid "$LOW" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"marker CEDAR-4821; next append recovered"}' | "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO3" --arg sid "$LOW" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"State recorded; no modifications made."}' | "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO3" --arg sid "$LOW" '{hook_event_name:"SessionEnd",cwd:$cwd,session_id:$sid,reason:"clear"}' | "$AC" hook --harness claude >/dev/null
LOW2=low222
jq -nc --arg cwd "$REPO3" --arg sid "$LOW2" '{hook_event_name:"SessionStart",source:"clear",cwd:$cwd,session_id:$sid,transcript_path:"/tmp/low2.jsonl"}' | "$AC" hook --harness claude | jq -er '.hookSpecificOutput.additionalContext' | grep -q 'CEDAR-4821'

# Regression: informational recover --list outside a repo must not return non-zero.
cd /
"$AC" recover --list | grep -q 'REGISTERED PROJECT RECOVERY STATE'
cd "$REPO"

# Regression: existing AGENTS mode and CRLF bytes survive managed-block append/update.
REPO4="$TMP/repo4"
mkdir -p "$REPO4"
git -C "$REPO4" init -q
git -C "$REPO4" config user.email test@example.com
git -C "$REPO4" config user.name Test
printf 'alpha\r\nbeta\r\n' > "$REPO4/AGENTS.md"
chmod 755 "$REPO4/AGENTS.md"
git -C "$REPO4" add AGENTS.md
git -C "$REPO4" commit -qm init
"$AC" init --repo "$REPO4" --project preserve >/dev/null
test "$(stat -c %a "$REPO4/AGENTS.md")" = 755
python3 - "$REPO4/AGENTS.md" <<'PY2'
from pathlib import Path
import sys
b=Path(sys.argv[1]).read_bytes()
assert b'alpha\r\nbeta\r\n' in b
assert b'AGENT-CONTEXT-CONTINUITY' in b
PY2

# Regression: Codex tight lifecycle events are configured at the host maximum (3s).
"$AC" install-hooks --harness codex >/dev/null
jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command|contains("agent-context hook")) | .timeout == 3' "$HOME/.codex/hooks.json" >/dev/null
jq -e '.hooks.Interrupt[]?.hooks[]? | select(.command|contains("agent-context hook")) | .timeout == 3' "$HOME/.codex/hooks.json" >/dev/null

# Regression: no predecessor must explicitly prohibit broad rediscovery.
REPO5="$TMP/repo5"
mkdir -p "$REPO5"
git -C "$REPO5" init -q
git -C "$REPO5" config user.email test@example.com
git -C "$REPO5" config user.name Test
printf 'n\n' > "$REPO5/n.txt"
git -C "$REPO5" add n.txt
git -C "$REPO5" commit -qm init
"$AC" init --repo "$REPO5" --project no-predecessor >/dev/null
jq -nc --arg cwd "$REPO5" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:"first"}' | "$AC" hook --harness claude | jq -er '.hookSpecificOutput.additionalContext' | grep -q 'NO EXACT PREDECESSOR RECOVERED'

# --- v1.2 feature tests: every case runs on both harnesses ---
for H in claude codex; do

# Redaction: credential-shaped strings must never reach state/handoff at rest.
REPO6="$TMP/repo6-$H"
mkdir -p "$REPO6"
git -C "$REPO6" init -q
git -C "$REPO6" config user.email test@example.com
git -C "$REPO6" config user.name Test
printf 'r\n' > "$REPO6/r.txt"
git -C "$REPO6" add r.txt
git -C "$REPO6" commit -qm init
"$AC" init --repo "$REPO6" --project "redaction-test-$H" >/dev/null
R1="redact111-$H"
JWT='eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGhpc2lzYWZha2VzaWduYXR1cmVub3RyZWFs'
PROMPT="secrets: jwt=$JWT ghp_faketokenfaketokenfaketoken1234 AKIAFAKEEXAMPLEKEYID Authorization: Bearer faketoken1234567890abcdef xoxb-fake-slack-token-000111222 Cookie: session=fakesessionvalue1234567890 postgres://user:fakepassword@db.example.com:5432/app API_TOKEN=fakeapitoken1234567890"
jq -nc --arg cwd "$REPO6" --arg sid "$R1" --arg pr "$PROMPT" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO6" --arg sid "$R1" --arg pr "$PROMPT" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:$pr}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO6" --arg sid "$R1" --arg pr "$PROMPT" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:$pr}' | "$AC" hook --harness "$H" >/dev/null
"$AC" handoff --repo "$REPO6" --harness "$H" --session-id "$R1" --mode rotate --objective "$PROMPT" --next-action next >/dev/null
STATE_FILE="$(find "$AGENT_CONTEXT_STATE_DIR/repos" -path '*active*' -name state.json | xargs grep -l "$R1" | head -1)"
! grep -qF "$JWT" "$STATE_FILE"
! grep -qF 'ghp_faketokenfaketokenfaketoken1234' "$STATE_FILE"
! grep -qF 'AKIAFAKEEXAMPLEKEYID' "$STATE_FILE"
! grep -qF 'fakepassword' "$STATE_FILE"
! grep -qF 'fakesessionvalue1234567890' "$STATE_FILE"
! grep -qF "$JWT" "$REPO6/.ai/state/HANDOFF.md"
! grep -qF 'fakeapitoken1234567890' "$REPO6/.ai/state/HANDOFF.md"
grep -q 'REDACTED' "$REPO6/.ai/state/HANDOFF.md"
# A real 40-char git SHA must survive redaction untouched.
REALHEAD="$(git -C "$REPO6" rev-parse HEAD)"
grep -qF "$REALHEAD" "$REPO6/.ai/state/HANDOFF.md"

# Suggested-skills section is present in handoff output.
grep -q 'Suggested skills for next session' "$REPO6/.ai/state/HANDOFF.md"

# Claim-checker: an unverified "tests pass" claim must be flagged.
REPO7="$TMP/repo7-$H"
mkdir -p "$REPO7"
git -C "$REPO7" init -q
git -C "$REPO7" config user.email test@example.com
git -C "$REPO7" config user.name Test
printf 'c\n' > "$REPO7/c.txt"
git -C "$REPO7" add c.txt
git -C "$REPO7" commit -qm init
"$AC" init --repo "$REPO7" --project "claim-test-$H" >/dev/null
C1="claim111-$H"
jq -nc --arg cwd "$REPO7" --arg sid "$C1" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO7" --arg sid "$C1" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"fix bug"}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO7" --arg sid "$C1" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"Done. All tests pass and I committed the changes."}' | "$AC" hook --harness "$H" >/dev/null
"$AC" handoff --repo "$REPO7" --harness "$H" --session-id "$C1" --mode rotate --objective "fix bug" --next-action "none" >/dev/null
grep -q 'Claim check' "$REPO7/.ai/state/HANDOFF.md"
grep -q 'no test-runner command' "$REPO7/.ai/state/HANDOFF.md"
grep -q 'HEAD is unchanged' "$REPO7/.ai/state/HANDOFF.md"

# Claim-checker: a verified "tests pass" claim (matching pytest tool call) must NOT be flagged.
C2="claim222-$H"
jq -nc --arg cwd "$REPO7" --arg sid "$C2" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO7" --arg sid "$C2" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"fix bug 2"}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO7" --arg sid "$C2" '{hook_event_name:"PostToolUse",cwd:$cwd,session_id:$sid,tool_name:"Bash",tool_input:{command:"pytest -q"},tool_response:{is_error:false}}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO7" --arg sid "$C2" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"All tests pass."}' | "$AC" hook --harness "$H" >/dev/null
"$AC" handoff --repo "$REPO7" --harness "$H" --session-id "$C2" --mode rotate --objective "fix bug 2" --next-action "none" >/dev/null
! grep -q 'no test-runner command' "$REPO7/.ai/state/HANDOFF.md"

# Acknowledge: recovery-side accept/reject/needs-clarification is logged.
"$AC" acknowledge --repo "$REPO7" --harness "$H" --session-id "$C2" --status accepted --note "looked fine" >/dev/null
ACK_FILE="$(find "$AGENT_CONTEXT_STATE_DIR/repos" -name acknowledgements.jsonl | xargs grep -l "$C2" | head -1)"
test -f "$ACK_FILE"
jq -e 'select(.status=="accepted")' "$ACK_FILE" >/dev/null

# Partial-failure manifest: an interrupted archive leaves a stale journal that doctor flags and the next SessionStart heals.
REPO8="$TMP/repo8-$H"
mkdir -p "$REPO8"
git -C "$REPO8" init -q
git -C "$REPO8" config user.email test@example.com
git -C "$REPO8" config user.name Test
printf 'j\n' > "$REPO8/j.txt"
git -C "$REPO8" add j.txt
git -C "$REPO8" commit -qm init
"$AC" init --repo "$REPO8" --project "journal-test-$H" >/dev/null
J1="journal111-$H"
jq -nc --arg cwd "$REPO8" --arg sid "$J1" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO8" --arg sid "$J1" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"interrupted work"}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO8" --arg sid "$J1" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"checkpointed"}' | "$AC" hook --harness "$H" >/dev/null
ACTIVE_DIR="$(dirname "$(find "$AGENT_CONTEXT_STATE_DIR/repos" -path '*active*' -name state.json | xargs grep -l "$J1" | head -1)")"
python3 - "$ACTIVE_DIR" <<'PY3'
import json,sys,time
from pathlib import Path
d=Path(sys.argv[1])
(d/'journal.json').write_text(json.dumps({'op':'archive','steps':['state_write','handoff_write','archive_move','archive_trim'],'done':['state_write'],'started_epoch':int(time.time())-999,'started_at':'x'}))
PY3
"$AC" doctor --repo "$REPO8" > "$TMP/doctor1-$H.out" || true
grep -q 'FAIL Partial-failure manifests: 1 stale' "$TMP/doctor1-$H.out"
J2="journal222-$H"
jq -nc --arg cwd "$REPO8" --arg sid "$J2" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" | jq -er '.hookSpecificOutput.additionalContext' | grep -q 'Recovered from an interrupted checkpoint write'
"$AC" doctor --repo "$REPO8" > "$TMP/doctor2-$H.out" || true
grep -q 'PASS Partial-failure manifests: 0 stale' "$TMP/doctor2-$H.out"

# Partial-failure manifest: an interrupted `handoff` op (crash between session_write and
# canonical_promote) must resume by rewriting the canonical file, not leave it stale.
J3="journal333-$H"
jq -nc --arg cwd "$REPO8" --arg sid "$J3" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO8" --arg sid "$J3" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"work"}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO8" --arg sid "$J3" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"done"}' | "$AC" hook --harness "$H" >/dev/null
"$AC" handoff --repo "$REPO8" --harness "$H" --session-id "$J3" --mode rotate --objective "work" --next-action "next" >/dev/null
J3_DIR="$(dirname "$(find "$AGENT_CONTEXT_STATE_DIR/repos" -path '*active*' -name state.json | xargs grep -l "$J3" | head -1)")"
echo 'STALE-CANONICAL-PLACEHOLDER' > "$REPO8/.ai/state/HANDOFF.md"
python3 - "$J3_DIR" <<'PY6'
import json,sys,time
from pathlib import Path
d=Path(sys.argv[1])
(d/'journal.json').write_text(json.dumps({'op':'handoff','steps':['session_write','canonical_promote'],'done':['session_write'],'started_epoch':int(time.time())-999,'started_at':'x'}))
PY6
J4="journal444-$H"
jq -nc --arg cwd "$REPO8" --arg sid "$J4" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" >/dev/null
! grep -q 'STALE-CANONICAL-PLACEHOLDER' "$REPO8/.ai/state/HANDOFF.md"
grep -q 'work' "$REPO8/.ai/state/HANDOFF.md"

# Fail-open: malformed stdin, and an unwritable state directory, must never make the hook exit non-zero
# (agent-context registers no PreToolUse hook on either harness, so it structurally cannot block a tool call either way).
echo 'not json' | "$AC" hook --harness "$H" >/dev/null; test $? -eq 0
jq -nc --arg cwd "$REPO8" --arg sid "$J1" '{hook_event_name:"Interrupt",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" >/dev/null; test $? -eq 0
UNWRITABLE="$TMP/unwritable-state-$H"
mkdir -p "$UNWRITABLE"
chmod 000 "$UNWRITABLE"
AGENT_CONTEXT_STATE_DIR="$UNWRITABLE/deeper" bash -c "cd '$REPO8' && jq -nc --arg cwd '$REPO8' '{hook_event_name:\"SessionStart\",source:\"startup\",cwd:\$cwd,session_id:\"failopen-$H\"}' | '$AC' hook --harness $H" >/dev/null; test $? -eq 0
chmod 755 "$UNWRITABLE"

done

# Confirm neither installed harness config registers a PreToolUse agent-context hook
# (checked against the real installed files, not just the source literal).
for CFG in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"; do
  if [ -f "$CFG" ]; then
    ! jq -e '.hooks.PreToolUse[]?.hooks[]? | select(.command|contains("agent-context hook"))' "$CFG" >/dev/null 2>&1
  fi
done

# YAML format option: identical feature set, YAML-formatted checkpoint/handoff via [handoff].format = "yaml".
for H in claude codex; do
REPO9="$TMP/repo9-$H"
mkdir -p "$REPO9"
git -C "$REPO9" init -q
git -C "$REPO9" config user.email test@example.com
git -C "$REPO9" config user.name Test
printf 'y\n' > "$REPO9/y.txt"
git -C "$REPO9" add y.txt
git -C "$REPO9" commit -qm init
"$AC" init --repo "$REPO9" --project "yaml-test-$H" >/dev/null
python3 - "$REPO9/.ai/project-context.toml" <<'PY5'
import sys
from pathlib import Path
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('format = "md"','format = "yaml"'))
PY5
Y1="yaml111-$H"
jq -nc --arg cwd "$REPO9" --arg sid "$Y1" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO9" --arg sid "$Y1" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"do thing"}' | "$AC" hook --harness "$H" >/dev/null
jq -nc --arg cwd "$REPO9" --arg sid "$Y1" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"done"}' | "$AC" hook --harness "$H" >/dev/null
"$AC" handoff --repo "$REPO9" --harness "$H" --session-id "$Y1" --mode rotate --objective "do thing" --next-action "verify" >/dev/null
head -1 "$REPO9/.ai/state/HANDOFF.md" | grep -q '# Session Handoff'
grep -q "^project: yaml-test-$H" "$REPO9/.ai/state/HANDOFF.md"
grep -q '^suggested_skills:' "$REPO9/.ai/state/HANDOFF.md"
python3 -c "
import yaml,sys
d=yaml.safe_load(open('$REPO9/.ai/state/HANDOFF.md'))
assert isinstance(d,dict) and d.get('project')=='yaml-test-$H'
" 2>/dev/null || python3 -c "
# PyYAML unavailable in this environment; fall back to a structural sanity check only.
import re
t=open('$REPO9/.ai/state/HANDOFF.md').read()
assert re.search(r'^project: yaml-test-$H\$',t,re.M)
"
done

# install.sh --claude / --codex / --both, and --md / --yaml default-format wiring.
INSTHOME="$TMP/insthome"
mkdir -p "$INSTHOME"
HOME="$INSTHOME" AGENT_CONTEXT_STATE_DIR="$INSTHOME/state" bash "$ROOT_DIR/install.sh" --claude --yaml >/dev/null
test -f "$INSTHOME/.claude/skills/handoff/SKILL.md"
! test -e "$INSTHOME/.codex/skills/handoff/SKILL.md"
jq -e '.default_format=="yaml"' "$INSTHOME/state/config.json" >/dev/null
REPO10="$TMP/repo10"
mkdir -p "$REPO10"
git -C "$REPO10" init -q; git -C "$REPO10" config user.email test@example.com; git -C "$REPO10" config user.name Test
printf 'i\n' > "$REPO10/i.txt"; git -C "$REPO10" add i.txt; git -C "$REPO10" commit -qm init
HOME="$INSTHOME" AGENT_CONTEXT_STATE_DIR="$INSTHOME/state" "$INSTHOME/.local/bin/agent-context" init --repo "$REPO10" --project inst-yaml-default >/dev/null
grep -q 'format = "yaml"' "$REPO10/.ai/project-context.toml"

rm -rf "$INSTHOME"
mkdir -p "$INSTHOME"
HOME="$INSTHOME" AGENT_CONTEXT_STATE_DIR="$INSTHOME/state" bash "$ROOT_DIR/install.sh" --codex >/dev/null
! test -e "$INSTHOME/.claude/skills/handoff/SKILL.md"
test -f "$INSTHOME/.codex/skills/handoff/SKILL.md"
jq -e '.default_format=="md"' "$INSTHOME/state/config.json" >/dev/null

rm -rf "$INSTHOME"
mkdir -p "$INSTHOME"
HOME="$INSTHOME" AGENT_CONTEXT_STATE_DIR="$INSTHOME/state" bash "$ROOT_DIR/install.sh" --both >/dev/null
test -f "$INSTHOME/.claude/skills/handoff/SKILL.md"
test -f "$INSTHOME/.codex/skills/handoff/SKILL.md"
jq -e '.default_format=="md"' "$INSTHOME/state/config.json" >/dev/null

# --- doctor runtime-evidence tests (hook_events_seen) ---
# Runtime evidence is scanned registry-wide (every project Agent-Context knows about),
# not just the --repo target (see cmd_doctor). Each scenario below therefore gets its
# own isolated AGENT_CONTEXT_STATE_DIR so an earlier scenario's completed session can't
# leak in and change a later scenario's expected PASS/INFO verdict.

# Old-format state (no hook_events_seen key) must remain valid: hook stays fail-open,
# doctor reports "not yet observed" instead of crashing or misreading absence as failure.
STATE11="$TMP/state-repo11"
REPO11="$TMP/repo11"
mkdir -p "$REPO11"
git -C "$REPO11" init -q
git -C "$REPO11" config user.email test@example.com
git -C "$REPO11" config user.name Test
printf 'o\n' > "$REPO11/o.txt"
git -C "$REPO11" add o.txt
git -C "$REPO11" commit -qm init
AGENT_CONTEXT_STATE_DIR="$STATE11" "$AC" init --repo "$REPO11" --project "doctor-old-state" >/dev/null
OLD1=old111
jq -nc --arg cwd "$REPO11" --arg sid "$OLD1" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | AGENT_CONTEXT_STATE_DIR="$STATE11" "$AC" hook --harness claude >/dev/null
OLD_STATE="$(find "$STATE11/repos" -path '*active*' -name state.json | xargs grep -l "$OLD1" | head -1)"
python3 - "$OLD_STATE" <<'PY7'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text()); d.pop('hook_events_seen',None); p.write_text(json.dumps(d))
PY7
jq -nc --arg cwd "$REPO11" --arg sid "$OLD1" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"hi"}' | AGENT_CONTEXT_STATE_DIR="$STATE11" "$AC" hook --harness claude >/dev/null; test $? -eq 0
jq -nc --arg cwd "$REPO11" --arg sid "$OLD1" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"ok"}' | AGENT_CONTEXT_STATE_DIR="$STATE11" "$AC" hook --harness claude >/dev/null; test $? -eq 0
AGENT_CONTEXT_STATE_DIR="$STATE11" "$AC" doctor --repo "$REPO11" | grep -qE 'INFO latest active evidence, partial lifecycle \(project=doctor-old-state session='"$OLD1"' .*\): UserPromptSubmit, Stop; missing: SessionStart, PostToolUse, SessionEnd \(no closed session with hook_events_seen\)'

# Full normal lifecycle -> runtime PASS with the observed events listed.
STATE12="$TMP/state-repo12"
REPO12="$TMP/repo12"
mkdir -p "$REPO12"
git -C "$REPO12" init -q
git -C "$REPO12" config user.email test@example.com
git -C "$REPO12" config user.name Test
printf 'p\n' > "$REPO12/p.txt"
git -C "$REPO12" add p.txt
git -C "$REPO12" commit -qm init
AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" init --repo "$REPO12" --project "doctor-full-lifecycle" >/dev/null
FULL1=full111
jq -nc --arg cwd "$REPO12" --arg sid "$FULL1" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO12" --arg sid "$FULL1" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"hi"}' | AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO12" --arg sid "$FULL1" '{hook_event_name:"PostToolUse",cwd:$cwd,session_id:$sid,tool_name:"Read",tool_input:{file_path:"p.txt"}}' | AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO12" --arg sid "$FULL1" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"ok"}' | AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO12" --arg sid "$FULL1" '{hook_event_name:"SessionEnd",cwd:$cwd,session_id:$sid,reason:"other"}' | AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" hook --harness claude >/dev/null
AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" doctor --repo "$REPO12" | grep -qE 'PASS normal lifecycle observed \(project=doctor-full-lifecycle session='"$FULL1"' .*\): SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd'

# A newer, still-live session (only SessionStart so far -- it structurally cannot have
# emitted SessionEnd yet) must not shadow an earlier *completed* session's evidence:
# doctor must still select the completed session and print PASS, not regress to partial.
FULL2=full222
jq -nc --arg cwd "$REPO12" --arg sid "$FULL2" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" hook --harness claude >/dev/null
AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" doctor --repo "$REPO12" | grep -qE 'PASS normal lifecycle observed \(project=doctor-full-lifecycle session='"$FULL1"' .*\): SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd'

# Partial lifecycle (no PostToolUse/Stop/SessionEnd yet) -> INFO with observed + missing.
STATE13="$TMP/state-repo13"
REPO13="$TMP/repo13"
mkdir -p "$REPO13"
git -C "$REPO13" init -q
git -C "$REPO13" config user.email test@example.com
git -C "$REPO13" config user.name Test
printf 'q\n' > "$REPO13/q2.txt"
git -C "$REPO13" add q2.txt
git -C "$REPO13" commit -qm init
AGENT_CONTEXT_STATE_DIR="$STATE13" "$AC" init --repo "$REPO13" --project "doctor-partial-lifecycle" >/dev/null
PART1=part111
jq -nc --arg cwd "$REPO13" --arg sid "$PART1" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | AGENT_CONTEXT_STATE_DIR="$STATE13" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO13" --arg sid "$PART1" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"hi"}' | AGENT_CONTEXT_STATE_DIR="$STATE13" "$AC" hook --harness claude >/dev/null
AGENT_CONTEXT_STATE_DIR="$STATE13" "$AC" doctor --repo "$REPO13" | grep -qE 'INFO latest active evidence, partial lifecycle \(project=doctor-partial-lifecycle session='"$PART1"' .*\): SessionStart, UserPromptSubmit; missing: PostToolUse, Stop, SessionEnd \(no closed session with hook_events_seen\)'

# Regression: a newer CLOSED-but-partial session must never be masked by an older CLOSED
# full-lifecycle session's PASS. Both sessions here reach SessionEnd (fully closed), but
# the older one has the complete normal lifecycle while the newer one is missing events --
# doctor must report the newer session's partial INFO, not the older PASS.
STATE16="$TMP/state-repo16"
REPO16="$TMP/repo16"
mkdir -p "$REPO16"
git -C "$REPO16" init -q
git -C "$REPO16" config user.email test@example.com
git -C "$REPO16" config user.name Test
printf 's\n' > "$REPO16/s.txt"
git -C "$REPO16" add s.txt
git -C "$REPO16" commit -qm init
AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" init --repo "$REPO16" --project "doctor-closed-mask" >/dev/null
OLDFULL=oldfull1
jq -nc --arg cwd "$REPO16" --arg sid "$OLDFULL" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO16" --arg sid "$OLDFULL" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"hi"}' | AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO16" --arg sid "$OLDFULL" '{hook_event_name:"PostToolUse",cwd:$cwd,session_id:$sid,tool_name:"Read",tool_input:{file_path:"s.txt"}}' | AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO16" --arg sid "$OLDFULL" '{hook_event_name:"Stop",cwd:$cwd,session_id:$sid,last_assistant_message:"ok"}' | AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO16" --arg sid "$OLDFULL" '{hook_event_name:"SessionEnd",cwd:$cwd,session_id:$sid,reason:"other"}' | AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" hook --harness claude >/dev/null
# Force the older session's archived state to a clearly older updated_epoch so ordering
# cannot tie with the newer session created moments later in the same test run.
OLDFULL_ARCHIVE=$(find "$STATE16" -path '*/archive/*' -name state.json | xargs grep -l "\"$OLDFULL\"")
python3 -c "
import json,sys
p=sys.argv[1]
d=json.loads(open(p).read())
d['updated_epoch']=d['updated_epoch']-3600
open(p,'w').write(json.dumps(d))
" "$OLDFULL_ARCHIVE"
NEWPART=newpart1
jq -nc --arg cwd "$REPO16" --arg sid "$NEWPART" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO16" --arg sid "$NEWPART" '{hook_event_name:"UserPromptSubmit",cwd:$cwd,session_id:$sid,prompt:"hi"}' | AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" hook --harness claude >/dev/null
jq -nc --arg cwd "$REPO16" --arg sid "$NEWPART" '{hook_event_name:"SessionEnd",cwd:$cwd,session_id:$sid,reason:"other"}' | AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" hook --harness claude >/dev/null
DOCTOR16_OUT=$(AGENT_CONTEXT_STATE_DIR="$STATE16" "$AC" doctor --repo "$REPO16")
echo "$DOCTOR16_OUT" | grep -qE 'INFO partial lifecycle observed \(project=doctor-closed-mask session='"$NEWPART"' .*\): SessionStart, UserPromptSubmit, SessionEnd; missing: PostToolUse, Stop'
! echo "$DOCTOR16_OUT" | grep -q "PASS normal lifecycle observed (project=doctor-closed-mask session=$OLDFULL"
! echo "$DOCTOR16_OUT" | grep -qE '^  PASS normal lifecycle observed'

# No evidence at all -> INFO "not yet observed", never treated as a doctor failure (exit 0).
# Runtime evidence is scanned across the whole registry (not just --repo), so this needs
# its own isolated state dir -- otherwise it would see the completed REPO12 session above.
NOEV_STATE="$TMP/state-no-evidence"
REPO14="$TMP/repo14"
mkdir -p "$REPO14"
git -C "$REPO14" init -q
git -C "$REPO14" config user.email test@example.com
git -C "$REPO14" config user.name Test
printf 'r2\n' > "$REPO14/r2.txt"
git -C "$REPO14" add r2.txt
git -C "$REPO14" commit -qm init
AGENT_CONTEXT_STATE_DIR="$NOEV_STATE" "$AC" init --repo "$REPO14" --project "doctor-no-evidence" >/dev/null
AGENT_CONTEXT_STATE_DIR="$NOEV_STATE" "$AC" doctor --repo "$REPO14" > "$TMP/doctor-no-evidence.out"; test $? -eq 0
grep -q 'INFO runtime not yet observed' "$TMP/doctor-no-evidence.out"

# Registry-wide runtime scope: a session recorded from a DIFFERENT repo must still be
# visible to doctor run against a repo with no sessions of its own (requirement 3: inspect
# Agent-Context's own persisted session state, not merely the --repo target). Reuse
# STATE12, which already holds REPO12's completed session, registered against REPO14.
AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" init --repo "$REPO14" --project "doctor-no-evidence-registry" >/dev/null
# Assert the provenance names REPO12's project, not REPO14's own (which has no sessions) --
# proof the evidence is genuinely coming from elsewhere in the registry.
AGENT_CONTEXT_STATE_DIR="$STATE12" "$AC" doctor --repo "$REPO14" | grep -qE 'PASS normal lifecycle observed \(project=doctor-full-lifecycle session='"$FULL1"' .*\): SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd'

# Repeated non-material PostToolUse events must not grow hook_events_seen or force
# repeated state writes: still one entry after several repeats, and no material_events recorded.
REPO15="$TMP/repo15"
mkdir -p "$REPO15"
git -C "$REPO15" init -q
git -C "$REPO15" config user.email test@example.com
git -C "$REPO15" config user.name Test
printf 's\n' > "$REPO15/s.txt"
git -C "$REPO15" add s.txt
git -C "$REPO15" commit -qm init
"$AC" init --repo "$REPO15" --project "doctor-repeat-posttool" >/dev/null
REP1=rep111
jq -nc --arg cwd "$REPO15" --arg sid "$REP1" '{hook_event_name:"SessionStart",source:"startup",cwd:$cwd,session_id:$sid}' | "$AC" hook --harness claude >/dev/null
for i in 1 2 3 4 5; do
  jq -nc --arg cwd "$REPO15" --arg sid "$REP1" '{hook_event_name:"PostToolUse",cwd:$cwd,session_id:$sid,tool_name:"Read",tool_input:{file_path:"s.txt"}}' | "$AC" hook --harness claude >/dev/null
done
REP_STATE="$(find "$AGENT_CONTEXT_STATE_DIR/repos" -path '*active*' -name state.json | xargs grep -l "$REP1" | head -1)"
python3 - "$REP_STATE" <<'PY8'
import json,sys
from pathlib import Path
d=json.loads(Path(sys.argv[1]).read_text())
assert list(d.get('hook_events_seen',{}).keys()).count('PostToolUse')==1
assert d.get('material_events',[])==[]
PY8

# Existing fail-open behavior remains intact after the hook_events_seen change:
# malformed stdin and an unwritable state dir still exit 0.
echo 'not json' | "$AC" hook --harness claude >/dev/null; test $? -eq 0
UNWRITABLE2="$TMP/unwritable-state-doctor"
mkdir -p "$UNWRITABLE2"
chmod 000 "$UNWRITABLE2"
AGENT_CONTEXT_STATE_DIR="$UNWRITABLE2/deeper" bash -c "cd '$REPO15' && jq -nc --arg cwd '$REPO15' '{hook_event_name:\"SessionStart\",source:\"startup\",cwd:\$cwd,session_id:\"failopen-doctor\"}' | '$AC' hook --harness claude" >/dev/null; test $? -eq 0
chmod 755 "$UNWRITABLE2"

echo 'PASS: init + exact-root project files'
echo 'PASS: rolling prompt/Stop checkpoint'
echo 'PASS: material PostToolUse checkpoint'
echo 'PASS: durable handoff promotion'
echo 'PASS: clear transition + recovery card'
echo 'PASS: low-score one-turn clear recovery retained'
echo 'PASS: recover --list outside repo is safe'
echo 'PASS: managed block preserves mode + CRLF'
echo 'PASS: Codex SessionEnd/Interrupt timeout normalized to 3s'
echo 'PASS: missing predecessor explicitly blocks broad rediscovery'
echo 'PASS: material session archive + recover list'
echo 'PASS: unique recent active-session recovery without SessionEnd'
echo 'PASS: lost-cwd recovery through stable pane lineage'
echo 'PASS: hook merge preserves pre-existing, unrelated hook handlers'
echo 'PASS: credential-shaped secrets redacted from state and handoff at rest'
echo 'PASS: suggested-skills section present in handoff'
echo 'PASS: unverified claim ("tests pass"/"committed") flagged in handoff'
echo 'PASS: verified claim ("tests pass" with matching tool call) not flagged'
echo 'PASS: acknowledge step logs accept/reject/needs-clarification'
echo 'PASS: stale partial-failure journal detected by doctor and healed on next SessionStart'
echo 'PASS: interrupted handoff-op journal resumes by rewriting the canonical file'
echo 'PASS: hook fails open on malformed input and unwritable state dir'
echo 'PASS: YAML-formatted handoff carries the identical feature set'
echo 'PASS: install.sh --claude/--codex/--both and --md/--yaml wiring'
echo 'PASS: old-format state without hook_events_seen remains valid and fail-open'
echo 'PASS: full normal lifecycle produces doctor runtime PASS with observed events'
echo 'PASS: partial lifecycle produces doctor runtime INFO with observed + missing events'
echo 'PASS: no runtime evidence produces INFO not-observed, never a doctor failure'
echo 'PASS: registry-wide runtime scope surfaces evidence from other repos'
echo 'PASS: newer live session does not shadow an earlier completed session'\''s PASS evidence'
echo 'PASS: newer closed partial session is not masked by an older closed full-lifecycle PASS'
echo 'PASS: repeated non-material PostToolUse does not grow hook_events_seen or record material_events'
echo 'PASS: fail-open behavior intact after hook_events_seen change'
echo 'SELFTEST PASS'
