---
name: explicit-stale-doc-errors-cache
description: |
  Fix stop-hook blocking with "N doc errors" from the `explicit` quality tool
  when the documents are actually clean. Use when: (1) `explicit` claude-code
  stop hook reports `Quality issues: N doc errors` but you just fixed them,
  (2) `explicit quality --json` returns `{"clean": false, "doc_errors": N,
  "files": []}` — note the empty files array alongside the non-zero count,
  (3) `explicit docs validate` and `explicit docs lint --json` both report 0
  errors but `explicit quality` still fails, (4) `explicit check <path>` on
  every doc returns "No violations found" yet quality stays red,
  (5) per-file `explicit violations <path>` finds nothing. Root cause: the
  `explicit` watch server caches an aggregate `doc_errors` counter that is
  not invalidated when files change on disk. The fix is to restart the
  watch server.
author: Claude Code
version: 1.0.0
date: 2026-04-08
---

# Explicit watch-server stale `doc_errors` cache

## Problem

The `explicit` Elixir code-quality tool runs a long-lived background watch
server (`explicit watch` / auto-started by `explicit status`). It maintains
an aggregate `doc_errors` counter that can become stale: even after the
underlying doc files have been fixed and individual checks (`docs validate`,
`docs lint`, per-file `check`) all pass, `explicit quality` still reports
the old count and the stop hook keeps blocking.

This produces a false-positive merge gate that no amount of editing the
docs will clear.

## Context / Trigger conditions

All of these symptoms point at this bug:

- Stop hook output:

  ```
  [explicit hooks claude stop]: Quality issues: 3 doc errors
  Run `explicit violations` for full list.
  ```

  …but `explicit violations` (no arg) lists nothing relevant.

- `explicit quality --json` returns:

  ```json
  {"clean": false, "doc_errors": 3, "files": [], "details": {"by_check": {}}}
  ```

  Note the `files: []` alongside `doc_errors: 3` — that's the smoking gun.
  A real failure would populate `files`.

- `explicit docs validate` says `errors: 0` (only warnings).

- `explicit docs lint --json` returns `{"clean": true, ..., "errors": []}`.

- `explicit check <every-doc-path>` returns "No violations found" for every
  file.

- `explicit status` shows `Doc errors: 3` even though all on-disk checks
  are clean.

## Solution

Restart the watch server. There is no `restart` subcommand, but
`explicit stop` followed by any other `explicit` invocation auto-starts a
fresh server which re-derives the counts from disk.

```sh
explicit stop
explicit quality --json   # auto-starts a fresh server, returns clean
```

Then re-trigger the stop hook (or just continue working — it will pass on
the next attempt).

## Verification

After `explicit stop`, the next `explicit quality --json` should return:

```json
{"clean": true, "doc_errors": 0, ..., "total_issues": 0}
```

And `explicit status` should show `Doc errors: 0`.

## Example

Full session from a real occurrence:

```sh
$ explicit quality --json
{"data":{"clean":false,"doc_errors":3,"files":[],...},"ok":true}

$ explicit docs validate
{"data":{"errors":0,"files":3,...},"ok":true}   # disagrees!

$ explicit docs lint --json
{"data":{"clean":true,"errors":[],...},"ok":true}   # also disagrees

$ explicit check docs/architecture/adr-001-*.md
No violations found.

$ explicit check docs/opportunities/opp-001-*.md
No violations found.

# Cache bug confirmed. Restart:
$ explicit stop
Server stopped.

$ explicit quality --json
{"data":{"clean":true,"doc_errors":0,"total_issues":0,...},"ok":true}
```

## Notes

- The bug is in the watch server, not in the docs or schema — do NOT
  spend time editing docs further once you've confirmed the symptoms.
  The whole point of recognizing this pattern is to skip that wild
  goose chase.
- Quick discriminator: if `quality` reports `doc_errors > 0` AND
  `files: []` in the same JSON payload, it is *always* the cache bug
  (a real error always has at least one file path).
- `explicit stop` is safe — the server is just a daemon for incremental
  caching; restarting it does not lose any persistent state.
- This may also affect the `code_violations` / `iron_law_violations`
  counters. If they look stale, the same `explicit stop` workaround
  applies.
- File a bug upstream if you have the time: the `quality` command should
  re-derive counters from the filesystem on each invocation, or the
  watch server should invalidate its cache on fsnotify edit events under
  `docs/`.
