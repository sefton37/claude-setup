#!/usr/bin/env bash
# ============================================================================
# db-ops.sh — Shared SQLite operations for Claude Code hooks
# ============================================================================
# Sourced by session-checkpoint.sh, push-commit.sh, and post-commit.sh.
# Provides functions to manage cycles, commits, and issue linking in the
# product management database.
#
# Usage: source ~/.claude/hooks/db-ops.sh
# ============================================================================

DB_PATH="$HOME/talking-rock/product/db/product.db"
STATE_DIR="$HOME/.claude/hooks/state"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# ---- Helpers ---------------------------------------------------------------

_db() {
  # PRAGMA foreign_keys=ON is injected into every SQLite invocation so that FK
  # violations raise errors rather than silently inserting orphaned rows.
  printf '.timeout 5000\nPRAGMA foreign_keys=ON;\n%s\n' "$1" | sqlite3 "$DB_PATH"
}

get_project_name() {
  # Derive project name from directory path
  # /home/kellogg/dev/RIVA -> RIVA
  # /home/kellogg/dev/Cairn -> Cairn
  local dir="${1:-$CLAUDE_PROJECT_DIR}"
  basename "$dir"
}

_state_file() {
  local project
  project=$(get_project_name "${1:-$CLAUDE_PROJECT_DIR}")
  echo "${STATE_DIR}/cycle-${project}.id"
}

# ---- Cycle operations ------------------------------------------------------

open_cycle() {
  # Opens a new cycle or reuses an existing active one for this project.
  # Writes cycle_id to per-project state file.
  # Args: $1 = project_dir (defaults to CLAUDE_PROJECT_DIR)
  local project_dir="${1:-$CLAUDE_PROJECT_DIR}"
  local project
  project=$(get_project_name "$project_dir")
  local state_file
  state_file=$(_state_file "$project_dir")

  # Check for existing active cycle for this project
  local existing
  existing=$(_db "SELECT id FROM cycles WHERE project='${project}' AND status='Active' LIMIT 1;")

  if [[ -n "$existing" ]]; then
    # Reuse existing active cycle (previous session crashed or still open)
    echo "$existing" > "$state_file"
    echo "$existing"
    return 0
  fi

  # Create new cycle
  local timestamp
  timestamp=$(date -u '+%Y-%m-%d %H:%M')
  local cycle_name="Session ${timestamp} — ${project}"

  _db "INSERT INTO cycles (name, status, project, project_dir, start_date, goal)
       VALUES ('${cycle_name}', 'Active', '${project}', '${project_dir}', datetime('now'), 'Pending');"

  local cycle_id
  cycle_id=$(_db "SELECT id FROM cycles WHERE project='${project}' AND status='Active' ORDER BY id DESC LIMIT 1;")

  echo "$cycle_id" > "$state_file"
  echo "$cycle_id"
}

close_cycle() {
  # Closes the active cycle for this project.
  # Args: $1 = project_dir (defaults to CLAUDE_PROJECT_DIR)
  local project_dir="${1:-$CLAUDE_PROJECT_DIR}"
  local state_file
  state_file=$(_state_file "$project_dir")

  if [[ ! -f "$state_file" ]]; then
    return 0
  fi

  local cycle_id
  cycle_id=$(cat "$state_file")

  if [[ -n "$cycle_id" ]]; then
    _db "UPDATE cycles SET status='Complete', end_date=datetime('now')
         WHERE id=${cycle_id} AND status='Active';"
  fi

  rm -f "$state_file"

  # Also clear active issues for this session
  local issues_file
  issues_file=$(_issues_state_file "$project_dir")
  rm -f "$issues_file"
}

get_current_cycle_id() {
  # Returns the current cycle_id for a project, or empty string.
  # Args: $1 = project_dir (defaults to CLAUDE_PROJECT_DIR)
  local project_dir="${1:-$CLAUDE_PROJECT_DIR}"
  local state_file
  state_file=$(_state_file "$project_dir")

  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  fi
}

# ---- Issue operations -------------------------------------------------------

_issues_state_file() {
  local project
  project=$(get_project_name "${1:-$CLAUDE_PROJECT_DIR}")
  echo "${STATE_DIR}/issues-${project}.ids"
}

set_active_issues() {
  # Writes issue IDs to the session state file and marks them In Progress.
  # Args: $@ = one or more issue IDs (integers)
  local project_dir="${CLAUDE_PROJECT_DIR:-.}"
  local state_file
  state_file=$(_issues_state_file "$project_dir")
  local cycle_id
  cycle_id=$(get_current_cycle_id "$project_dir")

  # Clear and rewrite the state file
  : > "$state_file"

  for id in "$@"; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    # Validate issue exists
    local exists
    exists=$(_db "SELECT id FROM issues WHERE id=${id};")
    [[ -z "$exists" ]] && continue

    echo "$id" >> "$state_file"

    # Mark In Progress
    _db "UPDATE issues SET status='In Progress'
         WHERE id=${id} AND status NOT IN ('Done');"

    # Link to current cycle
    if [[ -n "$cycle_id" ]]; then
      _db "INSERT OR IGNORE INTO cycle_issues (cycle_id, issue_id)
           VALUES (${cycle_id}, ${id});"
    fi
  done
}

get_active_issue_ids() {
  # Returns space-separated list of active issue IDs from state file.
  local project_dir="${1:-$CLAUDE_PROJECT_DIR}"
  local state_file
  state_file=$(_issues_state_file "$project_dir")
  if [[ -f "$state_file" ]]; then
    grep -v '^$' "$state_file" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
  fi
}

create_and_activate_issue() {
  # Creates a new issue and immediately sets it active for this session.
  # Args: $1 = name, $2 = epic_id (optional), $3 = type (optional, default Feature)
  local name="$1"
  local epic_id="${2:-}"
  local issue_type="${3:-Feature}"
  local safe_name="${name//\'/\'\'}"

  local epic_clause="NULL"
  [[ -n "$epic_id" ]] && epic_clause="$epic_id"

  _db "INSERT INTO issues (name, status, type, epic_id)
       VALUES ('${safe_name}', 'In Progress', '${issue_type}', ${epic_clause});"

  local new_id
  new_id=$(_db "SELECT id FROM issues ORDER BY id DESC LIMIT 1;")

  if [[ -n "$new_id" ]]; then
    set_active_issues "$new_id"
    echo "$new_id"
  fi
}

# ---- Commit operations -----------------------------------------------------

extract_issue_id() {
  # Extracts issue ID from commit message using conventional patterns.
  # Returns integer ID or empty string.
  # Args: $1 = commit message
  local message="$1"
  local issue_id=""

  # Match: fixes #N, closes #N, refs #N, issue #N
  if [[ "$message" =~ (fixes|closes|refs|issue)[[:space:]]+#([0-9]+) ]]; then
    local candidate="${BASH_REMATCH[2]}"
    # Validate that this issue exists in the DB
    local exists
    exists=$(_db "SELECT id FROM issues WHERE id=${candidate};")
    if [[ -n "$exists" ]]; then
      issue_id="$candidate"
    fi
  fi

  echo "$issue_id"
}

record_commit() {
  # Records a git commit to the commits table.
  # Args: $1 = project_dir (defaults to CLAUDE_PROJECT_DIR)
  #        Reads commit info from git in the current directory.
  local project_dir="${1:-$CLAUDE_PROJECT_DIR}"
  local project
  project=$(get_project_name "$project_dir")

  local hash short_hash message author timestamp branch
  hash=$(git rev-parse HEAD 2>/dev/null) || return 0
  short_hash=$(git rev-parse --short HEAD 2>/dev/null) || return 0
  message=$(git log -1 --format='%s' 2>/dev/null) || return 0
  author=$(git log -1 --format='%ae' 2>/dev/null) || return 0
  timestamp=$(git log -1 --format='%ai' 2>/dev/null) || return 0
  branch=$(git branch --show-current 2>/dev/null || echo "detached")

  local cycle_id
  cycle_id=$(get_current_cycle_id "$project_dir")

  local issue_id
  issue_id=$(extract_issue_id "$message")

  # Fallback: if no explicit issue ref, use the active session issue
  if [[ -z "$issue_id" ]]; then
    local active_ids
    active_ids=$(get_active_issue_ids "$project_dir")
    if [[ -n "$active_ids" ]]; then
      # Use the first active issue as the primary link
      issue_id=$(echo "$active_ids" | awk '{print $1}')
    fi
  fi

  # Escape single quotes in message
  local safe_message="${message//\'/\'\'}"

  local cycle_clause="NULL"
  [[ -n "$cycle_id" ]] && cycle_clause="$cycle_id"

  # Guard: abort DB insert if issue_id is still unresolved (no active issue,
  # no explicit ref in message). Belt-and-suspenders with the schema NOT NULL
  # constraint and the pre-commit hook's issue-linkage check.
  # The schema will also reject NULL inserts at the SQLite level (via NOT NULL).
  if [[ -z "$issue_id" ]]; then
    echo "WARNING: record_commit — no active issue and no 'fixes|closes|refs #N' in commit message. DB insert aborted." >&2
    return 1
  fi

  local issue_clause="NULL"
  [[ -n "$issue_id" ]] && issue_clause="$issue_id"

  # Get active spec_id for spec->commit traceability
  local spec_id=""
  if [[ -f "$HOME/.claude/hooks/spec-ops.sh" ]]; then
    spec_id=$(source "$HOME/.claude/hooks/spec-ops.sh" 2>/dev/null && get_active_spec_id "$project_dir" 2>/dev/null || true)
  fi
  local spec_clause="NULL"
  [[ -n "$spec_id" ]] && spec_clause="$spec_id"

  _db "INSERT OR IGNORE INTO commits (hash, short_hash, message, author, timestamp, project, branch, issue_id, cycle_id, spec_id)
       VALUES ('${hash}', '${short_hash}', '${safe_message}', '${author}', '${timestamp}', '${project}', '${branch}', ${issue_clause}, ${cycle_clause}, ${spec_clause});"

  # Link issue to cycle if both exist
  if [[ -n "$cycle_id" && -n "$issue_id" ]]; then
    _db "INSERT OR IGNORE INTO cycle_issues (cycle_id, issue_id)
         VALUES (${cycle_id}, ${issue_id});"
  fi

  # Also link all active session issues to this cycle
  if [[ -n "$cycle_id" ]]; then
    local active_ids
    active_ids=$(get_active_issue_ids "$project_dir")
    for aid in $active_ids; do
      _db "INSERT OR IGNORE INTO cycle_issues (cycle_id, issue_id)
           VALUES (${cycle_id}, ${aid});" 2>/dev/null || true
    done
  fi
}
