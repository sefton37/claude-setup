#!/usr/bin/env bash
# ============================================================================
# content-guard.sh — PreToolUse Hook (Write|Edit|MultiEdit)
# ============================================================================
# Scans the CONTENT being written/edited for sensitive patterns before the
# write happens. This is the OUTPUT-side complement to secrets-guard (which
# protects INPUT/reads). Together they form a complete barrier:
#
#   secrets-guard:  prevents reading secrets INTO Claude's context
#   content-guard:  prevents writing secrets OUT to tracked files
#
# Patterns are loaded from ~/.claude/hooks/sensitive-patterns.conf
# (one PCRE regex per line, # comments, blank lines ignored).
#
# Two-strike approval for legitimate writes containing matched patterns.
#
# Post-incident hardening: VPS IP and username leaked into git history
# because no hook inspected the content of Write/Edit operations.
# ============================================================================
set -euo pipefail

APPROVAL_FILE="/tmp/claude-approvals-content"
APPROVAL_TTL=600
PATTERNS_FILE="$HOME/.claude/hooks/sensitive-patterns.conf"

json_input=$(cat)
tool_name=$(echo "$json_input" | jq -r '.tool_name // empty' 2>/dev/null)

# ============================================================================
# Extract content to scan based on tool type
# ============================================================================
content_to_scan=""
file_path=""

case "$tool_name" in
  Write)
    content_to_scan=$(echo "$json_input" | jq -r '.tool_input.content // empty' 2>/dev/null)
    file_path=$(echo "$json_input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    ;;
  Edit)
    content_to_scan=$(echo "$json_input" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
    file_path=$(echo "$json_input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    ;;
  MultiEdit)
    # Collect all new_string values from edits array
    content_to_scan=$(echo "$json_input" | jq -r '.tool_input.edits[]?.new_string // empty' 2>/dev/null)
    file_path=$(echo "$json_input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    ;;
  *)
    exit 0
    ;;
esac

# Nothing to scan
[[ -n "$content_to_scan" ]] || exit 0

# ============================================================================
# Skip scanning for non-tracked files (temp files, Claude's own config)
# ============================================================================
if [[ -n "$file_path" ]]; then
  # Allow writes to temp files, Claude config, and the patterns file itself
  case "$file_path" in
    /tmp/*|/dev/null)
      exit 0
      ;;
    "$HOME/.claude/hooks/sensitive-patterns.conf")
      # Don't scan writes to the patterns file itself (circular)
      exit 0
      ;;
  esac
fi

# ============================================================================
# Load patterns
# ============================================================================
patterns=()

# Load from config file (generic pattern shapes)
if [[ -f "$PATTERNS_FILE" ]]; then
  mapfile -t patterns < <(grep -vE '^\s*(#|$)' "$PATTERNS_FILE" 2>/dev/null || true)
fi

# Load from environment variable (infrastructure-specific values)
# Set CONTENT_GUARD_PATTERNS in .bashrc as pipe-delimited regexes:
#   export CONTENT_GUARD_PATTERNS='your\.ip\.here|\byour_username\b'
if [[ -n "${CONTENT_GUARD_PATTERNS:-}" ]]; then
  IFS='|' read -ra env_patterns <<< "$CONTENT_GUARD_PATTERNS"
  patterns+=("${env_patterns[@]}")
fi

# No active patterns
(( ${#patterns[@]} > 0 )) || exit 0

# ============================================================================
# Scan content against patterns
# ============================================================================
matched_patterns=()

for pattern in "${patterns[@]}"; do
  # Skip empty patterns after trimming
  trimmed=$(echo "$pattern" | sed 's/^\s*//;s/\s*$//')
  [[ -n "$trimmed" ]] || continue

  if echo "$content_to_scan" | grep -qiP "$trimmed" 2>/dev/null; then
    matched_patterns+=("$trimmed")
  fi
done

# No matches — content is clean
(( ${#matched_patterns[@]} > 0 )) || exit 0

# ============================================================================
# Two-strike approval
# ============================================================================
# Hash: tool + file_path + first matched pattern (same write = same approval)
hash_input="${tool_name}:${file_path}:${matched_patterns[0]}"
cmd_hash=$(echo -n "$hash_input" | sha256sum | cut -d' ' -f1)

touch "$APPROVAL_FILE"
now=$(date +%s)

# Purge stale approvals
if [[ -s "$APPROVAL_FILE" ]]; then
  tmp=$(mktemp)
  while IFS='|' read -r hash ts || [[ -n "$hash" ]]; do
    [[ -n "$hash" && -n "$ts" ]] && (( now - ts < APPROVAL_TTL )) && echo "${hash}|${ts}" >> "$tmp"
  done < "$APPROVAL_FILE"
  mv "$tmp" "$APPROVAL_FILE"
fi

# Strike 2: approved — consume and pass
if grep -q "^${cmd_hash}|" "$APPROVAL_FILE" 2>/dev/null; then
  sed -i "/^${cmd_hash}|/d" "$APPROVAL_FILE"
  exit 0
fi

# Strike 1: record and block
echo "${cmd_hash}|${now}" >> "$APPROVAL_FILE"

# Build a preview of matched content (first 120 chars of first match)
preview=""
for pattern in "${matched_patterns[@]}"; do
  match_text=$(echo "$content_to_scan" | grep -oiP "$pattern" 2>/dev/null | head -1)
  if [[ -n "$match_text" ]]; then
    preview="${match_text:0:120}"
    break
  fi
done

cat >&2 <<EOF
🛡️ CONTENT GUARD — Blocked.

Tool: ${tool_name}
File: ${file_path}

Sensitive pattern(s) detected in content being written:
$(printf '  ◦ %s\n' "${matched_patterns[@]}")

Preview of matched content: ${preview}

This content matches patterns in ~/.claude/hooks/sensitive-patterns.conf
which are configured to prevent infrastructure secrets from entering files.

→ If this is a false positive (e.g., documentation about patterns, test data),
  explain to the user and retry after confirmation.
→ If this IS sensitive data, use environment variables or .env files instead.
→ Consider whether this value belongs in a .gitignored config file.
→ Approval expires in $(( APPROVAL_TTL / 60 )) minutes.

⚠ NEVER commit infrastructure details (IPs, usernames, hostnames, keys)
  directly into source files. Use environment variables.
EOF
exit 2
