# agent-context v1.2

Provider-neutral project continuity and recovery for Claude Code and Codex.

It keeps a small, bounded "what was I doing" record for each Git repository you work in, so a
new session (after `/clear`, a crash, a context-window rotation, or just opening a new terminal)
can pick up where the last one left off without re-reading the whole repo or guessing.

## Requirements

**The project you run this in must be a Git repository.** Everything here is scoped by the
exact Git top-level directory (`git rev-parse --show-toplevel`) — that's how it tells one
project apart from another and avoids ever mixing up recovery state between them. If the
folder you're in doesn't have a `.git` directory yet, run:

```bash
git init
```

first, then `agent-context init`. Outside of any Git repository, most commands simply report
that there's nothing to do (see `agent-context recover --list`, which is explicitly safe to run
from anywhere).

## Design

- Identity is the exact Git top-level path, never inferred from folder name or nesting.
- One global router (`~/.local/bin/agent-context`); each project owns its own manifest and
  pointers under `.ai/` inside that project's repo.
- No daemon, no database, no LLM calls, no network access, no embeddings/RAG.
- Automatic rolling checkpoint after every completed turn.
- Interruption / API-failure / pre-compact checkpointing where the harness exposes the event.
- `/clear` recovery through a SessionEnd -> SessionStart lineage handshake.
- Keeps the last 3 completed turn pairs per live session, and the last 5 material session
  archives per repository — everything else is pruned automatically.
- The full provider transcript is only ever referenced by path, never loaded automatically.
- Explicit, opt-in durable handoff promotion (nothing is promoted to the canonical handoff
  file without an explicit `agent-context handoff` call).
- Concurrent sessions in the same repo never share one rolling state file.

## Commands

```bash
agent-context init
agent-context doctor
agent-context doctor --all-projects
agent-context recover --list
agent-context recover --session <id>
agent-context handoff --mode rotate
agent-context acknowledge --status accepted|rejected|needs-clarification
agent-context install-hooks --harness all
agent-context set-default-format --format md|yaml
```

Claude Code explicit handoff: `/handoff`

Codex explicit handoff: `$handoff`

## Install

```bash
./install.sh [--claude|--codex|--both] [--md|--yaml]
```

- `--claude` / `--codex` / `--both` (default `--both`): which harness integration (skill file +
  hooks) to install. Restricting to one harness does not touch the other's skill directory or
  hook config at all.
- `--md` (default) / `--yaml`: the default `[handoff].format` written into
  `.ai/project-context.toml` by `agent-context init` for projects that don't already have a
  manifest. Already-initialized projects keep whatever format they were set up with; change a
  single project's format by hand-editing its manifest (`format = "yaml"`) or setting
  `AGENT_CONTEXT_FORMAT=yaml` in that project's environment.

Codex non-managed hooks require review/trust through `/hooks` before they run.

## Project onboarding

```bash
cd /path/to/your-repo   # must already be (or become) a Git repository — see Requirements above
agent-context init
agent-context doctor
```

`init` is idempotent. It creates or safely augments, inside that repo only:

- `AGENTS.md` — a short Git-identity guard plus a continuity block, appended without disturbing
  any existing content.
- `.ai/project-context.toml` — the project's manifest (format, pointers, retention).
- `.ai/PROJECT.md` — a one-page identity summary.
- `.ai/state/HANDOFF.md` — the canonical durable handoff, promoted to by explicit `handoff` calls.

The global harness integrations (hooks, skill files) are installed once, machine-wide, by
`install.sh`; they are not copied into every project.

## Retention defaults

- 3 completed turn pairs per live session.
- 5 material session archives per repository.
- 8,000-character startup/recovery card cap (typically about 1–2k tokens).
- Full transcript: path pointer only, never auto-loaded.

## Secret redaction

Every checkpoint and handoff write passes free-text session fields (prompts, assistant turns,
tool-call hints, error text, dirty-file lines, and any `--objective`/`--next-action`/`--note`
you pass to `handoff`) through a redactor before anything touches disk. It matches JWTs,
`ghp_`/`github_pat_`-style tokens, AWS access-key IDs, Slack tokens, `Authorization`/cookie
headers, generic `KEY=VALUE`-shaped credentials, `user:pass@host` URLs, and PEM private-key
blocks, replacing the value with a `[REDACTED:...]` marker. Structured fields (git HEAD, branch,
session id) are never run through the redactor, so a real commit SHA is never mistaken for a
secret. This is a mechanical safety net, not a substitute for not pasting secrets in the first
place — treat it as a last line of defense.

## Suggested skills

Every handoff ends with a short "suggested skills for next session" section, inferred from
keywords in the objective/next-action/note (tests → run the suite first, PR/review →
`code-review`, deploy → verify in the running app, secrets/security → `security-review`,
charts → `dataviz`, hooks/settings → config tooling), falling back to an explicit "none
inferred" line rather than guessing something specific.

## Partial-failure recovery

Multi-step checkpoint writes (archiving a session, promoting a handoff) record a small intent
journal before the first file changes and clear it after the last step completes. If the
process is interrupted mid-write, `agent-context doctor` reports the stale journal, and the
next `SessionStart` in that repository heals it automatically — resuming the remaining steps
so nothing is left individually-intact-but-collectively-inconsistent.

## Claim checking

A narrow, mechanical check — not a general prose verifier — for two specific, commonly
mechanically-checkable claims: "tests pass" and "committed". "Committed" is checked by
comparing the repo's HEAD at session start vs. now; "tests pass" is checked against this
session's own recorded tool-call log for a matching test-runner command (and its recorded
result, when the harness reports one). A mismatch is appended to the handoff under a
"Claim check" section instead of being silently trusted.

## Acknowledge step

When a new session's recovery card reports a recovered predecessor, it should run
`agent-context acknowledge --status accepted|rejected|needs-clarification` once it has
evaluated the card — logged to a per-repo `acknowledgements.jsonl` so recovery isn't silently
assumed to have landed correctly.

## Fail-open by design

`agent-context` registers no `PreToolUse` hook on either harness, so it structurally cannot
block a tool call regardless of its own exit code. The `hook` subcommand's entrypoint also
catches any internal exception and always exits 0, so a bug in this tool never blocks normal
Claude Code or Codex operation.

## YAML format option

`[handoff] format = "yaml"` (or `AGENT_CONTEXT_FORMAT=yaml`, or `install.sh --yaml` to make it
the default for newly-initialized projects) switches checkpoint/handoff files to a flat,
hand-emitted YAML representation instead of Markdown. No YAML parser is added as a dependency —
the machine state stays JSON (a strict YAML subset); only the human-facing handoff/checkpoint
text is emitted as YAML.

**Real measurement, not an assumption:** tokenizing (`tiktoken`, cl100k_base) six real archived
session handoffs in both formats, with identical feature content and only the serialization
differing:

| session | MD tokens | YAML tokens | delta |
|---|---:|---:|---:|
| 1 | 2568 | 2822 | +9.9% |
| 2 | 1889 | 2066 | +9.4% |
| 3 | 1656 | 1748 | +5.6% |
| 4 | 1572 | 1645 | +4.6% |
| 5 | 1614 | 1743 | +8.0% |
| 6 | 1525 | 1611 | +5.6% |

YAML was **more** tokens than Markdown on every session measured (+4.6% to +9.9%), the opposite
of the common assumption that YAML is more token-efficient for this kind of content. Markdown
stays the default; YAML is opt-in for anyone who still prefers the format for other reasons
(diffing, tooling, personal taste).

## Deferred idea (not built, logged for later)

**Background-agent-handoff variant**: instead of saving a handoff for the *same* session to
recover later, render the handoff and launch a background agent seeded with it as its prompt,
returning immediately. That's a different use case (handing off to a parallel worker, not
self-recovery) and is out of scope for now — worth its own feature rather than a mode flag on
`agent-context handoff`.

## Changelog

- **v1.2** — secret redaction on every checkpoint/handoff write; suggested-skills section on
  every handoff; partial-failure journal + self-healing for multi-step checkpoint writes;
  narrow claim-checker for "tests pass"/"committed"; explicit acknowledge step for recovery;
  YAML format option; `install.sh --claude/--codex/--both` and `--md/--yaml` flags.
- **v1.1** — retains any session with a prompt, completed turn, material tool event, failure,
  or promoted handoff (material score is ranking only, not a retention gate); fixed a one-turn
  `/clear` recovery loss; `recover --list` is safe outside a Git repository; managed `AGENTS.md`
  block updates preserve existing file mode and line-ending bytes; Codex `SessionEnd`/
  `Interrupt` hook timeouts normalized to the 3-second host maximum; startup context explicitly
  prohibits broad legacy/session-log rediscovery when no exact predecessor is recovered.

## License

MIT — see `LICENSE`.
