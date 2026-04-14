#!/usr/bin/env bash
# ============================================================================
# approve-spec.sh — Privileged path for flipping a spec to Approved status
# ============================================================================
# This is the ONLY permitted path for writing status='Approved' to the specs
# table. It validates a presented credential against ~/.claude/approval-secret
# before writing.
#
# Usage: bash ~/.claude/hooks/approve-spec.sh <spec_id> <credential>
#
# The credential must exactly match the contents of ~/.claude/approval-secret.
# The file must exist and be mode 600. If either condition is unmet, approval
# is rejected and an audit row is written with outcome='rejected'.
#
# Orchestrator runtime flow (after user says APPROVED):
#   THE_SECRET=$(cat ~/.claude/approval-secret)
#   bash ~/.claude/hooks/approve-spec.sh <spec_id> "$THE_SECRET"
#   unset THE_SECRET
#
# Direct agent Bash calls will fail because they have no access to the secret
# file contents and cannot forge a matching credential.
#
# Spec #8 — Gap 10: Harden spec approval against agent forgery
# ============================================================================
set -euo pipefail

APPROVAL_SECRET_FILE="$HOME/.claude/approval-secret"
DB_PATH="$HOME/talking-rock/product/db/product.db"

_db_approve() {
  printf '.timeout 5000\nPRAGMA foreign_keys=ON;\n%s\n' "$1" | sqlite3 "$DB_PATH"
}

_record_audit() {
  # Args: $1=spec_id $2=outcome $3=cred_hash
  local spec_id="$1" outcome="$2" cred_hash="${3:-}"
  local pid ppid tty_val
  pid=$$
  ppid=$PPID
  tty_val=$(tty 2>/dev/null || echo "notty")
  local safe_tty="${tty_val//\'/\'\'}"
  local safe_hash="${cred_hash//\'/\'\'}"
  _db_approve "INSERT INTO spec_approvals (spec_id, caller_pid, caller_ppid, tty, token_hash, outcome)
               VALUES (${spec_id}, ${pid}, ${ppid}, '${safe_tty}', '${safe_hash}', '${outcome}');"
}

# ---- Argument validation ---------------------------------------------------

if [[ $# -lt 2 ]]; then
  echo "ERROR: approve-spec.sh requires <spec_id> and <credential> arguments." >&2
  echo "Usage: bash ~/.claude/hooks/approve-spec.sh <spec_id> <credential>" >&2
  exit 1
fi

SPEC_ID="$1"
PROVIDED_CRED="$2"

# Validate spec_id is numeric
if ! [[ "$SPEC_ID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: spec_id must be a positive integer, got: ${SPEC_ID}" >&2
  exit 1
fi

# ---- Secret file validation ------------------------------------------------

if [[ ! -f "$APPROVAL_SECRET_FILE" ]]; then
  echo "ERROR: approval-secret file not found at ${APPROVAL_SECRET_FILE}." >&2
  echo "       Run the setup steps to create it (mode 600) before approving specs." >&2
  echo "" >&2
  echo "Bootstrap setup:" >&2
  echo "  python3 -c \"import secrets; print(secrets.token_hex(32))\" > ~/.claude/approval-secret" >&2
  echo "  chmod 600 ~/.claude/approval-secret" >&2
  exit 1
fi

# Mode check: must be 600
SECRET_MODE=$(stat -c '%a' "$APPROVAL_SECRET_FILE" 2>/dev/null || echo "000")
if [[ "$SECRET_MODE" != "600" ]]; then
  echo "ERROR: approval-secret file has unsafe permissions (${SECRET_MODE}). Must be 600." >&2
  echo "       Run: chmod 600 ~/.claude/approval-secret" >&2
  exit 1
fi

# Read the stored value (strip trailing newline)
STORED_CRED=$(tr -d '\n' < "$APPROVAL_SECRET_FILE")

if [[ -z "$STORED_CRED" ]]; then
  echo "ERROR: approval-secret file is empty." >&2
  exit 1
fi

# ---- Spec existence check --------------------------------------------------

SPEC_EXISTS=$(_db_approve "SELECT COUNT(*) FROM specs WHERE id=${SPEC_ID};" 2>/dev/null || echo "0")
if [[ "$SPEC_EXISTS" != "1" ]]; then
  # Hash the credential for audit even on rejection (never store plaintext)
  CRED_HASH=$(printf '%s' "${PROVIDED_CRED}" | sha256sum | cut -d' ' -f1)
  echo "ERROR: spec #${SPEC_ID} does not exist." >&2
  # Best-effort audit row; FK violation is expected and acceptable here
  _db_approve "INSERT INTO spec_approvals (spec_id, caller_pid, caller_ppid, tty, token_hash, outcome)
               VALUES (${SPEC_ID}, $$, $PPID, '$(tty 2>/dev/null || echo notty)', '${CRED_HASH}', 'rejected');" 2>/dev/null || true
  exit 1
fi

# ---- Credential validation -------------------------------------------------

# Hash both sides for constant-time-ish comparison and audit storage
# Never store or print the plaintext credential anywhere
CRED_HASH=$(printf '%s' "${PROVIDED_CRED}" | sha256sum | cut -d' ' -f1)
STORED_HASH=$(printf '%s' "${STORED_CRED}" | sha256sum | cut -d' ' -f1)

if [[ "$CRED_HASH" != "$STORED_HASH" ]]; then
  echo "ERROR: credential mismatch — approval rejected for spec #${SPEC_ID}." >&2
  _record_audit "$SPEC_ID" "rejected" "$CRED_HASH"
  exit 1
fi

# ---- DoD validation --------------------------------------------------------

DOD=$(_db_approve "SELECT dod_json FROM specs WHERE id=${SPEC_ID};" 2>/dev/null || echo "")
if [[ -z "$DOD" || "$DOD" == "null" ]]; then
  echo "ERROR: cannot approve spec ${SPEC_ID} — dod_json is absent or null." >&2
  _record_audit "$SPEC_ID" "rejected" "$CRED_HASH"
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
# This is the only call site in the codebase that may write status='Approved'.
# set_spec_status delegates here via approve-spec; it does not write Approved directly.

_db_approve "UPDATE specs SET status='Approved', approved_at=datetime('now'), approved_by='user', updated_at=datetime('now') WHERE id=${SPEC_ID};"

# ---- Record successful audit row ------------------------------------------

_record_audit "$SPEC_ID" "approved" "$CRED_HASH"

echo "INFO: spec #${SPEC_ID} approved successfully." >&2
exit 0
