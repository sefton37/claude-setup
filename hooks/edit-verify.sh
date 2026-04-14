#!/usr/bin/env bash
# edit-verify.sh — PostToolUse hook for Edit|Write.
#
# After an Edit or Write tool call, confirm the claimed change actually landed:
#   1. The target file exists.
#   2. For Edit: the new_string appears at least once in the file.
#   3. For Write: the file's mtime was updated within the last 30 seconds.
#
# On mismatch, emit a prominent warning into the transcript. Does not block —
# its job is to surface lies by the tool layer or the model, not to enforce.
#
# Invoked via settings.json PostToolUse matcher "Edit|Write".
# Input: JSON on stdin describing the tool call (shape varies per tool).
# Exit: 0 always. Output on stdout is injected into the transcript.

set -u

LOG_DIR="$HOME/.claude/hooks/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/edit-verify.log"

# Read JSON payload from stdin (non-blocking; timeout 2s)
PAYLOAD=$(timeout 2 cat 2>/dev/null || echo "{}")

# Best-effort extraction of tool_name and file_path. Two possible schemas in
# current Claude Code: {tool_name, tool_input:{file_path,...}} or flattened.
TOOL_NAME=$(printf '%s' "$PAYLOAD" | grep -oP '"tool_name"\s*:\s*"\K[^"]+' | head -1)
FILE_PATH=$(printf '%s' "$PAYLOAD" | grep -oP '"file_path"\s*:\s*"\K[^"]+' | head -1)
NEW_STRING=$(printf '%s' "$PAYLOAD" | grep -oP '"new_string"\s*:\s*"\K[^"]+' | head -1)

# Silently exit if we can't find what we need — other hooks may need stdin.
if [[ -z "${FILE_PATH:-}" ]]; then
  exit 0
fi

# 1. File must exist.
if [[ ! -f "$FILE_PATH" ]]; then
  printf '\n🚨 EDIT-VERIFY — File does not exist after %s: %s\n' "${TOOL_NAME:-tool}" "$FILE_PATH"
  printf '[%s] MISSING_FILE %s %s\n' "$(date -Iseconds)" "$TOOL_NAME" "$FILE_PATH" >> "$LOG_FILE"
  exit 0
fi

# 2. Recent mtime check (soft — tools that write atomically can reset mtime).
MTIME_AGE=$(( $(date +%s) - $(stat -c %Y "$FILE_PATH" 2>/dev/null || echo 0) ))
if [[ $MTIME_AGE -gt 60 ]]; then
  printf '\n⚠️  EDIT-VERIFY — File mtime is %ds old after %s: %s\n' \
    "$MTIME_AGE" "${TOOL_NAME:-tool}" "$FILE_PATH"
  printf '    This does not prove the tool call failed, but the file was not just written.\n'
  printf '[%s] STALE_MTIME %s %ss %s\n' "$(date -Iseconds)" "$TOOL_NAME" "$MTIME_AGE" "$FILE_PATH" >> "$LOG_FILE"
fi

# 3. For Edit, confirm the new_string is present.
if [[ "${TOOL_NAME:-}" == "Edit" && -n "${NEW_STRING:-}" ]]; then
  # Unescape common JSON escapes before searching.
  UNESCAPED=$(printf '%s' "$NEW_STRING" | sed -e 's/\\n/\n/g' -e 's/\\t/\t/g' -e 's/\\"/"/g' -e 's/\\\\/\\/g')
  # Take the first line (up to 80 chars) as the search needle; full multiline
  # match is hard in grep and we only need evidence, not proof.
  NEEDLE=$(printf '%s' "$UNESCAPED" | head -1 | cut -c1-80)
  if [[ -n "$NEEDLE" ]] && ! grep -qF -- "$NEEDLE" "$FILE_PATH"; then
    printf '\n🚨 EDIT-VERIFY — new_string not found in target file after Edit: %s\n' "$FILE_PATH"
    printf '    First 80 chars searched: %s\n' "$NEEDLE"
    printf '    The edit may not have persisted. Run: git diff %s\n' "$FILE_PATH"
    printf '[%s] NEW_STRING_MISSING %s %s\n' "$(date -Iseconds)" "$TOOL_NAME" "$FILE_PATH" >> "$LOG_FILE"
  fi
fi

exit 0
