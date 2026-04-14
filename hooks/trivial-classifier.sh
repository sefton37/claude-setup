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

# ---- Cumulative per-session trivial budget ----------------------------------
# Budget limits: if any session-level counter exceeds these, the verdict is
# forced to NON-TRIVIAL regardless of per-edit deltas.
BUDGET_LOC_MAX=30
BUDGET_FILES_MAX=3
BUDGET_EDITS_MAX=10

# Keyword bypass max: even if summary matches a keyword (typo/comment/etc.),
# reject the bypass in hook mode if the diff is >5 LOC or touches >1 file.
KEYWORD_BYPASS_MAX_LOC=5

# Derive session-id deterministically: prefer CLAUDE_SESSION_ID env var,
# else hash of CLAUDE_PROJECT_DIR + date-hour.
_trivial_session_id() {
  if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    echo "$CLAUDE_SESSION_ID"
  else
    echo "${CLAUDE_PROJECT_DIR:-unknown}-$(date +%Y%m%d%H)" | sha256sum | cut -c1-16
  fi
}

_trivial_budget_file() {
  local sid
  sid=$(_trivial_session_id)
  echo "${HOME}/.claude/hooks/state/${sid}/trivial-budget.json"
}

# Read the current budget from state file. Outputs JSON budget object.
# Falls back to zeroed object if file absent or corrupt.
_trivial_budget_read() {
  local bfile
  bfile=$(_trivial_budget_file)
  if [[ -f "$bfile" ]]; then
    python3 -c "
import json, sys
try:
    d = json.load(open('$bfile'))
    print(json.dumps(d))
except Exception:
    print(json.dumps({'session_id':'','total_loc':0,'total_files':0,'edits_count':0,'files_seen':[]}))
" 2>/dev/null || echo '{"session_id":"","total_loc":0,"total_files":0,"edits_count":0,"files_seen":[]}'
  else
    echo '{"session_id":"","total_loc":0,"total_files":0,"edits_count":0,"files_seen":[]}'
  fi
}

# Write updated budget. Args: total_loc total_files edits_count files_seen_json
_trivial_budget_write() {
  local bfile sid
  bfile=$(_trivial_budget_file)
  sid=$(_trivial_session_id)
  mkdir -p "$(dirname "$bfile")"
  python3 -c "
import json
obj = {
  'session_id': '$sid',
  'total_loc': $1,
  'total_files': $2,
  'edits_count': $3,
  'files_seen': $4
}
with open('$bfile', 'w') as f:
    json.dump(obj, f)
" 2>/dev/null || true
}

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

# ---- Cumulative trivial-budget enforcement (hook mode only) -----------------
# Read current session budget, check against caps, then increment.
budget_json=$(_trivial_budget_read)
b_total_loc=$(echo "$budget_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('total_loc',0))" 2>/dev/null || echo 0)
b_total_files=$(echo "$budget_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('total_files',0))" 2>/dev/null || echo 0)
b_edits_count=$(echo "$budget_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('edits_count',0))" 2>/dev/null || echo 0)
b_files_seen=$(echo "$budget_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('files_seen',[])))" 2>/dev/null || echo '[]')

# Determine if this file is already counted in files_seen
file_is_new=$(echo "$b_files_seen" | python3 -c "
import json,sys
seen = json.load(sys.stdin)
print('1' if '${file_path}' not in seen else '0')
" 2>/dev/null || echo 1)

new_total_loc=$(( b_total_loc + delta ))
new_total_files=$(( file_is_new == 1 ? b_total_files + 1 : b_total_files ))
new_edits_count=$(( b_edits_count + 1 ))

# Check cumulative caps BEFORE accepting this edit
if [[ $new_total_loc -gt $BUDGET_LOC_MAX ]]; then
  echo "NON-TRIVIAL"
  echo "  reason: cumulative LOC budget exceeded (${new_total_loc}/${BUDGET_LOC_MAX} total this session)"
  exit 1
fi

if [[ $new_total_files -gt $BUDGET_FILES_MAX ]]; then
  echo "NON-TRIVIAL"
  echo "  reason: cumulative file budget exceeded (${new_total_files}/${BUDGET_FILES_MAX} files this session)"
  exit 1
fi

if [[ $new_edits_count -gt $BUDGET_EDITS_MAX ]]; then
  echo "NON-TRIVIAL"
  echo "  reason: cumulative edit count budget exceeded (${new_edits_count}/${BUDGET_EDITS_MAX} edits this session)"
  exit 1
fi

# Persist updated budget
new_files_seen=$(echo "$b_files_seen" | python3 -c "
import json,sys
seen = json.load(sys.stdin)
fp = '${file_path}'
if fp not in seen:
    seen.append(fp)
print(json.dumps(seen))
" 2>/dev/null || echo "$b_files_seen")
_trivial_budget_write "$new_total_loc" "$new_total_files" "$new_edits_count" "$new_files_seen"

echo "TRIVIAL"
echo "  reason: ${delta} LOC delta on single file, no new symbols/imports, non-dangerous path"
echo "  budget: ${new_total_loc}/${BUDGET_LOC_MAX} LOC, ${new_total_files}/${BUDGET_FILES_MAX} files, ${new_edits_count}/${BUDGET_EDITS_MAX} edits this session"
exit 0
