#!/usr/bin/env bash
# ============================================================================
# drift-detector.sh — Scope-drift check against the active spec
# ============================================================================
# Invoked by the auditor agent and optionally from push-commit.sh.
# Compares the current git working tree + HEAD's diff file list against the
# files recorded in spec_groundings (existing) and the spec's declared new
# artifacts, and flags out-of-scope work.
#
# Usage:
#   drift-detector.sh [spec_id]       (spec_id defaults to active spec)
#
# Exits 0 if no drift, 1 if drift detected (prints report to stdout).
# ============================================================================

set -uo pipefail

source "$HOME/.claude/hooks/spec-ops.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$PROJECT_DIR" 2>/dev/null || { echo "drift-detector: cannot cd to $PROJECT_DIR"; exit 0; }

SPEC_ID="${1:-}"
[[ -z "$SPEC_ID" ]] && SPEC_ID=$(get_active_spec_id "$PROJECT_DIR")

if [[ -z "$SPEC_ID" ]]; then
  echo "drift-detector: no active spec — nothing to compare against"
  exit 0
fi

# Files we expect the session to touch: grounded files + anything the spec's
# new-artifact declarations point to. New artifacts are extracted from the
# dod_json by looking for paths in `check` strings.
GROUNDED=$(_db "SELECT path FROM spec_groundings
                WHERE spec_id=${SPEC_ID} AND kind IN ('file','test')
                  AND path IS NOT NULL;" | sort -u)

DOD=$(get_spec_dod "$SPEC_ID")
DOD_PATHS=""
if [[ -n "$DOD" && "$DOD" != "null" ]]; then
  DOD_PATHS=$(echo "$DOD" | jq -r '.[] | .check // empty' 2>/dev/null \
              | grep -oE '[A-Za-z0-9_./-]+\.(py|ts|tsx|js|jsx|go|rs|java|kt|md|sql|sh|yaml|yml|toml|json)' \
              | sort -u)
fi

EXPECTED=$(printf "%s\n%s\n" "$GROUNDED" "$DOD_PATHS" | sort -u | grep -v '^$')

# Files actually touched in this session
if git rev-parse --git-dir >/dev/null 2>&1; then
  TOUCHED=$(git diff HEAD --name-only 2>/dev/null
            git diff --cached --name-only 2>/dev/null
            git ls-files --others --exclude-standard 2>/dev/null)
  TOUCHED=$(echo "$TOUCHED" | sort -u | grep -v '^$')
else
  echo "drift-detector: not a git repo, skipping"
  exit 0
fi

if [[ -z "$TOUCHED" ]]; then
  echo "drift-detector: no files touched"
  exit 0
fi

DRIFT=$(comm -23 <(echo "$TOUCHED") <(echo "$EXPECTED" | sed "s|^${PROJECT_DIR}/||"))
DRIFT=$(echo "$DRIFT" | grep -v '^$')

# Also check out-of-scope string for substring hits
OOS=$(_db "SELECT out_of_scope FROM specs WHERE id=${SPEC_ID};" 2>/dev/null)
OOS_HITS=""
if [[ -n "$OOS" ]]; then
  while IFS= read -r touched_file; do
    [[ -z "$touched_file" ]] && continue
    if echo "$OOS" | grep -qF "$touched_file"; then
      OOS_HITS+="${touched_file}"$'\n'
    fi
  done <<< "$TOUCHED"
fi

echo "# Drift detector — spec #${SPEC_ID}"
echo ""
echo "Touched files (${TOUCHED:+$(echo "$TOUCHED" | wc -l) total}):"
echo "$TOUCHED" | sed 's/^/  /'
echo ""
echo "Expected files (grounded + declared new):"
echo "$EXPECTED" | sed 's/^/  /'
echo ""

exit_code=0
if [[ -n "$DRIFT" ]]; then
  echo "⚠ DRIFT: files touched but not grounded or declared in spec:"
  echo "$DRIFT" | sed 's/^/  - /'
  echo ""
  echo "  Either amend the spec (user approval required) or revert the drift."
  exit_code=1
fi

if [[ -n "$OOS_HITS" ]]; then
  echo "❌ OUT-OF-SCOPE: files touched that the spec explicitly marked out-of-scope:"
  echo "$OOS_HITS" | sed 's/^/  - /'
  exit_code=1
fi

if [[ $exit_code -eq 0 ]]; then
  echo "✓ No drift — every touched file is within spec scope."
fi

# Flag the spec row if drift
if [[ $exit_code -ne 0 ]]; then
  _db "UPDATE specs SET status='Drifted' WHERE id=${SPEC_ID} AND status='Approved';" 2>/dev/null || true
fi

exit $exit_code
