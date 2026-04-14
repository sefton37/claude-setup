# Agent Panel for Claude Code

A curated roster of 13 specialized subagents designed from evidence-based best practices.

## Design Principles

This panel was built against three bodies of evidence:

1. **Anthropic's official guidance** — [Claude Code: Best practices for agentic coding](https://www.anthropic.com/engineering/claude-code-best-practices) and the [Claude Agent SDK](https://www.anthropic.com/engineering/building-agents-with-the-claude-agent-sdk) engineering posts.
2. **MAST failure taxonomy** (Cemri et al., NeurIPS 2025) — 14 failure modes across 1600+ multi-agent traces, organized into system design, inter-agent misalignment, and task verification failures.
3. **Production patterns** from PubNub, ClaudeLog, and VoltAgent community repos.

### Key constraints applied:
- **Lightweight prompts** (~1-2k tokens each) for fast initialization and efficient chaining
- **Minimal tool permissions** per agent (least privilege)
- **Model tiering** — Haiku for read-only/speed tasks, Sonnet for reasoning
- **Single responsibility** — each agent does one thing well
- **Explicit contracts** — every agent defines inputs, outputs, and Definition of Done
- **Failure-mode-aware** — Verifier agent directly addresses MAST's task verification gap; State Fidelity agent directly addresses frontend-backend data integrity gap; Historian agent directly addresses inter-session knowledge loss

---

## The Roster

| Agent | Model | Tools | Role | Write Access |
|-------|-------|-------|------|-------------|
| **scout** | haiku | Read, Grep, Glob, Bash | Codebase exploration & search | ❌ None |
| **planner** | sonnet | Read, Grep, Glob, Bash, Write | Architecture & planning | 📝 Docs only |
| **implementer** | sonnet | Read, Write, Edit, Bash, Glob, Grep | Code writing & execution | ✅ Full |
| **reviewer** | sonnet | Read, Grep, Glob, Bash | Code review | ❌ None |
| **state-fidelity** | sonnet | Read, Grep, Glob, Bash | Data truthfulness audit (UI ↔ backend) | ❌ None |
| **tester** | sonnet | Read, Write, Edit, Bash, Glob, Grep | Test writing (TDD) | ✅ Full |
| **debugger** | sonnet | Read, Edit, Bash, Glob, Grep | Root cause analysis & fixes | ✏️ Edit only |
| **security-scanner** | sonnet | Read, Grep, Glob, Bash | Security vulnerability scanning | ❌ None |
| **documenter** | sonnet | Read, Write, Edit, Glob, Grep | Documentation writing | ✅ Full |
| **git-ops** | sonnet | Read, Bash, Grep, Glob | Git workflow & PR management | ❌ None (git via Bash) |
| **refactorer** | sonnet | Read, Write, Edit, Bash, Glob, Grep | Code improvement | ✅ Full |
| **verifier** | haiku | Read, Grep, Glob, Bash | Post-task verification | ❌ None |
| **historian** | sonnet | Read, Write, Edit, Grep, Glob | Project memory — recall & record | 📝 `.memory/` only |

---

## Installation

### Per-project (recommended for teams)
```bash
# From your project root
cp -r agents/ .claude/agents/
# Commit to share with team
git add .claude/agents/
git commit -m "feat: add Claude Code agent panel"
```

### Global (available in all projects)
```bash
cp -r agents/ ~/.claude/agents/
```

### Verify
In Claude Code, run:
```
/agents
```
You should see all 13 agents listed.

### Historian setup
The historian reads and writes to a `.memory/` directory in your project root. Initialize it once:
```bash
mkdir -p .memory
echo "# Project Memory\n\nInitialized $(date -I).\n" > .memory/README.md
echo ".memory/" >> .gitignore  # or commit it — your call
```

If you want memory version-controlled (recommended for teams), commit `.memory/` instead of ignoring it. Decisions and patterns become part of your project's institutional knowledge.

---

## Common Workflows

### 🏗️ Full Feature Development (Plan → Test → Build → Review → Ship)

```
1. "Use the historian to recall context about the auth system"
   → historian surfaces prior decisions, known gotchas, relevant patterns

2. "Use the planner to design the authentication module"
   → planner researches codebase, produces plan document

3. "Use the tester to write tests for the auth module based on the plan"
   → tester writes failing tests (TDD)

4. "Use the implementer to make all auth tests pass"
   → implementer writes code until tests green

5. "Use the reviewer to check the auth implementation"
   → reviewer evaluates quality, security, maintainability

6. "Use the security-scanner to audit the auth module"
   → security-scanner checks for vulnerabilities

7. "Use the verifier to confirm the auth feature is complete"
   → verifier checks requirements against deliverables

8. "Use git-ops to commit and create a PR for the auth feature"
   → git-ops creates structured commits and PR description

9. "Use the historian to record what was decided and learned"
   → historian distills decisions, trade-offs, and gotchas into .memory/
```

### 🐛 Bug Fix (Reproduce → Fix → Verify)

```
1. "Use the historian to check if we've seen this bug pattern before"
   → historian searches memory for prior incidents in this area

2. "Use the debugger to investigate why login fails with SSO tokens"
   → debugger reproduces, diagnoses root cause, applies minimal fix

3. "Use the tester to add a regression test for the SSO bug"
   → tester writes test that would have caught the bug

4. "Use the verifier to confirm the fix is complete"
   → verifier runs tests, checks no regressions

5. "Use the historian to record the root cause and fix"
   → historian logs the failure pattern so future sessions recognize it
```

### 🔍 Codebase Exploration

```
1. "Use the scout to find how payments are processed"
   → scout traces payment flow across files, returns paths

2. "Use the planner to evaluate options for replacing Stripe with Square"
   → planner produces comparison with trade-offs and migration plan
```

### 🧹 Refactoring

```
1. "Use the scout to find all duplicated validation logic"
   → scout identifies patterns

2. "Use the refactorer to consolidate validation into shared utilities"
   → refactorer restructures code, tests stay green

3. "Use the reviewer to check the refactoring"
   → reviewer verifies no behavior changed

4. "Use the documenter to update the README"
   → documenter writes docs reflecting new structure
```

### 🔍 Data Truthfulness Audit (UI ↔ Backend)

```
1. "Use the state-fidelity agent to audit the package list component"
   → state-fidelity traces: system package DB → API → React Query cache → rendered list
   → catches: missing cache invalidation after install/uninstall mutations

2. "Use the state-fidelity agent to audit the config editor"
   → state-fidelity traces: config file on disk → API read → form state → rendered values
   → catches: form useState holding stale copy after backend write
```

### 🐛 Data-Layer Bug Fix (UI Shows Wrong Data)

```
1. "Use the state-fidelity agent to find where the data path diverges"
   → state-fidelity identifies that mutation succeeds but cache key mismatch prevents invalidation

2. "Use the debugger to fix the cache invalidation"
   → debugger aligns query keys between read and invalidation

3. "Use the tester to add a regression test"
   → tester writes test verifying UI reflects post-mutation state

4. "Use the verifier to confirm the fix"
   → verifier runs tests, checks no regressions
```

### 📜 Session Continuity (New Session Cold Start)

```
1. "Use the historian to recall what we were working on"
   → historian reads .memory/sessions.md and .memory/decisions.md
   → returns: last session's context, open items, active decisions

2. "Use the historian to recall everything about the API rate limiter"
   → historian searches .memory/ for rate-limiter-related entries
   → returns: when it was built, why, what was rejected, known edge cases
```

---

## Agent Interaction Rules

These agents follow Claude Code's architectural constraints:

- **Subagents cannot spawn sub-subagents.** The main conversation orchestrates.
- **Context is isolated.** Each agent works in its own window and returns a summary.
- **Handoffs are explicit.** The orchestrator (you or the main agent) decides what runs next.
- **Read-only agents never modify code.** This is enforced by tool permissions.
- **Historian writes only to `.memory/`.** It never modifies source code, tests, or docs.

---

## Customization

### Changing models
Edit the `model:` field in any agent's frontmatter:
- `haiku` — fastest, cheapest, great for read-only tasks
- `sonnet` — balanced reasoning and speed (default for most)
- `opus` — deepest reasoning, use for genuinely complex analysis
- `inherit` — use whatever model the main conversation uses

### Adding MCP tools
Add MCP server tools to the `tools:` field:
```yaml
tools: Read, Grep, Glob, Bash, mcp__my-server__my-tool
```

### Project-specific overrides
Place a modified version of any agent in `.claude/agents/` (project level) to override the global version for that project.

---

## Design Rationale

### Why 13 agents and not 100?
Research (NeurIPS 2025) shows multi-agent performance degrades with coordination overhead. Systems that learn to prune agents over time outperform static large rosters. These 13 cover the full development lifecycle without overlap. Each agent has exactly one lens — no agent is asked to evaluate quality AND security AND data fidelity simultaneously.

### Why separate tester and implementer?
Anthropic's internally recommended TDD workflow explicitly separates test writing from implementation to prevent the implementer from "teaching to the test." The tester writes the spec; the implementer satisfies it.

### Why a verifier?
The MAST taxonomy identified task verification as one of three primary failure categories in multi-agent systems. Without independent verification, agents self-report completion and errors compound silently.

### Why a state-fidelity agent?
No existing agent defaults to asking "is what the user sees actually what the system knows?" Reviewer evaluates code quality. Tester writes tests for defined behavior. Security-scanner finds vulnerabilities. None of them trace the full data path from source of truth → API → frontend state → rendered UI to catch stale caches, unreconciled optimistic updates, derived state drift, or missing loading/error states. In systems where the UI represents backend or system state (like ReOS), data fidelity is the central architectural concern — not an edge case. A dedicated agent ensures this lens is applied automatically, not only when someone remembers to ask.

### Why a historian?
The other 12 agents are action agents — they do things to the codebase within a single session. But Claude Code sessions are stateless. Every new session starts cold: scout re-discovers what it already found yesterday, planner re-researches decisions that were already made, debugger re-diagnoses patterns that were already identified. The historian is a continuity agent. It maintains the project's self-knowledge across sessions by recording decisions, patterns, gotchas, and session context into `.memory/` — plain markdown files that live in the repo, are human-readable, version-controllable, and searchable by any agent via Read and Grep. Without independent memory, institutional knowledge exists only in git history (implicit, buried) or in the developer's head (unavailable to agents). The historian makes it explicit, structured, and retrievable.

### Why Haiku for scout and verifier?
Both are read-only, high-frequency agents. Haiku delivers ~90% of Sonnet's capability for search and verification tasks at 2x speed and 3x cost savings (per Anthropic benchmarks). They should be cheap and fast.

### Why Sonnet for historian (not Haiku)?
The historian's job is judgment — deciding what's worth remembering, how to structure it, and what to surface given an ambiguous request. This is a reasoning task, not a search task. Haiku can find patterns; Sonnet can evaluate which patterns matter. The historian runs infrequently (start and end of sessions, not mid-task), so cost is negligible.
