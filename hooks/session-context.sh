#!/usr/bin/env bash
# ============================================================================
# session-context.sh — DB-backed session context for Claude Code
# ============================================================================
# Called by session-checkpoint.sh. Opens a cycle in the product DB and
# outputs structured context (active issues, recent decisions) that Claude
# sees as system context at the start of every session.
# ============================================================================

source "$HOME/.claude/hooks/db-ops.sh"
source "$HOME/.claude/hooks/spec-ops.sh" 2>/dev/null || true

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
PROJECT=$(get_project_name "$PROJECT_DIR")

# ---- Open or reuse cycle ---------------------------------------------------
CYCLE_ID=$(open_cycle "$PROJECT_DIR")

# ---- Query active work for this project ------------------------------------
ACTIVE_ISSUES=$(_db "
  SELECT '  #' || i.id || ' [' || i.status || '] ' || i.name
  FROM issues i
  LEFT JOIN epics e ON i.epic_id = e.id
  WHERE (e.project = '${PROJECT}' OR i.id IN (
    SELECT ci.issue_id FROM cycle_issues ci
    JOIN cycles c ON ci.cycle_id = c.id
    WHERE c.project = '${PROJECT}' AND c.status = 'Active'))
    AND i.status IN ('In Progress', 'Blocked')
  ORDER BY CASE i.status WHEN 'In Progress' THEN 0 WHEN 'Blocked' THEN 1 END,
           CASE i.priority WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END
  LIMIT 10;
")

BACKLOG_ISSUES=$(_db "
  SELECT '  #' || i.id || ' ' || i.name || ' (' || COALESCE(i.estimate,'?') || ')'
  FROM issues i
  LEFT JOIN epics e ON i.epic_id = e.id
  WHERE e.project = '${PROJECT}'
    AND i.status = 'Backlog'
  ORDER BY CASE i.priority WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END
  LIMIT 5;
")

# ---- Check for already-active session issues (resumed session) -------------
ALREADY_ACTIVE=$(get_active_issue_ids "$PROJECT_DIR")

# ---- Query recent decisions ------------------------------------------------
RECENT_DECISIONS=$(_db "
  SELECT '  ' || key_finding
  FROM research
  WHERE project = '${PROJECT}'
  ORDER BY date DESC
  LIMIT 3;
")

# ---- Query last completed cycle for this project ---------------------------
LAST_CYCLE=$(_db "
  SELECT name || ' — ' || COALESCE(retrospective, 'no retrospective')
  FROM cycles
  WHERE project = '${PROJECT}' AND status = 'Complete'
  ORDER BY end_date DESC
  LIMIT 1;
")

# ---- Query recent commits for this project ---------------------------------
RECENT_COMMITS=$(_db "
  SELECT '  ' || short_hash || ' ' || message
  FROM commits
  WHERE project = '${PROJECT}'
  ORDER BY created_at DESC
  LIMIT 5;
")

# ---- Output context block --------------------------------------------------
cat <<CONTEXT

SESSION CONTEXT — ${PROJECT} @ $(date -u '+%Y-%m-%d %H:%M UTC')
Cycle: #${CYCLE_ID}
CONTEXT

if [[ -n "$LAST_CYCLE" ]]; then
  echo "Last session: ${LAST_CYCLE}"
fi

echo ""
echo "ISSUES:"
if [[ -n "$ACTIVE_ISSUES" ]]; then
  echo "  In Progress / Blocked:"
  echo "$ACTIVE_ISSUES"
fi
if [[ -n "$BACKLOG_ISSUES" ]]; then
  echo "  Backlog (top 5):"
  echo "$BACKLOG_ISSUES"
fi
if [[ -z "$ACTIVE_ISSUES" && -z "$BACKLOG_ISSUES" ]]; then
  echo "  (none found for ${PROJECT})"
fi

if [[ -n "$RECENT_DECISIONS" ]]; then
  echo ""
  echo "RECENT DECISIONS:"
  echo "$RECENT_DECISIONS"
fi

if [[ -n "$RECENT_COMMITS" ]]; then
  echo ""
  echo "RECENT COMMITS:"
  echo "$RECENT_COMMITS"
fi

# ---- Active Spec lookup (Gate 0 status) ------------------------------------
ACTIVE_SPEC_ID=""
if declare -f get_active_spec_id >/dev/null 2>&1; then
  ACTIVE_SPEC_ID=$(get_active_spec_id "$PROJECT_DIR" 2>/dev/null || true)
fi

if [[ -n "$ACTIVE_SPEC_ID" ]]; then
  SPEC_STATUS=$(get_spec_status "$ACTIVE_SPEC_ID" 2>/dev/null)
  SPEC_DOC=$(get_spec_doc_path "$ACTIVE_SPEC_ID" 2>/dev/null)
  echo ""
  echo "ACTIVE SPEC: #${ACTIVE_SPEC_ID} (status: ${SPEC_STATUS})"
  [[ -n "$SPEC_DOC" ]] && echo "  doc: ${SPEC_DOC}"
  if [[ "$SPEC_STATUS" != "Approved" ]]; then
    echo "  ⚠ Spec not yet Approved — contract-gate will block Edit/Write."
    echo "  Resume product-owner agent to finalize and get user approval."
  else
    echo "  ✓ DoD is binding. Reviewer/auditor will execute checks mechanically."
  fi
else
  echo ""
  echo "ACTIVE SPEC: none"
  echo "  If the kickoff prompt is non-trivial work, invoke product-owner"
  echo "  BEFORE writing code. contract-gate.sh will block Edit/Write until a"
  echo "  spec is Approved (trivial edits bypass via trivial-classifier.sh)."
fi

echo ""
if [[ -n "$ALREADY_ACTIVE" ]]; then
  echo "ACTIVE SESSION ISSUES: #${ALREADY_ACTIVE// /, #} (resumed from prior session)"
  echo "COMMIT TRACKING: Active. All commits auto-linked to issue(s) above."
  echo "  Use 'fixes #N' in commit message to override the linked issue."
else
  echo "ISSUE SELECTION REQUIRED:"
  echo "  At the start of this session, confirm which issue you are working on."
  echo "  To select existing: call set_active_issue <id> via db-ops.sh"
  echo "  To start new work: call create_and_activate_issue '<name>' [epic_id] via db-ops.sh"
  echo "  If no issue applies, commits will still be recorded (linked to cycle only)."
  echo "COMMIT TRACKING: Active. Commits linked to cycle #${CYCLE_ID}."
fi
