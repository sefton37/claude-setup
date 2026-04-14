# Claude Code Hooks — Dangerous Mode Safety System

## What This Is

A defense-in-depth hook system that makes Claude Code's dangerous mode
(`--dangerously-skip-permissions`) safe enough for daily use. Eight hooks
across five event types create overlapping safety layers so no single
bypass can cause irreversible damage.

Built from security research across 50+ sources including Anthropic docs,
CVE disclosures, Lasso Security, Knostic AI, Embrace The Red, Backslash
Security, and community incident reports.

## The Threat Model

Running Claude Code with reduced approvals exposes you to five categories
of risk. Each hook addresses one or more:

| Threat | Hook(s) | Severity |
|---|---|---|
| File/folder deletion | deletion-guard | 🔴 Critical |
| Silent overwrite via mv/cp | overwrite-guard | 🔴 Critical |
| Secret exposure (.env, SSH keys) | secrets-guard + permission-handler | 🔴 Critical |
| Data exfiltration (DNS, sockets) | network-guard + permission-handler | 🔴 Critical |
| Prompt injection via file content | injection-scanner | 🟡 Important |
| No rollback point | session-checkpoint | 🟡 Important |
| Documentation drift | push-commit | 🟢 Quality |
| Catastrophic system commands | permission-handler | 🔴 Critical |

## Architecture

```
Claude Code (dangerous mode)
    │
    ├── SessionStart ──→ session-checkpoint.sh
    │                     • Tags HEAD as claude-checkpoint-{timestamp}
    │                     • Injects safety rules into Claude's context
    │                     • Warns if project is not a git repo
    │
    ├── PreToolUse (Bash) ──→ deletion-guard.sh
    │   │                      • rm/rmdir/shred/unlink/find -delete/git clean
    │   │                      • Two-strike: block → explain → retry passes
    │   │
    │   ├────────────────→ secrets-guard.sh
    │   │                   • .env, .ssh, .aws, .pem, .key, credentials
    │   │                   • Bash reads AND Read tool calls
    │   │                   • printenv/env dumps, secret var echo
    │   │                   • Two-strike for legitimate access
    │   │
    │   ├────────────────→ overwrite-guard.sh
    │   │                   • mv/cp to existing destination files
    │   │                   • Only fires when destination EXISTS
    │   │                   • Two-strike with backup suggestion
    │   │
    │   └────────────────→ network-guard.sh
    │                       • HARD BLOCK: ping, nc, socat, telnet
    │                       • HARD BLOCK: dig/nslookup with $variables
    │                       • HARD BLOCK: curl file uploads, secret URLs
    │                       • Two-strike: ssh, scp, rsync
    │
    ├── PreToolUse (Read) ──→ secrets-guard.sh
    │                          • Same path checks as Bash handler
    │
    ├── PostToolUse (Read|WebFetch|Bash) ──→ injection-scanner.sh
    │                                         • 5 detection categories
    │                                         • Warn-not-block philosophy
    │                                         • Alert injected into transcript
    │
    ├── PermissionRequest ──→ permission-handler.sh
    │                          • 🔴 Catastrophic blocklist (always deny)
    │                          • 🟢 Safe allowlist (always approve)
    │                          • 🟡 Passthrough (defer to mode)
    │                          • Full audit logging
    │
    └── Stop ──→ push-commit.sh
                  • Code changed without docs? → bounce back
                  • Docs aligned? → auto-commit + push
                  • Conventional commit format
```

## Hook Details

### 1. session-checkpoint.sh — SessionStart

Creates a git tag before Claude touches anything. Your nuclear rollback option.

**Fires:** Once at session start
**Creates:** `claude-checkpoint-{YYYYmmdd-HHMMSS}` tag on HEAD
**Cleanup:** Keeps last 10 tags, prunes older ones
**Context injection:** Safety rules appear in Claude's system prompt
**Rollback:** `git reset --hard claude-checkpoint-{timestamp}`

### 2. deletion-guard.sh — PreToolUse (Bash)

Intercepts file deletion before it happens.

**Catches:** `rm`, `rmdir`, `unlink`, `shred`, `find -delete`, `find -exec rm`, `git clean -fd`, `truncate`
**Mechanism:** SHA-256 hash two-strike with 10-minute TTL
**Flow:** Block → Claude explains to user → User confirms → Claude retries exact command → Passes
**Storage:** `/tmp/claude-approvals-deletion`

### 3. secrets-guard.sh — PreToolUse (Bash + Read)

Protects sensitive files and environment variables from exposure.

**Protected paths:** `.env*`, `.ssh/*`, `.aws/*`, `.gnupg/*`, `.netrc`, `.npmrc`, `.pypirc`, `*.pem`, `*.key`, `*_rsa`, `*_ed25519`, `secrets.json`, `credentials.json`, `service.account.json`
**Catches Bash:** `cat .env`, `grep .ssh/`, `strings *.key`, `source .env`, `base64 .aws/credentials`, `printenv` (full dump), `echo $API_KEY`, `/proc/*/environ`
**Catches Read:** Direct Read tool calls to any sensitive path
**Research basis:** CVE-2025-55284, Knostic AI, Claude Code auto-loading .env

### 4. overwrite-guard.sh — PreToolUse (Bash)

Catches silent overwrites — functionally equivalent to deletion.

**Catches:** `mv` and `cp` when destination file already exists
**Skips:** Commands using `--no-clobber` / `-n` flags (already safe)
**Checks:** Resolves paths, handles both file→file and file→directory cases
**Suggestion:** Recommends `cp file file.bak` or `-n` flag

### 5. network-guard.sh — PreToolUse (Bash)

Blocks non-HTTP exfiltration channels.

**Hard blocked (no two-strike):**
- `ping` — DNS subdomain exfiltration (CVE-2025-55284)
- `nc`/`ncat`/`netcat` — raw socket connections
- `socat` — advanced socket relay
- `telnet` — unencrypted connections
- `dig`/`nslookup`/`host` with `$variable` expansion
- `curl`/`wget` with `--upload-file`, `--form`, or secret vars in URL

**Two-strike (legitimate use):**
- `ssh` (not `ssh-keygen`/`ssh-add`/`ssh-agent`)
- `scp`
- `rsync` to remote hosts (containing `:`)

### 6. injection-scanner.sh — PostToolUse (Read|WebFetch|Bash)

Scans tool output for prompt injection attempts.

**Detection categories:**
1. **Instruction Override** — "ignore previous instructions", "new system prompt"
2. **Jailbreak** — "you are DAN", "pretend to be unrestricted"
3. **Authority Spoofing** — fake `[SYSTEM]`, `[ADMIN]`, `[ANTHROPIC]` tags
4. **Instruction Smuggling** — hidden directives in HTML comments, code comments
5. **Exfiltration Directives** — "send the data to", "curl https://"

**Philosophy:** Warn, don't block. The tool already executed — scanner injects
a warning into Claude's transcript so it treats the content with suspicion.
Scans first 50KB for performance.

### 7. permission-handler.sh — PermissionRequest

Three-tier programmatic permission management.

**Tier 1 (🔴 Always Deny):** `rm -rf /`, `dd of=/dev/sd*`, `mkfs`, `chmod 777 /`, password file modifications, `curl|bash`, ping/nc/socat, iptables flush, critical service stop, .env direct reads
**Tier 2 (🟢 Always Approve):** Read-only operations (cat, grep, ls, find -print), git read commands, package queries, dev tools (node, python, cargo, npm test), directory ops, docker read ops, Claude's own Read/Write/Edit tools
**Tier 3 (🟡 Passthrough):** Everything else defers to Claude Code's built-in behavior

**Audit log:** Every decision written to `.claude/hooks/logs/permissions.log`
**Dual mode:** Circuit breaker in dangerous mode, auto-approver in normal mode

### 8. push-commit.sh — Stop

Documentation-first commit workflow.

**Flow:**
1. Claude finishes work → Stop fires
2. No uncommitted changes → exit 0 (nothing to do)
3. Code changed without docs → exit 2 → Claude updates docs → Stop fires again
4. Everything aligned → `git add -A` → conventional commit → push

**Skip:** Create `.skip-doc-check` in project root
**Commit format:** `type(scope): update N file(s)` with change list in body
**Auto-detects:** feat, fix, docs, test, refactor, chore

## Doc-Strategy Agent

For deeper documentation audits beyond the automated push-commit check:

```
/agent doc-strategy
```

Spawns a subagent that reads your git diff, inventories all documentation,
and produces a structured alignment report with severity ratings (🔴 Critical,
🟡 Important, 🟢 Nice-to-have) and specific recommended edits.

## Installation

### 1. Copy files into your project

```bash
# From your project root:
mkdir -p .claude/hooks .claude/agents

# Copy hooks
cp hooks/deletion-guard.sh      .claude/hooks/
cp hooks/secrets-guard.sh       .claude/hooks/
cp hooks/overwrite-guard.sh     .claude/hooks/
cp hooks/network-guard.sh       .claude/hooks/
cp hooks/session-checkpoint.sh   .claude/hooks/
cp hooks/injection-scanner.sh    .claude/hooks/
cp hooks/permission-handler.sh   .claude/hooks/
cp hooks/push-commit.sh         .claude/hooks/

# Copy agent definition
cp agents/doc-strategy.md       .claude/agents/

# Make executable
chmod +x .claude/hooks/*.sh
```

### 2. Wire the hooks

```bash
# If you don't have settings yet:
cp hooks-settings.json .claude/settings.json

# If you already have settings, merge the "hooks" key manually.
```

### 3. Activate in Claude Code

After modifying settings on disk:
- Open Claude Code and go to `/hooks` to review
- Hooks edited on disk require session restart to activate
- This is a security feature — hooks can't silently self-modify

### 4. Global hooks (recommended for some)

Deletion guard and secrets guard work well as global hooks since they protect
against universal risks. Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/deletion-guard.sh\"",
            "timeout": 10
          },
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/secrets-guard.sh\"",
            "timeout": 10
          }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/secrets-guard.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

## Dependencies

- `jq` — JSON parsing (all hooks)
- `git` — checkpoint, push-commit, doc alignment
- `sha256sum` — two-strike approval hashing
- Standard POSIX tools (grep, sed, awk, sort, date, mktemp)

All are present on Ubuntu/Debian by default. For macOS, install `jq` and
`coreutils` (for `sha256sum` → `gsha256sum`).

## Two-Strike Approval System

Four hooks use the same pattern for operations that are dangerous but
sometimes legitimate:

1. **Strike 1:** Hook detects dangerous operation → blocks → records
   SHA-256 hash of the exact command with timestamp → Claude explains
   to user what it wants to do and why
2. **Strike 2:** User confirms → Claude retries the exact same command →
   hook finds the hash → consumes it → allows through
3. **Expiry:** Approvals expire after 10 minutes (configurable via
   `APPROVAL_TTL` in each script)
4. **Storage:** `/tmp/claude-approvals-{type}` — cleared on reboot

This means Claude can never silently delete, overwrite, read secrets,
or connect remotely without the user seeing and approving the specific
operation.

## Customization

### Adjust what counts as "code" vs "docs"

Edit patterns in `push-commit.sh`:

```bash
code_pattern='\.(sh|bash|py|js|ts|jsx|tsx|rs|go|...)$'
doc_pattern='\.(md|txt|rst|...)$|README|CHANGELOG|docs/'
config_pattern='\.(json|lock|sum|...)$|Dockerfile|\.github/'
```

### Add protected secret paths

Edit `SENSITIVE_PATH_PATTERNS` array in `secrets-guard.sh`:

```bash
SENSITIVE_PATH_PATTERNS=(
  '\.env$'
  '\.env\.'
  # Add your custom patterns:
  'my-project\.secret'
  '/vault/'
)
```

### Change approval TTL

Each hook has `APPROVAL_TTL=600` (10 minutes). Reduce for tighter security
or increase for longer working sessions.

### Disable auto-push

Comment out the push section at the bottom of `push-commit.sh`.
Commits still happen; you push manually when ready.

### Skip doc check per-session

```bash
touch .skip-doc-check    # Skip until removed
rm .skip-doc-check       # Re-enable
```

### Add injection patterns

Edit pattern groups in `injection-scanner.sh`. Each category uses
`grep -oiP` with Perl-compatible regex. Add new patterns to
existing categories or create new ones.

## CVE Coverage

| CVE / Disclosure | Description | Hook(s) |
|---|---|---|
| CVE-2025-55284 | DNS exfiltration via ping subdomains | network-guard (hard block ping), secrets-guard |
| Knostic AI | .env auto-loading, printenv exposure | secrets-guard, permission-handler |
| Lasso Security | Prompt injection in file content | injection-scanner |
| GitHub #14964 | Write tool overwrites without reading | overwrite-guard |
| GitHub #12851 | Missing backup-before-delete | session-checkpoint, deletion-guard |
| GitHub #12232 | AllowedTools ignored with bypassPerms | permission-handler (defense in depth) |
| Backslash Security | MCP server trust boundaries | permission-handler (future: MCP hooks) |

## Known Limitations

1. **Claude Code auto-loads .env into memory at startup.** Hooks can't
   prevent this — they block explicit reads and output. Use bubblewrap
   (`--ro-bind /dev/null .env`) or vault solutions for full protection.

2. **PostToolUse scanner can't block.** The tool already ran. Scanner
   injects warnings but can't undo a file read. This is by design —
   it's an alerting layer, not a blocking layer.

3. **Write tool can overwrite files without Bash.** The overwrite-guard
   catches `mv`/`cp` via Bash but not Claude's native Write tool writing
   to an existing path. The permission-handler approves Write (it's
   usually needed), but consider adding a PreToolUse Write matcher for
   critical files.

4. **Pattern-based detection has limits.** Obfuscated commands
   (`\r\m -rf /`) or base64-encoded payloads can bypass grep patterns.
   These are edge cases — the goal is defense in depth, not perfection.

5. **PermissionRequest may not fire in --dangerously-skip-permissions.**
   PreToolUse hooks are the primary safety layer in dangerous mode.
   The permission-handler is defense in depth for normal/reduced modes.

## Philosophy

This system follows the principle that sovereignty requires vigilance
but not paranoia. The hooks create a safety floor — a set of invariants
that hold regardless of what Claude is told to do:

- You always have a rollback point
- Deletions always require your eyes
- Secrets never leak silently
- Overwrites never happen invisibly
- Network exfiltration channels are closed
- Prompt injections are flagged
- Documentation stays aligned with code

Everything runs locally. No external API calls. No telemetry.
Every decision is logged for your review. The system works for you,
never around you.
