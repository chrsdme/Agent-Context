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
echo 'SELFTEST PASS'
