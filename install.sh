#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
TARGET="$BIN_DIR/agent-context"

HARNESS="both"
FORMAT="md"
for arg in "$@"; do
  case "$arg" in
    --claude) HARNESS="claude" ;;
    --codex) HARNESS="codex" ;;
    --both) HARNESS="both" ;;
    --yaml) FORMAT="yaml" ;;
    --md) FORMAT="md" ;;
    -h|--help)
      cat <<'USAGE'
Usage: install.sh [--claude|--codex|--both] [--md|--yaml]

  --claude   install the Claude Code integration only (skill + hooks)
  --codex    install the Codex integration only (skill + hooks)
  --both     install both (default)

  --md       new projects default to Markdown handoffs/checkpoints (default)
  --yaml     new projects default to YAML handoffs/checkpoints

The format flag only sets the default used by `agent-context init` for
projects that don't already have a manifest; any already-initialized
project keeps whatever [handoff].format it already has.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (see --help)" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$BIN_DIR"
if [ -e "$TARGET" ]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  cp -p "$TARGET" "${TARGET}.backup-${TS}"
  echo "Backed up existing agent-context to ${TARGET}.backup-${TS}"
fi
install -m 0755 "$SRC_DIR/bin/agent-context" "$TARGET"

if [ "$HARNESS" = "claude" ] || [ "$HARNESS" = "both" ]; then
  mkdir -p "$HOME/.claude/skills/handoff"
  install -m 0644 "$SRC_DIR/skills/claude-handoff/SKILL.md" "$HOME/.claude/skills/handoff/SKILL.md"
fi
if [ "$HARNESS" = "codex" ] || [ "$HARNESS" = "both" ]; then
  mkdir -p "$HOME/.codex/skills/handoff"
  install -m 0644 "$SRC_DIR/skills/codex-handoff/SKILL.md" "$HOME/.codex/skills/handoff/SKILL.md"
fi

"$TARGET" set-default-format --format "$FORMAT"

if [ "$HARNESS" = "both" ]; then
  "$TARGET" install-hooks --harness all
else
  "$TARGET" install-hooks --harness "$HARNESS"
fi

cat <<MSG

Installed agent-context.
  Harness installed: $HARNESS
  Default handoff/checkpoint format for newly-initialized projects: $FORMAT

IMPORTANT:
  1. In Codex, open /hooks and review/trust the new agent-context entries.
  2. Any other tool's existing hooks in these config files are left in place untouched.

Initialize a repository with:
  cd /path/to/repo
  agent-context init
  agent-context doctor
MSG
