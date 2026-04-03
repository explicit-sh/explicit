# Explicit — Codebase Review & Improvement Recommendations

## What It Does Well

The architecture is clever: a persistent OTP server doing real-time AST analysis, a Zig CLI as thin client, and Claude hooks as the enforcement mechanism. The **Stop hook pattern** (block Claude from completing until quality passes) is the key innovation — it creates an inescapable feedback loop.

Key strengths:
- **Schema-driven doc validation** via KDL is well-designed and extensible
- **Eval framework** with scenario YAML + LLM answerer is a solid approach to testing AI behavior
- **Suppression system** (`# explicit:disable RuleName`) respects developer autonomy
- **File watcher with debouncing** avoids redundant checks
- **Hash-based caching** in `ViolationStore` skips unchanged files

---

## How to Force Better Output from Claude

The core question. Here are concrete improvements ordered by impact:

### 1. 🔴 The Stop Hook Is Too Easily Satisfied

**Problem:** The stop hook in [connection_handler.ex](file:///Users/onnimonni/Projects/elixir-explicit/server/lib/explicit/connection_handler.ex) (`hookClaudeStop`) only checks `quality` + `test.run`. The `quality` method counts violations but doesn't check doc quality deeply — it counts `doc_errors` but doesn't gate on them. Claude can write minimal stubs that technically pass.

**Fix:**
- Gate on **doc completeness** — check that required sections have real content, not just boilerplate. Add a `min-words` or `min-sentences` constraint to sections in schema.kdl.
- Gate on **test-to-code ratio** — if there are 10 modules but only 2 test files, block.
- Gate on **doc-ref density** — don't just check that `OPP-001` exists somewhere; verify each non-boilerplate module references at least one doc ID in `@moduledoc`.
- Add a **"substance check"** — detect low-effort docs (e.g., "TBD", single-word section content, lorem ipsum).

### 2. 🔴 The System Prompt Lacks Negative Examples

**Problem:** [system_prompt.ex](file:///Users/onnimonni/Projects/elixir-explicit/server/lib/explicit/system_prompt.ex) tells Claude *what to do* but not *what bad looks like*. LLMs respond better when shown the contrast between good and bad output.

**Fix:** Add explicit anti-patterns to the system prompt:
```
## BAD — Do NOT do this:
- Creating a doc with section content "TBD" or "TODO"
- Writing @moduledoc "Implements OPP-001" without explaining what the module does
- Asking all questions in a single text block instead of using AskUserQuestion
- Writing tests after code (tests-first means tests BEFORE implementation)
- Skipping ADR when making architecture decisions like "use LiveView" or "use ETS"
```

### 3. 🟡 PostToolUse Hook Only Checks FIXMEs

**Problem:** The `PostToolUse` hook ([settings.json](file:///Users/onnimonni/Projects/elixir-explicit/.claude/settings.json)) only runs `check-fixme` after Write/Edit. This is a missed opportunity.

**Fix:** Add a `check-code` PostToolUse hook that:
- Runs the violation checker on the just-edited file immediately
- Returns violations as feedback *while Claude is still working*, not just at stop time
- This creates a tighter feedback loop — Claude sees issues within the same turn and can fix them immediately

### 4. 🟡 No Semantic Quality Checks on Documentation

**Problem:** Doc validation checks structure (required sections exist, frontmatter valid) but not **content quality**. Claude can write `## Context\n\nThis is the context.` and it passes.

**Fix:**
- Add `min-words` constraint to section schema (e.g., `section "Context" required=#true min-words=30`)
- Add a **Consequences balance check** — if Positive has 3 items but Negative has 0, flag it
- Add a **Gherkin syntax check** for spec Scenarios — verify `Given/When/Then` keywords exist
- Detect boilerplate fillers: "This section describes...", "The purpose of this..."

### 5. 🟡 The Eval Scorer Could Be More Granular

**Problem:** [scorer.ex](file:///Users/onnimonni/Projects/elixir-explicit/eval/lib/eval/scorer.ex) scores broadly but doesn't check output *quality*. It checks if docs exist but not if they're good.

**Fix:**
- Score doc content quality (word count, section completeness, Gherkin validity)
- Score test quality (number of assertions, test names descriptiveness)
- Score code quality (functions have real logic vs stubs)
- Add **timing scores** — did Claude follow the correct phase ordering? (questions → docs → validate → tests → code → quality)
- Add a **regression score** — compare against previous eval runs

### 6. 🟢 Add a PreToolUse Hook for Ordering Enforcement

**Problem:** The system prompt says "don't write code before docs" but there's no enforcement beyond the Stop hook. Claude writes code, gets blocked, *then* goes back and creates docs retroactively (which defeats the purpose).

**Fix:** Add a `PreToolUse` hook that:
- On first Write/Edit of a `.ex` file, checks whether `explicit docs validate` has been called (track via a state file)
- If no docs validated yet, return an error message: "You must create and validate docs before writing code. Run: explicit docs new opp 'Title'"
- This prevents the retroactive-doc problem

### 7. 🟢 Missing Checks That Would Improve Code Quality

Current checks are good but narrow. Add:

| Check | Detects |
|-------|---------|
| `NoHardcodedSecrets` | API keys, passwords, tokens in source |
| `NoNPlusOne` | `Repo.all` inside `Enum.map` (Ecto preload missing) |
| `NoMixEnvInRuntime` | `Mix.env()` calls outside config (crashes in releases) |
| `NoIOInspectInProd` | `IO.inspect` left in non-test code |
| `RequireChangesetValidation` | Schema without changeset function |

### 8. 🟢 Skills Need More Specificity

**Problem:** The generated skills in [init.ex](file:///Users/onnimonni/Projects/elixir-explicit/server/lib/explicit/init.ex) are generic. They say "fill in Context, Decision, Consequences" but don't show *how*.

**Fix:** Make skills include concrete examples with the project name interpolated:
```markdown
## Example ADR

---
status: proposed
author: onni
date: 2026-04-03
---

# Use Phoenix LiveView for real-time store updates

## Context
The llama milk store needs real-time inventory updates when products sell out.
Server-sent events would require separate WebSocket infrastructure...

## Decision
Use Phoenix LiveView because it provides real-time updates without a separate
JavaScript framework. OTP processes can push changes to connected clients...
```

### 9. 🟢 Code-Doc Linking Enforcement Is Weak

**Problem:** The stop hook checks for regex `(ADR|OPP|SPEC)-\d{3}` in code, but doesn't verify the referenced doc ID actually *exists*. Claude can write `Implements OPP-999` and pass.

**Fix:** In the quality method, cross-reference doc IDs found in code against actually existing docs. Flag phantom references.

---

## Architecture & Code Quality Issues

### Zig CLI: Hand-rolled JSON Parsing

The CLI uses `mem.indexOf` + `extractJsonString` to parse JSON responses. This breaks on:
- Escaped quotes in values
- Nested objects with the same key names
- Values containing the key string

Consider using Zig's `std.json` parser, or at minimum add a comment acknowledging the fragility.

### Connection Handler: God Module

[connection_handler.ex](file:///Users/onnimonni/Projects/elixir-explicit/server/lib/explicit/connection_handler.ex) is 554 lines handling 20+ methods. Extract into domain modules:
- `Explicit.Handlers.Core` (status, violations, check, watch, stop)
- `Explicit.Handlers.Docs` (validate, new, list, get, set, describe, lint, diagnostics)
- `Explicit.Handlers.Quality` (quality, test.run, sarif)
- `Explicit.Handlers.Init` (init, scaffold)

### Missing Tests

The CLAUDE.md says "Tests for ViolationStore and Checker" are not done. These are critical — they're the foundation of the enforcement system. If a Credo check silently fails to detect a violation, the whole system becomes useless.

### `erl_crash.dump` Committed

[server/erl_crash.dump](file:///Users/onnimonni/Projects/elixir-explicit/server/erl_crash.dump) (4.8MB) should be in `.gitignore`.

### Eval Runner: `Code.compile_file` Is Fragile

In [runner.ex](file:///Users/onnimonni/Projects/elixir-explicit/eval/lib/eval/runner.ex#L176-L184), the eval runner dynamically compiles `system_prompt.ex` from a relative path. This breaks if the file moves or if the module is already loaded. Consider making the system prompt a shared library dependency instead.

---

## Priority Summary

| Priority | Improvement | Effort | Impact |
|----------|------------|--------|--------|
| 🔴 P0 | Tighten stop hook quality gates | Medium | High — blocks low-effort output |
| 🔴 P0 | Add negative examples to system prompt | Low | High — immediate prompt quality |
| 🟡 P1 | PostToolUse code check (tight feedback) | Medium | High — real-time error correction |
| 🟡 P1 | Semantic doc quality checks (min-words, etc) | Medium | High — prevents boilerplate docs |
| 🟡 P1 | Eval scorer granularity | Medium | Medium — better measurement |
| 🟢 P2 | PreToolUse ordering enforcement | Medium | Medium — prevents retroactive docs |
| 🟢 P2 | Additional code checks | Low each | Medium — catches more bugs |
| 🟢 P2 | Rich skill examples | Low | Medium — better doc quality |
| 🟢 P2 | Cross-reference doc IDs | Low | Low — edge case |
