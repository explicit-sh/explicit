@CLAUDE.md

## RTK

- Every shell command must be prefixed with `rtk`.
- Use direct wrappers when available: `rtk ls`, `rtk git status`, `rtk pytest`, `rtk docker ps`.
- If RTK does not provide a dedicated wrapper, use `rtk proxy ...` instead, for example `rtk proxy ssh user@host` or `rtk proxy mix test`.
- Do not run bare shell commands when an `rtk ...` or `rtk proxy ...` form can be used.

## Codex Hooks

- Reference: https://developers.openai.com/codex/hooks
- Enable Codex hooks with `.codex/config.toml` and `[features] codex_hooks = true`.
- Repo-local Codex hooks live in `.codex/hooks.json`.
- Current Codex `PreToolUse` and `PostToolUse` events only match `Bash`; `Edit|Write` matchers do not fire there.
- `Stop` ignores `matcher` and can continue the run by exiting `2` with a reason on stderr.
- explicit hook entry points for Codex are `explicit hooks codex check-fixme`, `explicit hooks codex check-code`, and `explicit hooks codex stop`.

## OpenCode Plugins

- Reference: https://opencode.ai/docs/plugins/
- Project config lives in `opencode.json` and project-local plugins live in `.opencode/plugins/`.
- OpenCode plugins are event-based, not native blocking stop hooks like Codex/Claude hooks.
- explicit's OpenCode integration listens for `session.idle` and runs `explicit hooks stop opencode`.
- OpenCode can be pointed at repo instructions with `"instructions": ["AGENTS.md"]` in `opencode.json`.

## Gemini CLI Hooks

- Reference: https://geminicli.com/docs/hooks/
- Project hook config lives in `.gemini/settings.json`.
- Gemini CLI project context defaults to `GEMINI.md`; explicit also configures Gemini to load `AGENTS.md` via `context.fileName`.
- explicit's Gemini integration uses `AfterTool` for `check-fixme` and `check-code`, and `AfterAgent` for `explicit hooks stop gemini`.
- Gemini hooks are synchronous and can block or retry turns depending on event and exit code.
