#!/usr/bin/env bash
# ============================================================================
# approve-spec.sh — Privileged path for flipping a spec to Approved status
# ============================================================================
# Single write path for status='Approved'. Records every attempt to the
# spec_approvals audit table (PID/PPID/TTY/timestamp) and handles supersession
# of any prior Approved spec for the same issue.
#
# Usage: bash ~/.claude/hooks/approve-spec.sh <spec_id>
#
# Originally (spec #8 as-designed) required a cryptographic token. That was
# security theater — the orchestrator that types APPROVED is the same entity
# that would read the secret file, so the token added no real gate. What
# remains useful is the audit trail: every approval is logged.
#
# Validates:
#   - spec exists
#   - dod_json is non-null, valid JSON, ≥1 check (mirrors the DB CHECK)
# On success:
#   - supersedes any prior Approved spec for the same issue_id
#   - writes status='Approved', approved_at=now, approved_by='user'
#   - inserts audit row with outcome='approved'
# On failure: inserts audit row with outcome='rejected'.
# ============================================================================
set -euo pipefail

DB_PATH="$HOME/talking-rock/product/db/product.db"

_db_approve() {
  printf '.timeout 5000\nPRAGMA foreign_keys=ON;\n%s\n' "$1" | sqlite3 "$DB_PATH"
}

_record_audit() {
  # Args: $1=spec_id $2=outcome
  local spec_id="$1" outcome="$2"
  local pid ppid tty_val
  pid=$$
  ppid=$PPID
  tty_val=$(tty 2>/dev/null || echo "notty")
  local safe_tty="${tty_val//\'/\'\'}"
  _db_approve "INSERT INTO spec_approvals (spec_id, caller_pid, caller_ppid, tty, outcome)
               VALUES (${spec_id}, ${pid}, ${ppid}, '${safe_tty}', '${outcome}');" 2>/dev/null || true
}

# ---- Argument validation ---------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "ERROR: approve-spec.sh requires <spec_id> argument." >&2
  echo "Usage: bash ~/.claude/hooks/approve-spec.sh <spec_id>" >&2
  exit 1
fi

SPEC_ID="$1"

if ! [[ "$SPEC_ID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: spec_id must be a positive integer, got: ${SPEC_ID}" >&2
  exit 1
fi

# ---- Spec existence check --------------------------------------------------

SPEC_EXISTS=$(_db_approve "SELECT COUNT(*) FROM specs WHERE id=${SPEC_ID};" 2>/dev/null || echo "0")
if [[ "$SPEC_EXISTS" != "1" ]]; then
  echo "ERROR: spec #${SPEC_ID} does not exist." >&2
  _record_audit "$SPEC_ID" "rejected"
  exit 1
fi

# ---- DoD validation (mirrors DB CHECK constraint) --------------------------

DOD=$(_db_approve "SELECT dod_json FROM specs WHERE id=${SPEC_ID};" 2>/dev/null || echo "")
if [[ -z "$DOD" || "$DOD" == "null" ]]; then
  echo "ERROR: cannot approve spec ${SPEC_ID} — dod_json is absent or null." >&2
  _record_audit "$SPEC_ID" "rejected"
  exit 1
fi

DOD_COUNT=$(_db_approve "SELECT json_array_length(dod_json) FROM specs WHERE id=${SPEC_ID};" 2>/dev/null || echo "0")
if [[ -z "$DOD_COUNT" || "$DOD_COUNT" == "0" ]]; then
  echo "ERROR: cannot approve spec ${SPEC_ID} — dod_json is empty or invalid." >&2
  _record_audit "$SPEC_ID" "rejected"
  exit 1
fi

# ---- Supersede any prior Approved spec for same issue ----------------------

ISSUE_ID=$(_db_approve "SELECT issue_id FROM specs WHERE id=${SPEC_ID};" 2>/dev/null || echo "")
if [[ -n "$ISSUE_ID" && "$ISSUE_ID" != "NULL" ]]; then
  PRIOR_ID=$(_db_approve "SELECT id FROM specs WHERE issue_id=${ISSUE_ID} AND status='Approved' AND id != ${SPEC_ID} LIMIT 1;" 2>/dev/null || echo "")
  if [[ -n "$PRIOR_ID" ]]; then
    echo "INFO: superseding prior Approved spec #${PRIOR_ID} for issue #${ISSUE_ID}" >&2
    _db_approve "UPDATE specs SET status='Superseded', updated_at=datetime('now') WHERE id=${PRIOR_ID};"
  fi
fi

# ---- Write Approved status -------------------------------------------------

_db_approve "UPDATE specs SET status='Approved', approved_at=datetime('now'), approved_by='user', updated_at=datetime('now') WHERE id=${SPEC_ID};"

_record_audit "$SPEC_ID" "approved"

echo "INFO: spec #${SPEC_ID} approved successfully." >&2
exit 0
