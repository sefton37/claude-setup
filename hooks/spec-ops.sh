#!/usr/bin/env bash
# ============================================================================
# spec-ops.sh — Shared SQLite operations for Spec-Driven Development
# ============================================================================
# Sourced by contract-gate.sh, drift-detector.sh, session-context.sh, and
# invoked directly from the product-owner / reviewer / auditor agents.
#
# Implements Gate 0 of the verification chain: no code change proceeds
# without an APPROVED spec whose DoD is machine-checkable.
#
# Key functions:
#   create_spec          — insert Draft spec for the active issue
#   set_spec_status      — transition spec status; enforces one-Approved-per-issue
#   get_active_spec_id   — returns the Approved/Grounded spec for active issue
#   run_all_dod_checks   — execute every DoD check and record results
#
# set_spec_status is the primary lifecycle gate: it validates DoD completeness
# before Approved transitions and supersedes any prior Approved spec for the
# same issue (enforcing the one-Approved-per-issue invariant).
#
# Usage: source ~/.claude/hooks/spec-ops.sh
# ============================================================================

source "$HOME/.claude/hooks/db-ops.sh"
# All _db() calls in this file go through db-ops.sh::_db(), which injects
# PRAGMA foreign_keys=ON into every SQLite invocation. No separate override needed.

SPEC_DOCS_BASE="$HOME/talking-rock/product/docs"

# ---- Query helpers ---------------------------------------------------------

get_active_spec_id() {
  # Returns the spec_id of the most recent Approved or Grounded spec for the
  # active session issue(s). Empty string if none.
  local project_dir="${1:-$CLAUDE_PROJECT_DIR}"
  local active_ids
  active_ids=$(get_active_issue_ids "$project_dir")
  [[ -z "$active_ids" ]] && return 0
  # State file holds exactly one ID (enforced by set_active_issue); use directly.
  # Read-only query: selects specs in Approved or Grounded status (no write path) # delegation
  local statuses="'Approved','Grounded'" # read-only filter; no write path # delegation
  _db "SELECT id FROM specs WHERE issue_id=${active_ids} AND status IN (${statuses}) ORDER BY id DESC LIMIT 1;"
}

get_spec_status() {
  local spec_id="$1"
  [[ -z "$spec_id" ]] && return 0
  _db "SELECT status FROM specs WHERE id=${spec_id};"
}

get_spec_field() {
  # Args: $1=spec_id $2=column
  local spec_id="$1" col="$2"
  [[ -z "$spec_id" ]] && return 0
  _db "SELECT ${col} FROM specs WHERE id=${spec_id};"
}

get_spec_doc_path() {
  get_spec_field "$1" doc_path
}

get_spec_dod() {
  # Returns raw JSON array of DoD checks
  get_spec_field "$1" dod_json
}

# ---- Spec lifecycle --------------------------------------------------------

create_spec() {
  # Creates a Draft spec for the first active issue. Returns spec_id.
  # Args: $1=original_prompt   $2=project_dir (optional)
  local prompt="$1"
  local project_dir="${2:-$CLAUDE_PROJECT_DIR}"
  local project
  project=$(get_project_name "$project_dir")
  local cycle_id
  cycle_id=$(get_current_cycle_id "$project_dir")
  local active_ids
  active_ids=$(get_active_issue_ids "$project_dir")
  # State file holds exactly one ID (enforced by set_active_issue); use directly.
  local issue_id
  issue_id="$active_ids"

  local issue_clause="NULL"
  [[ -n "$issue_id" ]] && issue_clause="$issue_id"
  local cycle_clause="NULL"
  [[ -n "$cycle_id" ]] && cycle_clause="$cycle_id"

  local safe_prompt="${prompt//\'/\'\'}"

  _db "INSERT INTO specs (issue_id, cycle_id, project, original_prompt, status)
       VALUES (${issue_clause}, ${cycle_clause}, '${project}', '${safe_prompt}', 'Draft');"

  _db "SELECT id FROM specs WHERE project='${project}' ORDER BY id DESC LIMIT 1;"
}

update_spec() {
  # Args: $1=spec_id  $2=column  $3=value
  # SECURITY (spec #8): reject any attempt to set status=Approved via this path.
  # update_spec is a general-purpose column updater; Approved status must go
  # through set_spec_status which delegates to approve-spec.sh.
  local spec_id="$1" col="$2" val="$3"
  if [[ "$col" == "status" && "$val" == "Approved" ]]; then # guard — delegation only # delegation
    echo "ERROR: update_spec cannot write status=Approved directly. Use set_spec_status instead (spec #8)." >&2
    return 1
  fi
  local safe_val="${val//\'/\'\'}"
  _db "UPDATE specs SET ${col}='${safe_val}' WHERE id=${spec_id};"
}

set_spec_status() {
  # Args: $1=spec_id  $2=status
  # Valid statuses: Draft | Grounded | Approved | Fulfilled | Violated | Drifted | Superseded
  #
  # AUDIT (spec #8 revised): When status=Approved, delegates to approve-spec.sh
  # which records the attempt to spec_approvals (PID/PPID/TTY) and handles
  # supersession of prior Approved specs for the same issue. No cryptographic
  # gate — the token approach was security theater (the orchestrator that
  # approves specs is the same entity that reads the secret file).
  local spec_id="$1" status="$2"

  if [[ "$status" == "Approved" ]]; then
    # Non-empty DoD validation is enforced by approve-spec.sh and by the DB
    # CHECK constraint. Supersession of prior Approved spec is also there.
    bash "$HOME/.claude/hooks/approve-spec.sh" "$spec_id"
    return $?
  fi

  # Non-Approved statuses: written directly.
  if [[ "$status" == "Fulfilled" ]]; then
    _db "UPDATE specs SET status='Fulfilled', fulfilled_at=datetime('now') WHERE id=${spec_id};"
  else
    _db "UPDATE specs SET status='${status}' WHERE id=${spec_id};"
  fi
}

ensure_one_approved_per_issue_index() {
  # Idempotent migration: creates the partial unique index that enforces at most
  # one Approved spec per issue_id at the DB layer. Called at source time so any
  # environment that sources spec-ops.sh picks up the constraint automatically.
  # delegation: index predicate only — this is a structural constraint, not a write path for Approved
  local _idx_sql="CREATE UNIQUE INDEX IF NOT EXISTS idx_specs_one_approved_per_issue ON specs(issue_id) WHERE status='Approved';" # delegation: structural constraint
  sqlite3 "$DB_PATH" "$_idx_sql" 2>/dev/null || true
}

# Run migration on every source — idempotent, fast (no-op if index already exists).
ensure_one_approved_per_issue_index

# ---- Grounding -------------------------------------------------------------

add_grounding() {
  # Records one grounding row. Call once per referenced file/symbol/test.
  # Args: $1=spec_id $2=kind(file|symbol|test|command_output)
  #       $3=path $4=symbol $5=sha256 $6=snippet
  local spec_id="$1" kind="$2" path="$3" symbol="$4" sha="$5" snippet="$6"
  local safe_snippet="${snippet//\'/\'\'}"
  _db "INSERT INTO spec_groundings (spec_id, kind, path, symbol, sha256, snippet)
       VALUES (${spec_id}, '${kind}',
               $( [[ -n "$path" ]] && echo "'${path}'" || echo "NULL" ),
               $( [[ -n "$symbol" ]] && echo "'${symbol//\'/\'\'}'" || echo "NULL" ),
               $( [[ -n "$sha" ]] && echo "'${sha}'" || echo "NULL" ),
               '${safe_snippet}');"
}

ground_file() {
  # Helper: hash a file and record it as grounding. Returns 1 if file missing.
  # Args: $1=spec_id $2=path
  local spec_id="$1" path="$2"
  [[ ! -f "$path" ]] && return 1
  local sha
  sha=$(sha256sum "$path" | awk '{print $1}')
  add_grounding "$spec_id" file "$path" "" "$sha" ""
}

ground_symbol() {
  # Greps for a symbol in a file, records grounding with snippet.
  # Returns 1 if symbol not found (spec must not reference nonexistent symbols).
  # Args: $1=spec_id $2=path $3=symbol
  local spec_id="$1" path="$2" symbol="$3"
  local snippet
  snippet=$(grep -n "$symbol" "$path" 2>/dev/null | head -3)
  [[ -z "$snippet" ]] && return 1
  local sha=""
  [[ -f "$path" ]] && sha=$(sha256sum "$path" | awk '{print $1}')
  add_grounding "$spec_id" symbol "$path" "$symbol" "$sha" "$snippet"
}

# ---- Check recording -------------------------------------------------------

record_check() {
  # Appends one check result. Returns check row id.
  # Args: $1=spec_id $2=check_id $3=check_type $4=phase
  #       $5=result(pass|fail|precondition-unmet|skipped)
  #       $6=command $7=expected $8=actual $9=run_n
  local spec_id="$1" cid="$2" ctype="$3" phase="$4"
  local result="$5" cmd="$6" expected="$7" actual="$8"
  local run_n="${9:-1}"
  local safe_cmd="${cmd//\'/\'\'}"
  local safe_expected="${expected//\'/\'\'}"
  local safe_actual="${actual//\'/\'\'}"
  _db "INSERT INTO spec_checks
         (spec_id, check_id, check_type, phase, result, run_n, command, expected, actual)
       VALUES (${spec_id}, '${cid}', '${ctype}', '${phase}',
               '${result}', ${run_n}, '${safe_cmd}',
               '${safe_expected}', '${safe_actual}');"
}

get_check_results() {
  # Returns markdown table of check results for a spec, most recent run per check_id per phase.
  # Args: $1=spec_id  $2=phase(optional filter)
  local spec_id="$1" phase_filter="$2"
  local phase_clause=""
  [[ -n "$phase_filter" ]] && phase_clause="AND phase='${phase_filter}'"
  _db "SELECT check_id, check_type, phase, result, run_n, substr(actual, 1, 80)
       FROM spec_checks
       WHERE spec_id=${spec_id} ${phase_clause}
       ORDER BY run_at DESC;"
}

count_failing_checks() {
  # Args: $1=spec_id  $2=phase(optional)
  local spec_id="$1" phase_filter="$2"
  local phase_clause=""
  [[ -n "$phase_filter" ]] && phase_clause="AND phase='${phase_filter}'"
  _db "SELECT COUNT(*) FROM spec_checks
       WHERE spec_id=${spec_id} AND result='fail' ${phase_clause};"
}

# ---- DoD check execution ---------------------------------------------------
# Given one DoD check object (as a JSON line from dod_json), run it and return
# pass|fail|precondition-unmet plus the raw output. Callers wrap this with
# record_check() to persist evidence.
#
# The DoD check object shape:
#   { "id": "DOD-1",
#     "type": "existence|absence|behavior|equality|count|coverage|no-fabrication|user-observable",
#     "precondition": "shell command that must exit 0 for check to be valid (or empty)",
#     "check":   "shell command to run",
#     "expected": "expected stdout or numeric comparator like >=1 | ==0 | exit:0"
#   }

run_dod_check() {
  # Args: $1=json_obj (single-line JSON)
  # Echoes: "result|||actual_output"   (result is pass|fail|precondition-unmet|skipped)
  local json="$1"
  local check_type precondition check expected
  check_type=$(echo "$json" | jq -r '.type // "behavior"')
  precondition=$(echo "$json" | jq -r '.precondition // ""')
  check=$(echo "$json" | jq -r '.check // ""')
  expected=$(echo "$json" | jq -r '.expected // ""')

  # User-observable checks cannot be auto-run
  if [[ "$check_type" == "user-observable" ]]; then
    echo "skipped|||requires human verification"
    return 0
  fi

  # Precondition gate
  if [[ -n "$precondition" ]]; then
    if ! bash -c "$precondition" >/dev/null 2>&1; then
      echo "precondition-unmet|||precondition: ${precondition}"
      return 0
    fi
  fi

  # Execute check
  local actual exit_code
  actual=$(bash -c "$check" 2>&1)
  exit_code=$?

  # Compare against expected — support several comparators
  local result="fail"
  if [[ -z "$expected" ]]; then
    [[ $exit_code -eq 0 ]] && result="pass"
  elif [[ "$expected" == "exit:0" ]]; then
    [[ $exit_code -eq 0 ]] && result="pass"
  elif [[ "$expected" == "exit:nonzero" ]]; then
    [[ $exit_code -ne 0 ]] && result="pass"
  elif [[ "$expected" =~ ^(>=|<=|==|>|<)([0-9]+)$ ]]; then
    local op="${BASH_REMATCH[1]}"
    local num="${BASH_REMATCH[2]}"
    # Treat actual as an integer (first integer in output)
    local actual_num
    actual_num=$(echo "$actual" | grep -oE '[0-9]+' | head -1)
    [[ -z "$actual_num" ]] && actual_num=0
    case "$op" in
      ">=") [[ $actual_num -ge $num ]] && result="pass" ;;
      "<=") [[ $actual_num -le $num ]] && result="pass" ;;
      "==") [[ $actual_num -eq $num ]] && result="pass" ;;
      ">")  [[ $actual_num -gt $num ]] && result="pass" ;;
      "<")  [[ $actual_num -lt $num ]] && result="pass" ;;
    esac
  else
    # Literal string match
    [[ "$actual" == *"$expected"* ]] && result="pass"
  fi

  # Truncate actual for storage
  local trimmed
  trimmed=$(echo "$actual" | head -c 4000)
  echo "${result}|||${trimmed}"
}

run_all_dod_checks() {
  # Runs every check in a spec's DoD and records results. Returns 0 if all
  # pass, non-zero otherwise (number = count of failing/unmet).
  # Args: $1=spec_id  $2=phase  $3=run_n (default 1)
  local spec_id="$1" phase="$2" run_n="${3:-1}"
  local dod
  dod=$(get_spec_dod "$spec_id")
  # Vacuous-pass guard: if the DoD is absent or empty, return non-zero so callers
  # know no checks were executed. An Approved spec with no DoD is a structural error.
  if [[ -z "$dod" || "$dod" == "null" ]]; then
    echo "WARNING: spec ${spec_id} has no dod_json — zero checks executed." >&2
    return 1
  fi

  local failures=0
  while IFS= read -r json_line; do
    [[ -z "$json_line" ]] && continue
    local cid ctype cmd expected
    cid=$(echo "$json_line" | jq -r '.id // "unknown"')
    ctype=$(echo "$json_line" | jq -r '.type // "behavior"')
    cmd=$(echo "$json_line" | jq -r '.check // ""')
    expected=$(echo "$json_line" | jq -r '.expected // ""')

    local out result actual
    out=$(run_dod_check "$json_line")
    result="${out%%|||*}"
    actual="${out#*|||}"

    record_check "$spec_id" "$cid" "$ctype" "$phase" \
                 "$result" "$cmd" "$expected" "$actual" "$run_n"

    [[ "$result" != "pass" && "$result" != "skipped" ]] && ((failures++))
  done < <(echo "$dod" | jq -c '.[]')

  return $failures
}

# ---- Markdown doc helpers --------------------------------------------------

spec_doc_path_for() {
  # Args: $1=project $2=spec_id
  local project="$1" spec_id="$2"
  echo "${SPEC_DOCS_BASE}/${project}/specs/spec-${spec_id}.md"
}

ensure_spec_doc_dir() {
  local project="$1"
  mkdir -p "${SPEC_DOCS_BASE}/${project}/specs"
}
