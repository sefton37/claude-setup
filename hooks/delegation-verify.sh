#!/usr/bin/env bash
# delegation-verify.sh — PostToolUse hook for Agent.
#
# After a subagent completes, extract any file paths mentioned in its output
# and run `git diff --stat` + `wc -l` on them. Inject the real numbers into
# the transcript so the orchestrator cannot be deceived by a prose report.
#
# This is the strongest mechanical defense against the hallucination pattern
# documented in ~/.claude/projects/-home-kellogg/memory/hallucinations.md:
# agents describing edits that never persisted. Even if the agent's report
# says "modified lines 500–600", this hook surfaces the actual diff.
#
# Invoked via settings.json PostToolUse matcher "Agent".
# Input: JSON on stdin with the agent's tool_result.
# Exit: 0 always. Output on stdout is injected into the transcript.

set -u

LOG_DIR="$HOME/.claude/hooks/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/delegation-verify.log"

PAYLOAD=$(timeout 2 cat 2>/dev/null || echo "{}")

# Extract the agent's result text. Shape may vary; grab the biggest "text"
# field present. Best-effort — we just need paths out of it.
RESULT_TEXT=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def walk(o, out):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ("text", "content", "result", "output") and isinstance(v, str):
                out.append(v)
            else:
                walk(v, out)
    elif isinstance(o, list):
        for v in o: walk(v, out)

out = []
walk(d, out)
print("\n".join(out))
' 2>/dev/null)

if [[ -z "${RESULT_TEXT:-}" ]]; then
  exit 0
fi

# Only run if we appear to be in a git repo — otherwise nothing meaningful
# to compare against. Check by walking up from CWD.
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel)

# Extract up to 20 file paths that (a) look like project paths and (b) exist
# in the repo. Accept both absolute and relative forms.
PATHS=$(printf '%s' "$RESULT_TEXT" \
  | grep -oE '([a-zA-Z0-9_./-]+/)+[a-zA-Z0-9_./-]+\.(kt|kts|java|py|ts|tsx|js|jsx|rs|go|rb|swift|sh|md|xml|json|yaml|yml|gradle|properties|toml)' \
  | sort -u \
  | head -20)

if [[ -z "${PATHS:-}" ]]; then
  exit 0
fi

# Build a report of files actually modified in the working tree.
CHANGED_FILES=$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | awk '{print $NF}')

REPORT=""
CLAIMED_BUT_UNCHANGED=""
for p in $PATHS; do
  # Normalize: try both as-is and relative-to-repo.
  if [[ -f "$p" ]]; then
    ABSPATH="$p"
  elif [[ -f "$REPO_ROOT/$p" ]]; then
    ABSPATH="$REPO_ROOT/$p"
  else
    continue
  fi

  RELPATH=$(realpath --relative-to="$REPO_ROOT" "$ABSPATH" 2>/dev/null || echo "$p")
  LINES=$(wc -l < "$ABSPATH" 2>/dev/null || echo "?")

  # Is this file in the working-tree diff?
  if printf '%s\n' "$CHANGED_FILES" | grep -qxF "$RELPATH"; then
    DIFFSTAT=$(cd "$REPO_ROOT" && git diff --stat -- "$RELPATH" 2>/dev/null | head -1)
    REPORT+=$(printf '  ✓ %s (%s lines) — %s\n' "$RELPATH" "$LINES" "${DIFFSTAT:-(staged)}")$'\n'
  else
    # File mentioned but not changed. Could be innocent (read-only reference)
    # but suspicious if agent claimed to modify it.
    if printf '%s' "$RESULT_TEXT" | grep -iqE "(modif|edit|updat|chang|add|wrote|wrot|creat).{0,40}$RELPATH" ||
       printf '%s' "$RESULT_TEXT" | grep -iqE "$RELPATH.{0,40}(modif|edit|updat|chang|add|wrote|wrot)"; then
      CLAIMED_BUT_UNCHANGED+=$(printf '  ✗ %s (%s lines) — NO DIFF\n' "$RELPATH" "$LINES")$'\n'
    fi
  fi
done

if [[ -n "$REPORT" || -n "$CLAIMED_BUT_UNCHANGED" ]]; then
  printf '\n── DELEGATION-VERIFY ──────────────────────────────\n'
  if [[ -n "$REPORT" ]]; then
    printf 'Files with actual changes:\n%s' "$REPORT"
  fi
  if [[ -n "$CLAIMED_BUT_UNCHANGED" ]]; then
    printf '\n⚠️  Files the agent discussed as modified but show NO working-tree diff:\n%s' "$CLAIMED_BUT_UNCHANGED"
    printf '    This is the hallucination pattern from hallucinations.md.\n'
    printf '    Verify independently before trusting the agent report.\n'
    printf '[%s] UNCHANGED_CLAIMED %s\n' "$(date -Iseconds)" "$(printf '%s' "$CLAIMED_BUT_UNCHANGED" | tr '\n' ' ')" >> "$LOG_FILE"
  fi
  printf '───────────────────────────────────────────────────\n\n'
fi

exit 0
