# Feedback on `explicit` (from a Claude Code session, 2026-04-08)

Notes from one full session: scaffolding a Phoenix + Oban project
guarded by the OPP→ADR→code workflow. Ordered roughly by pain.

## Bugs

### 1. Watch server caches stale doc-error counts

Symptom: after fixing the docs the stop hook still reported
`Quality issues: 3 doc errors`. `explicit docs lint --json` and
`explicit docs validate` both said 0 errors, but `explicit quality --json`
kept returning `doc_errors: 3` with an empty `files: []` list. Workaround
was `explicit stop` (which restarts the server on next invocation) — then
quality immediately went green.

The watch server is treating "doc errors" as a sticky counter that isn't
invalidated when the underlying files change. Two contracts are out of
sync inside the same process. This blocked the stop hook even though the
tree was actually clean — i.e. it produced a false-positive merge gate.

Fix ideas:
- Re-derive `doc_errors` from current file state on every `quality` call,
  not from a cached counter.
- Or: invalidate the cache on fsnotify edit events for any path under
  `docs/`.
- Or at the very least: include the *list* of failing files in the
  failure payload so the user can see whether the cache is stale (right
  now `quality` reports a count with no paths).

### 2. `validate` and `docs describe` disagree about `code_paths`

`explicit docs describe adr` lists `code_paths` as a valid field on the
`adr` type:

```json
{"name":"code_paths","type":"string[]","description":"Glob patterns of source code paths related to this decision","required":false}
```

But `explicit validate` rejected it with:

```
F010: Field 'code_paths' is not allowed in frontmatter. Links go from code
to docs, not the other way. Remove code_paths and reference doc IDs in
your Elixir code instead.
```

Either the schema or the validator is wrong, but they ship together so
the contradiction is internal. Users discover it the hard way.

### 3. `F000 Unknown document type` on docs that have a valid type

Both ADR-001 and OPP-001 sit in the canonical `docs/architecture/` and
`docs/opportunities/` folders, match the schema's `folder` field, and
pass `docs validate`. But `validate` still emits an `F000` warning for
each. Either drop the warning or explain what it actually wants.

### 4. `validate` scans `_build/` and `deps/`

`explicit validate` walks into `services/oban-extra/_build/dev/lib/phoenix/priv/templates/...`
and `services/oban-extra/deps/...` and reports hundreds of "missing @doc"
violations against Phoenix's own generator templates and third-party
hex packages. Signal:noise was roughly 0:300 in this session.

Should respect `.gitignore` (or at minimum skip `_build/`, `deps/`,
`node_modules/`, `priv/static/`) by default. There must already be a
list somewhere because `mix format` and `mix test` know it; reuse it.

## DX

### 5. `docs new` produces a doc that fails `docs validate`

`explicit docs new opp "..."` creates a frontmatter block missing the
required `author` field. Then `docs validate` complains. The tool that
*creates* the doc should know which fields are required and prefill
them — `author` is trivially `git config user.name` or
`git config user.email`. Same for `date` (already filled) and `status`
(already defaulted to `identified`/`proposed`).

Right now the workflow is:

```
explicit docs new opp "Title"        # creates broken doc
explicit docs validate                # fails
# read describe output
explicit docs describe opp            # discover required fields
# manually edit frontmatter to add author
explicit docs validate                # passes
```

When it could be:

```
explicit docs new opp "Title"         # creates valid doc
explicit docs validate                # passes
```

### 6. Four overlapping commands, no clear authority

`validate`, `quality`, `docs validate`, `docs lint` all check overlapping
subsets of rules and disagree on what counts as an error vs warning vs
clean. In this session:

- `docs validate` → 0 errors, 4 warnings
- `docs lint` → clean, 0 errors
- `quality` → 3 doc errors (cached)
- `validate` → 1 doc error (the ghost F010)

Pick one canonical "is this project shippable" command. Make the others
either alias it or be obviously narrower (e.g. `docs lint` = doc graph
health only).

### 7. Stop hook message is too terse to act on

```
[explicit hooks claude stop]: Quality issues: 3 doc errors
Run `explicit violations` for full list.
```

Two problems:
1. `explicit violations` (no arg) does *not* show doc errors. It shows
   per-file code violations. The hook is pointing at the wrong command.
2. The hook already knows the count — it should print the file paths
   and check codes inline. The agent then has actionable info without
   another round-trip.

Better message:

```
[explicit] 3 doc errors blocking commit:
  docs/opportunities/opp-001-...md:F002 missing required field 'author'
  docs/architecture/adr-001-...md:F002 missing required field 'author'
  docs/architecture/adr-001-...md:F010 'code_paths' not allowed
Run `explicit docs validate --json` for details.
```

### 8. `docs describe` is per-type only

To learn the schema you must run `explicit docs describe opp`,
`explicit docs describe adr`, `explicit docs describe spec`, ... one at
a time. `explicit docs describe` (no arg) returns the *list* of types
without their fields, so you can't see the requirement matrix at a
glance. A `--all` flag, or making the no-arg form return everything,
would save 5+ round-trips when first onboarding to a project.

## Token efficiency

Concrete changes that would have cut this session's `explicit` token
spend by an estimated 60–80%:

### 9. Default to errors-only

Every `validate` call in this session produced ~30 lines of warnings I
didn't act on, plus hundreds of `_build/`/`deps/` false positives
(see #4). A default `--errors-only` mode with an explicit `--all` flag
would have replaced all of them with empty output.

### 10. `--json` output is truncated mid-string at 8192 bytes

```
$ explicit validate --json | wc -c
8192
$ explicit validate --json | tail -c 50
...constraint priority_range from table public.oban_jobs", "
                                                              ^ no closing
```

The JSON cannot be parsed because it's cut off mid-string. I had to
write a `--json | python3 -c ...` filter that crashed, then fall back
to per-file `explicit violations <path>`. If the output were complete
*or* paginated *or* streamed (NDJSON), one call would replace ten.

### 11. JSON fields contradict each other

`quality --json` returned:

```json
{"clean": false, "doc_errors": 3, "files": [], "details": {"by_check": {}}}
```

`clean: false` and `doc_errors: 3` but `files: []` — no way to act on
this. I had to call three more commands to figure out *what* was wrong.
If `doc_errors > 0`, populate `files` with the offending paths.

### 12. Plain-text default is just paths, no codes/messages

```
$ explicit validate
[FAIL]
  /Users/.../auth.ex
  /Users/.../context_fixtures_functions.ex
  ...
```

A path with no error code or message is not actionable — the user
*has* to switch to `--json`, which is then truncated (#10). The plain
output should be `path:line  CODE  message` like every other linter
since 1976.

### 13. Eliminate the "quality vs validate vs docs validate" round-trips

Right now to figure out the state of the world I made calls to
`explicit validate`, `explicit validate --json`, `explicit quality`,
`explicit quality --json`, `explicit docs validate`, `explicit docs lint`,
`explicit docs lint --json`, `explicit check <path>` (×2),
`explicit violations <path>` (×5), `explicit stop`, `explicit status`.
That's ~14 invocations. With (a) one canonical command, (b) machine-
readable complete output, and (c) the cache bug fixed, the entire
session could have used `explicit quality --json` exactly twice
(once before, once after).

## Summary table

| Pain | Fix | Estimated token savings |
| --- | --- | --- |
| Stale cache (#1) | Re-derive on each call | High — stop hook re-runs |
| `_build/`/`deps/` scanning (#4) | Respect .gitignore | High — 300 noise lines per call |
| `--json` truncation (#10) | Stream / paginate | High — forces fallback loops |
| `quality` reports count without files (#11) | Populate `files` array | High — eliminates 3 follow-up calls |
| `docs new` missing required fields (#5) | Prefill `author` | Medium |
| Plain-text has no codes (#12) | `path:line CODE msg` | Medium |
| Hook message too terse (#7) | Inline the violations | Medium |
| 4 overlapping commands (#6) | Pick one | Medium |

## What works well

To balance the criticism:

- The OPP/ADR/SPEC schema concept is genuinely useful — separating
  business *why* from technical *how* is the right cut, and the agent
  was guided into it correctly the first time.
- `explicit docs new <type> "Title"` returning JSON with `id` and
  `path` is exactly right for tool-driven use.
- The stop hook *exists* — even buggy, a hard gate beats a soft
  convention. Just make it actionable.
- Type aliases (`opportunity` → `opp`) are friendly.
- Per-file `explicit check <path>` is a clean primitive that other
  commands could be built on top of.
