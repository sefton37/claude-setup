#!/usr/bin/env bash
# ============================================================================
# push-commit.sh — Stop Hook for Claude Code
# ============================================================================
# PURPOSE:  Enforces a documentation-first commit workflow. When Claude stops,
#           this hook checks if code changes have corresponding documentation
#           updates. If not, it bounces Claude back with specific guidance.
#           Once docs are aligned, it auto-commits and pushes.
#
# SEQUENCE:
#   1. Claude finishes work → Stop event fires
#   2. Hook checks for uncommitted changes (exit 0 if none)
#   3. Resolves active issue — rejects with exit 2 if none found
#   4. Hook categorizes changes: code vs docs vs config
#   5. If code changed without docs → EXIT 2 (Claude updates docs)
#   6. Claude updates docs → Stop fires again
#   7. This time changes are aligned → scoped stage → commit + push → EXIT 0
#
# STAGING STRATEGY (scoped — does not stage unrelated dirty files):
#   Path A: If the caller already has staged files, use only those (no expansion).
#   Path B: If nothing staged, derive scope from active spec's spec_groundings
#           (only paths under $PROJECT_DIR). Stage those files if dirty.
#   Path C: If nothing staged and no spec groundings available, emit a list of
#           all dirty/untracked files and ask the user to stage explicitly → exit 2.
#
# ISSUE LINKAGE:
#   - Resolves the active issue ID from the state file. Rejects if none found.
#   - Appends "fixes #N" when issue status is In Progress, "refs #N" otherwise.
#   - This ensures record_commit always finds an explicit issue ref in the message.
#
# EVENT:    Stop (matcher: "")
# EXIT 0:   No changes, or successfully committed and pushed
# EXIT 2:   Documentation needs updating, staging needs manual help, or no active issue
# EXIT 1:   Git error (non-blocking, shown to user)
#
# SKIP:     Create a .skip-doc-check file in project root to bypass
#           the documentation alignment check (commit still runs).
#           Or include [skip-docs] in any changed filename.
#
# INSTALL:  Copy to .claude/hooks/ and wire in settings.json
# ============================================================================

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
cd "$PROJECT_DIR"

# ---- Preflight: are we in a git repo? ----
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  # Not a git repo — nothing to do
  exit 0
fi

# ---- Preflight: resolve active issue (MUST exist before proceeding) ----
# Source db-ops.sh to get get_active_issue_ids and issue status query.
DB_OPS="$HOME/.claude/hooks/db-ops.sh"
DB_PATH="$HOME/talking-rock/product/db/product.db"

if [[ ! -f "$DB_OPS" ]]; then
  echo "WARNING: db-ops.sh not found — cannot resolve active issue. Commit aborted." >&2
  exit 2
fi

# shellcheck source=/home/kellogg/.claude/hooks/db-ops.sh
source "$DB_OPS"

active_issue_ids=$(get_active_issue_ids "$PROJECT_DIR" 2>/dev/null || true)
active_issue_id=$(echo "$active_issue_ids" | awk '{print $1}')

if [[ -z "$active_issue_id" ]]; then
  cat >&2 <<EOF
PUSH-COMMIT REJECTED — No active issue found.

Auto-commits must be linked to an active issue so record_commit can write
a non-NULL issue_id to the product DB. Without this, the commit is unlinked
and violates the issue-linkage contract.

To fix, set an active issue before stopping:
  source ~/.claude/hooks/db-ops.sh && set_active_issues <id>

Or create a new issue:
  source ~/.claude/hooks/db-ops.sh && create_and_activate_issue "description"
EOF
  exit 2
fi

# Build the issue reference trailer.
# Always use "fixes #N" — both "fixes" and "refs" satisfy extract_issue_id's
# regex, but "fixes" is the token checked by DOD-7 and is recognized by Forgejo
# for automatic issue closing on merge.
issue_trailer="fixes #${active_issue_id}"

# ---- Step 0: Check for uncommitted changes ----
# Includes staged, unstaged, and untracked files
has_staged=$(git diff --cached --name-only 2>/dev/null)
has_unstaged=$(git diff --name-only 2>/dev/null)
has_untracked=$(git ls-files --others --exclude-standard 2>/dev/null)

all_changes=$(printf '%s\n%s\n%s' "$has_staged" "$has_unstaged" "$has_untracked" \
  | sort -u | grep -v '^$' || true)

if [[ -z "$all_changes" ]]; then
  # Nothing to commit
  exit 0
fi

# ---- Step 1: Categorize changes ----

# Source code patterns (things that should have doc coverage)
code_pattern='\.(sh|bash|py|js|ts|jsx|tsx|rs|go|rb|java|c|cpp|h|hpp|cs|php|swift|kt|scala|ex|exs|lua|zig|nix|toml|yaml|yml)$'

# Documentation patterns
doc_pattern='\.(md|txt|rst|adoc|org)$|README|CHANGELOG|CONTRIBUTING|docs/|doc/'

# Config/infra patterns (usually don't need doc updates)
config_pattern='\.(json|lock|sum|mod)$|package\.json|Cargo\.toml|go\.mod|Makefile|Dockerfile|docker-compose|\.github/|\.gitignore|\.env'

code_changes=$(echo "$all_changes" | grep -iE "$code_pattern" || true)
doc_changes=$(echo "$all_changes" | grep -iE "$doc_pattern" || true)
config_changes=$(echo "$all_changes" | grep -iE "$config_pattern" || true)

# Count by category (grep -c . returns 0 with exit 1 on empty input;
# the || true prevents set -e from exiting, and the result is still the right number)
code_count=$(echo "$code_changes" | grep -c . 2>/dev/null) || code_count=0
doc_count=$(echo "$doc_changes" | grep -c . 2>/dev/null) || doc_count=0
total_count=$(echo "$all_changes" | grep -c . 2>/dev/null) || total_count=0

# ---- Step 2: Documentation alignment check ----

skip_doc_check=false

# Skip if .skip-doc-check exists
if [[ -f "$PROJECT_DIR/.skip-doc-check" ]]; then
  skip_doc_check=true
fi

# Skip if only config/infra files changed (no source code)
if [[ "$code_count" -eq 0 ]]; then
  skip_doc_check=true
fi

# Skip docs check when the caller has pre-staged specific files.
# Pre-staging is a deliberate act — the caller has chosen exactly what to commit.
# The docs-sync gate is designed for the auto-stage (no pre-staging) path; requiring
# docs for every pre-staged commit would block git-ops agents that stage targeted
# infrastructure fixes (e.g. a hook script update) without a companion doc edit.
if [[ -n "$has_staged" ]]; then
  skip_doc_check=true
fi

# Skip if [skip-docs] marker found
if echo "$all_changes" | grep -q 'skip-docs'; then
  skip_doc_check=true
fi

if [[ "$skip_doc_check" == "false" && "$code_count" -gt 0 && "$doc_count" -eq 0 ]]; then
  # ---- CODE CHANGED, NO DOCS UPDATED — BOUNCE BACK ----

  # Find relevant doc files that might need updating
  relevant_docs=""
  checked_dirs=""

  while IFS= read -r code_file; do
    dir=$(dirname "$code_file")
    # Avoid checking the same directory twice
    if echo "$checked_dirs" | grep -qF "$dir"; then
      continue
    fi
    checked_dirs+="$dir"$'\n'

    # Look for doc files in the same directory and parent
    for candidate in \
      "$dir/README.md" \
      "$dir/../README.md" \
      "README.md" \
      "CHANGELOG.md" \
      "docs/"; do
      if [[ -e "$PROJECT_DIR/$candidate" ]]; then
        relevant_docs+="  - $candidate"$'\n'
      fi
    done
  done <<< "$code_changes"

  relevant_docs=$(echo "$relevant_docs" | sort -u | grep -v '^$' || true)

  cat >&2 <<EOF
DOCUMENTATION REVIEW — Required before commit.

${code_count} source file(s) changed:
$(echo "$code_changes" | sed 's/^/  - /')

No documentation files were updated alongside these changes.

BEFORE I CAN COMMIT, please:
  1. Review the changes you just made
  2. Update relevant documentation to reflect the current state
  3. Focus on: what changed, why, and any new usage patterns

$(if [[ -n "$relevant_docs" ]]; then
  echo "Documentation files that likely need attention:"
  echo "$relevant_docs"
else
  echo "No existing docs found nearby. Consider adding a README.md"
  echo "or updating the project-level documentation."
fi)

$(if [[ -n "$config_changes" ]]; then
  echo ""
  echo "Note: Config changes detected too (these don't require doc updates):"
  echo "$config_changes" | sed 's/^/  - /'
fi)

Once documentation is updated, I will automatically commit and push all changes.

To skip this check for trivial changes, create a .skip-doc-check file in the project root.
EOF
  exit 2
fi

# ---- Step 3: Scoped staging ----
# Path A: caller already staged files — respect that staging area, do not expand it.
# Path B: nothing staged — derive scope from active spec's spec_groundings.
# Path C: nothing staged and no groundings — list dirty files and reject.

already_staged=$(git diff --cached --name-only 2>/dev/null || true)

if [[ -n "$already_staged" ]]; then
  # Path A: caller pre-staged files — use only those. No expansion.
  # Warn if there are dirty/untracked files outside the staged set so the caller
  # knows they were intentionally excluded (DOD-9 requirement).
  unstaged_dirty=$(git diff --name-only 2>/dev/null || true)
  untracked_dirty=$(git ls-files --others --exclude-standard 2>/dev/null || true)
  outside_scope=$(printf '%s\n%s' "$unstaged_dirty" "$untracked_dirty" | sort -u | grep -v '^$' || true)
  if [[ -n "$outside_scope" ]]; then
    echo "NOTE: The following dirty/untracked files are outside the staged set and will NOT be committed:" >&2
    echo "$outside_scope" | sed 's/^/  - /' >&2
    echo "They remain unstaged. Stage them manually if you want to include them." >&2
  fi
else
  # Paths B / C: nothing pre-staged. Attempt spec-groundings scope.
  SPEC_OPS="$HOME/.claude/hooks/spec-ops.sh"
  scoped_files=""

  if [[ -f "$SPEC_OPS" ]]; then
    source "$SPEC_OPS" 2>/dev/null || true
    active_spec_id=$(get_active_spec_id "$PROJECT_DIR" 2>/dev/null || true)

    if [[ -n "$active_spec_id" ]]; then
      # Query spec_groundings for file-kind paths under PROJECT_DIR
      project_dir_abs=$(realpath "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")
      grounded_paths=$(sqlite3 "$DB_PATH" \
        "SELECT path FROM spec_groundings WHERE spec_id=${active_spec_id} AND kind='file' AND path IS NOT NULL;" \
        2>/dev/null || true)

      while IFS= read -r gpath; do
        [[ -z "$gpath" ]] && continue
        # Resolve to absolute path and ensure it's under PROJECT_DIR
        abs_gpath=$(realpath "$gpath" 2>/dev/null || echo "$gpath")
        if [[ "$abs_gpath" == "$project_dir_abs"/* || "$abs_gpath" == "$project_dir_abs" ]]; then
          rel_path="${abs_gpath#"$project_dir_abs/"}"
          # Only stage if the file is actually dirty or untracked
          if git diff --name-only -- "$rel_path" 2>/dev/null | grep -q . || \
             git ls-files --others --exclude-standard -- "$rel_path" 2>/dev/null | grep -q .; then
            scoped_files+="$rel_path"$'\n'
          fi
        fi
      done <<< "$grounded_paths"
    fi
  fi

  if [[ -n "$scoped_files" ]]; then
    # Path B: stage only grounded files
    while IFS= read -r sf; do
      [[ -z "$sf" ]] && continue
      git add -- "$sf"
    done <<< "$scoped_files"

    # Check if any dirty files were left outside scope — warn but do not abort
    remaining_dirty=$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
    remaining_dirty=$(echo "$remaining_dirty" | grep -v '^$' || true)
    if [[ -n "$remaining_dirty" ]]; then
      echo "NOTE: The following dirty files are outside the spec scope and were NOT staged:" >&2
      echo "$remaining_dirty" | sed 's/^/  - /' >&2
      echo "They remain unstaged. Stage them manually if needed." >&2
    fi
  else
    # Path C: no pre-staged files, no grounded paths match — list and reject
    dirty_files=$(git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
    dirty_files=$(echo "$dirty_files" | sort -u | grep -v '^$' || true)

    cat >&2 <<EOF
PUSH-COMMIT REJECTED — Cannot determine safe staging scope.

No files were pre-staged, and no spec_groundings file-paths are available
under $PROJECT_DIR to restrict staging scope.

Staging everything indiscriminately is refused to prevent bundling unrelated
dirty state from other contexts.

Dirty / untracked files that need to be staged manually:
$(echo "$dirty_files" | sed 's/^/  - /')

To proceed:
  git add <specific files>   # stage only the files you want in this commit
  (then let the Stop hook fire again)

Or: set an active spec with file groundings before committing, and the hook
will derive scope automatically.
EOF
    exit 2
  fi

  # Verify something was staged after Path B
  already_staged=$(git diff --cached --name-only 2>/dev/null || true)
  if [[ -z "$already_staged" ]]; then
    cat >&2 <<EOF
PUSH-COMMIT REJECTED — Scoped staging produced an empty index.

The active spec's groundings matched no dirty files under $PROJECT_DIR.

Dirty / untracked files present:
$(printf '%s\n%s' "$(git diff --name-only 2>/dev/null)" "$(git ls-files --others --exclude-standard 2>/dev/null)" | sort -u | grep -v '^$' | sed 's/^/  - /')

Stage the relevant files manually, then let the Stop hook run again.
EOF
    exit 2
  fi
fi

# ---- Step 3a: Scan staged content for sensitive patterns ----
PATTERNS_FILE="$HOME/.claude/hooks/sensitive-patterns.conf"

sensitive_patterns=()
if [[ -f "$PATTERNS_FILE" ]]; then
  mapfile -t sensitive_patterns < <(grep -vE '^\s*(#|$)' "$PATTERNS_FILE" 2>/dev/null || true)
fi
if [[ -n "${CONTENT_GUARD_PATTERNS:-}" ]]; then
  IFS='|' read -ra _env_pats <<< "$CONTENT_GUARD_PATTERNS"
  sensitive_patterns+=("${_env_pats[@]}")
fi

if (( ${#sensitive_patterns[@]} > 0 )); then
    staged_diff=$(git diff --cached --unified=0 -- ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' ':!Cargo.lock' ':!go.sum' 2>/dev/null || true)
    # Only scan added lines (lines starting with +, excluding +++ header)
    added_lines=$(echo "$staged_diff" | grep -E '^\+[^+]' | sed 's/^\+//' || true)

    if [[ -n "$added_lines" ]]; then
      leaked_patterns=()
      for pattern in "${sensitive_patterns[@]}"; do
        trimmed=$(echo "$pattern" | sed 's/^\s*//;s/\s*$//')
        [[ -n "$trimmed" ]] || continue
        if echo "$added_lines" | grep -qiP "$trimmed" 2>/dev/null; then
          leaked_patterns+=("$trimmed")
        fi
      done

      if (( ${#leaked_patterns[@]} > 0 )); then
        # Unstage everything — do NOT commit
        git reset HEAD --quiet 2>/dev/null || true

        cat >&2 <<GUARD_EOF
CONTENT GUARD — Commit blocked.

Sensitive pattern(s) detected in staged changes:
$(printf '  - %s\n' "${leaked_patterns[@]}")

The commit was aborted and changes have been unstaged.
These patterns are defined in ~/.claude/hooks/sensitive-patterns.conf

-> Remove the sensitive values from the files before committing.
-> Use environment variables or .gitignored config files for infrastructure details.
-> If these are false positives, add allowlist patterns to sensitive-patterns.conf.

NEVER commit infrastructure details (IPs, usernames, hostnames, keys)
directly into source files.
GUARD_EOF
        exit 2
      fi
    fi
fi

# Build a meaningful commit message from the diff
# Determine conventional commit type
commit_type="chore"

if git diff --cached --name-only | grep -qiE '(feat|feature)' || \
   git diff --cached --diff-filter=A --name-only | grep -c . | grep -qvE '^0$'; then
  # New files added → likely a feature
  commit_type="feat"
elif git diff --cached --name-only | grep -qiE '(fix|bug|patch|hotfix)'; then
  commit_type="fix"
elif [[ "$doc_count" -gt 0 && "$code_count" -eq 0 ]]; then
  commit_type="docs"
elif git diff --cached --name-only | grep -qiE '(test|spec|_test\.|\.test\.)'; then
  commit_type="test"
elif git diff --cached --name-only | grep -qiE '(refactor)'; then
  commit_type="refactor"
fi

# Determine scope from the most common directory
primary_dir=$(git diff --cached --name-only | head -5 \
  | xargs -I{} dirname {} 2>/dev/null \
  | sort | uniq -c | sort -rn | head -1 \
  | awk '{print $2}' || echo "root")

# Clean up scope
scope=$(echo "$primary_dir" | sed 's|^\./||' | sed 's|/|-|g' | head -c 20)
if [[ "$scope" == "." || -z "$scope" ]]; then
  scope="root"
fi

# Re-count staged files for the commit subject (may differ from all_changes after scoped staging)
staged_count=$(git diff --cached --name-only | grep -c . || echo 0)

# Build the commit message with issue reference appended to body
commit_subject="${commit_type}(${scope}): update ${staged_count} file(s)"

commit_body="Changes:
$(git diff --cached --name-only | sed 's/^/- /')

---
Auto-committed by push-commit hook

${issue_trailer}"

# Commit
if ! git commit -m "$commit_subject" -m "$commit_body" 2>&1; then
  echo "Git commit failed" >&2
  exit 1
fi
# Echo the issue trailer so callers and tests can confirm linkage
echo "Linked: ${issue_trailer}"

# ---- Record commit + close cycle in product DB ----
# db-ops.sh is already sourced above; record_commit will find the issue ref
# in the commit message (issue_trailer = "fixes #N" or "refs #N").
record_commit "$PROJECT_DIR" 2>/dev/null || true
close_cycle "$PROJECT_DIR" 2>/dev/null || true

# Push to current branch
current_branch=$(git branch --show-current 2>/dev/null)
if [[ -z "$current_branch" ]]; then
  echo "Detached HEAD — committed but cannot push without a branch" >&2
  exit 1
fi

# Check if remote exists
if ! git remote | grep -q 'origin'; then
  echo "No 'origin' remote configured — committed locally but not pushed" >&2
  echo "Committed ${staged_count} files to ${current_branch} (local only)" >&2
  exit 0
fi

if ! git push origin "$current_branch" 2>&1; then
  echo "Push failed — changes are committed locally" >&2
  exit 1
fi

echo "Committed and pushed ${staged_count} files to origin/${current_branch}"
exit 0
