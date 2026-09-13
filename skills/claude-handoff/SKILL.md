---
name: handoff
description: Create a durable project handoff before /clear, /new, rotation, or a stage boundary.
disable-model-invocation: true
---

Create a concise durable handoff for the current repository.

1. Identify the current objective and exact next action from the current conversation.
2. Run `agent-context handoff --harness claude --mode rotate` with concise `--objective`, `--next-action`, and optional `--note` values.
3. Do not fabricate validation, commits, or completion claims. Any credential-shaped text in these values is redacted automatically before it is written; do not rely on this to justify pasting secrets in the first place.
4. Report whether the session handoff was written and whether it was promoted to `.ai/state/HANDOFF.md`. If the tool printed "Claim check flagged", surface those flags to the user rather than silently dropping them — they mean a claim in this handoff (e.g. "tests pass", "committed") has no matching tool call in this session's own log.
5. If another active material session prevents canonical promotion, report the conflict rather than forcing it.
6. If `agent-context doctor` reports a stale partial-failure manifest, do not hand-edit `.ai/state/` — start a new session (SessionStart heals it automatically) or ask the owner before touching those files directly.

## Recovery-side: acknowledging a handoff

When a *new* session's SessionStart card reports "Recovery status: EXACT PREDECESSOR RECOVERED" (or the durable handoff excerpt is non-empty), after you have read and evaluated it, run:

```
agent-context acknowledge --harness claude --status accepted|rejected|needs-clarification [--note "..."]
```

Use `accepted` if the card matched reality, `rejected` if it was stale/wrong and you're starting over, `needs-clarification` if you had to ask the user before trusting it. This is a log entry, not a gate — do it once per recovered session, don't skip it silently.
