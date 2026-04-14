#!/usr/bin/env bash
# ============================================================================
# trivial-classifier.sh — Deterministic rule for bypassing the Spec gate
# ============================================================================
# A request is TRIVIAL iff ALL of the following hold:
#   - files_touched         <= 1
#   - loc_delta (abs)       <= 10
#   - new_symbols           == 0
#   - no test / migration / config / CI file touched
#   - no new imports / dependencies
#
# This script is invoked two ways:
#   1. By the product-owner agent with a one-line summary argument. In that
#      mode it applies a keyword heuristic to the summary. The user then
#      confirms or overrides. This is a suggestion, not a gate.
#   2. By contract-gate.sh after an Edit/Write has been proposed. In that
#      mode it reads tool-input stdin (JSON from Claude hooks) and computes
#      the delta against the file on disk. This IS a gate.
#
# Exit codes:
#   0  TRIVIAL   — may proceed without spec
#   1  NON-TRIVIAL — spec required
#   2  AMBIGUOUS — cannot classify mechanically; require spec to be safe
#
# Output on stdout: one line — TRIVIAL | NON-TRIVIAL | AMBIGUOUS
# followed by human-readable reasoning.
# ============================================================================

set -euo pipefail

MAX_LOC_DELTA=10
DANGER_PATTERNS='(^|/)(migrations?|alembic|schema\.sql|\.github|\.woodpecker|Dockerfile|docker-compose|Makefile|pyproject\.toml|requirements.*\.txt|package\.json|Cargo\.toml|go\.mod|settings\.py|CLAUDE\.md|.*\.conf|.*\.service)(/|$)'
TEST_PATTERNS='(^|/)(test_|.*_test\.|tests?/)'

mode="cli"
summary=""

# Detect mode: if stdin has JSON, we're in hook mode
if [[ ! -t 0 ]]; then
  # Try to read stdin (non-blocking best-effort)
  input=$(cat 2>/dev/null || true)
  if [[ -n "$input" ]] && echo "$input" | jq -e . >/dev/null 2>&1; then
    mode="hook"
  fi
fi

if [[ "$mode" == "cli" ]]; then
  summary="${1:-}"
  reasons=()

  # Multi-file hint
  if echo "$summary" | grep -qiE 'refactor|rewrite|migrat|rename across|multiple files|whole|pipeline|subsystem'; then
    echo "NON-TRIVIAL"
    echo "  reason: summary mentions multi-file / systemic work"
    exit 1
  fi

  # New-feature hint
  if echo "$summary" | grep -qiE '\b(add|new|create|implement|introduce|build)\b'; then
    echo "NON-TRIVIAL"
    echo "  reason: summary mentions new work (add/create/implement/build)"
    exit 1
  fi

  # Tiny-edit hint
  if echo "$summary" | grep -qiE '\b(typo|rename one|comment|log message|docstring|formatting|whitespace)\b'; then
    echo "TRIVIAL"
    echo "  reason: summary matches tiny-edit keyword (typo/comment/formatting)"
    exit 0
  fi

  echo "AMBIGUOUS"
  echo "  reason: no clear heuristic match — recommend requiring spec for safety"
  exit 2
fi

# ---- Hook mode (stdin JSON from Claude hook) -------------------------------
# Claude hook JSON shape for Edit/Write includes tool_input.file_path.
# We count LOC delta by comparing proposed content length to the file on disk.
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')
tool=$(echo "$input" | jq -r '.tool_name // empty')

if [[ -z "$file_path" ]]; then
  echo "AMBIGUOUS"
  echo "  reason: no file_path in tool input"
  exit 2
fi

# Dangerous file types always require spec
if echo "$file_path" | grep -qE "$DANGER_PATTERNS"; then
  echo "NON-TRIVIAL"
  echo "  reason: touches migration / CI / deps / config / CLAUDE.md — spec required"
  exit 1
fi

# Compute LOC delta
if [[ "$tool" == "Write" ]]; then
  new_content=$(echo "$input" | jq -r '.tool_input.content // ""')
  new_loc=$(echo "$new_content" | wc -l)
  if [[ -f "$file_path" ]]; then
    old_loc=$(wc -l < "$file_path")
  else
    old_loc=0
  fi
  delta=$(( new_loc > old_loc ? new_loc - old_loc : old_loc - new_loc ))
elif [[ "$tool" == "Edit" ]]; then
  old_str=$(echo "$input" | jq -r '.tool_input.old_string // ""')
  new_str=$(echo "$input" | jq -r '.tool_input.new_string // ""')
  old_lines=$(echo -n "$old_str" | grep -c '' || true)
  new_lines=$(echo -n "$new_str" | grep -c '' || true)
  delta=$(( new_lines > old_lines ? new_lines - old_lines : old_lines - new_lines ))
else
  echo "AMBIGUOUS"
  echo "  reason: unknown tool $tool"
  exit 2
fi

if [[ $delta -gt $MAX_LOC_DELTA ]]; then
  echo "NON-TRIVIAL"
  echo "  reason: LOC delta $delta > $MAX_LOC_DELTA"
  exit 1
fi

# Check for new imports / new def / new class / new function keywords in new content
new_payload=$(echo "$input" | jq -r '(.tool_input.new_string // .tool_input.content // "")')
if echo "$new_payload" | grep -qE '^\s*(import |from .+ import|def |class |fn |func |pub fn|public (class|fun)|export (class|function|const))'; then
  echo "NON-TRIVIAL"
  echo "  reason: introduces new symbol or import"
  exit 1
fi

echo "TRIVIAL"
echo "  reason: ${delta} LOC delta on single file, no new symbols/imports, non-dangerous path"
exit 0
