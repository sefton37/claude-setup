#!/usr/bin/env bash
# ============================================================================
# contract-gate.sh — Gate 0 enforcement on Edit/Write
# ============================================================================
# PreToolUse hook for Edit/Write/MultiEdit. Enforces: no code change proceeds
# without an APPROVED spec for the active session issue.
#
# Flow:
#   1. Read tool-input JSON from stdin.
#   2. If the path is one the gate ignores (spec docs, memory, session notes,
#      the product DB tooling itself), allow.
#   3. Run trivial-classifier in hook mode. If TRIVIAL, allow.
#   4. Look up an active Approved spec via spec-ops. If none, BLOCK with a
#      message that tells Claude to invoke the product-owner agent.
#   5. If a spec exists, run the "continuous" subset of DoD checks (cheap:
#      existence, absence, no-fabrication). Record results. Never BLOCK on
#      continuous failures — they're tracked, auditor enforces at commit time.
#
# Exit codes (Claude PreToolUse convention):
#   0  allow
#   2  block (stderr shown to Claude)
# ============================================================================

set -uo pipefail

# Bypass for self-modifications to the harness itself
HARNESS_BYPASS_PREFIXES=(
  "$HOME/.claude/"
  "$HOME/talking-rock/product/"
  "$HOME/.claude/projects/-home-kellogg/memory/"
)

source "$HOME/.claude/hooks/spec-ops.sh" 2>/dev/null || exit 0

input=$(cat 2>/dev/null || true)
[[ -z "$input" ]] && exit 0

# Must be an Edit/Write variant
tool=$(echo "$input" | jq -r '.tool_name // empty' 2>/dev/null)
case "$tool" in
  Edit|Write|MultiEdit) : ;;
  *) exit 0 ;;
esac

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$file_path" ]] && exit 0

# ---- Harness bypass --------------------------------------------------------
for prefix in "${HARNESS_BYPASS_PREFIXES[@]}"; do
  if [[ "$file_path" == "$prefix"* ]]; then
    exit 0
  fi
done

# ---- Non-code bypass -------------------------------------------------------
# Docs, memory, markdown notes outside a repo don't require a spec.
case "$file_path" in
  *.md|*/MEMORY.md|*/NOTES.md|*/README.md)
    # Still require spec if the md is a spec target or project doc
    # Heuristic: project-internal README/CLAUDE require spec — handled below
    if [[ "$(basename "$file_path")" == "CLAUDE.md" ]]; then
      : # fall through to gate
    else
      exit 0
    fi
    ;;
esac

# ---- Trivial bypass --------------------------------------------------------
classifier_out=$(echo "$input" | bash "$HOME/.claude/hooks/trivial-classifier.sh" 2>&1 || true)
verdict=$(echo "$classifier_out" | head -1)
if [[ "$verdict" == "TRIVIAL" ]]; then
  exit 0
fi

# ---- Spec lookup -----------------------------------------------------------
spec_id=$(get_active_spec_id "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true)

if [[ -z "$spec_id" ]]; then
  cat >&2 <<EOF
[contract-gate] BLOCKED — no Approved spec for the active session issue.

File:     $file_path
Tool:     $tool
Verdict:  $verdict

Gate 0 of the verification chain requires an approved Spec before code is
written. Invoke the product-owner agent now to draft one:

  > Use the product-owner agent to draft a spec for the current request.

The spec must be APPROVED by the user (not by any agent) before this gate
will open. See ~/.claude/agents/product-owner.md.

If this edit is trivial and the classifier is wrong, you may either:
  - Rephrase/split the edit so the classifier recognizes it as trivial, or
  - Ask the user to override with an explicit "trivial, proceed" statement
    and record that consent in memory/sessions.md.
EOF
  exit 2
fi

status=$(get_spec_status "$spec_id" 2>/dev/null || true)
if [[ "$status" != "Approved" ]]; then
  cat >&2 <<EOF
[contract-gate] BLOCKED — spec #${spec_id} exists but status is '${status}', not 'Approved'.

Only the USER can flip the status to Approved by replying APPROVED in the
session. No agent (including you) may self-approve.

If the user has just said APPROVED, the orchestrator should run:
  source ~/.claude/hooks/spec-ops.sh && set_spec_status ${spec_id} Approved

Then retry this edit.
EOF
  exit 2
fi

# ---- Empty DoD guard on Approved spec (blocking) ---------------------------
# If the active spec is Approved but has no DoD entries, the contract is in a
# bad state (e.g., constraint was added after approval, or a direct DB write
# bypassed the shell guard in set_spec_status). Block with a distinct message.
dod=$(get_spec_dod "$spec_id")
dod_ok=0
if [[ -n "$dod" && "$dod" != "null" ]]; then
  # Use SQLite json_array_length to validate: mirrors the DB CHECK constraint exactly.
  # Returns empty/null if dod is not valid JSON; returns 0 if valid JSON but empty array.
  dod_count=$(sqlite3 "$DB_PATH" "SELECT json_array_length(json('$(echo "$dod" | sed "s/'/''/g")'))" 2>/dev/null || echo "0")
  if [[ "$dod_count" =~ ^[0-9]+$ ]] && [[ "$dod_count" -ge 1 ]]; then
    dod_ok=1
  fi
fi
if [[ "$dod_ok" -eq 0 ]]; then
  cat >&2 <<EOF
[contract-gate] BLOCKED — spec #${spec_id} is Approved but has an empty or invalid DoD.

File:     $file_path
Tool:     $tool

The active spec (#${spec_id}) has status=Approved but its dod_json is absent,
empty, or not valid JSON. This is a bad-state condition: mechanical verification
cannot proceed without at least one DoD check.

Fix options:
  1. Add DoD checks:  source ~/.claude/hooks/spec-ops.sh && update_spec ${spec_id} dod_json '[...]'
  2. Re-run set_spec_status to validate:  set_spec_status ${spec_id} Approved
  3. If this spec is being replaced, create a new spec for the current request.

This message differs from "no spec" — a spec exists but its DoD is empty.
EOF
  exit 2
fi

# ---- Continuous DoD checks (cheap subset, non-blocking) --------------------
# Run the cheap check types now; record results; never block on failure here.
# The auditor is the blocking gate at commit time.
if [[ "$dod_ok" -eq 1 ]]; then
  {
    while IFS= read -r json_line; do
      [[ -z "$json_line" ]] && continue
      ctype=$(echo "$json_line" | jq -r '.type // "behavior"')
      case "$ctype" in
        existence|absence|no-fabrication|count)
          cid=$(echo "$json_line" | jq -r '.id // "unknown"')
          cmd=$(echo "$json_line" | jq -r '.check // ""')
          expected=$(echo "$json_line" | jq -r '.expected // ""')
          out=$(run_dod_check "$json_line")
          result="${out%%|||*}"
          actual="${out#*|||}"
          record_check "$spec_id" "$cid" "$ctype" "continuous" \
                       "$result" "$cmd" "$expected" "$actual" 1
          ;;
      esac
    done < <(echo "$dod" | jq -c '.[]' 2>/dev/null)
  } >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

exit 0
