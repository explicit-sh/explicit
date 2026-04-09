@CLAUDE.md

## Codex Hooks

- Reference: https://developers.openai.com/codex/hooks
- Enable Codex hooks with `.codex/config.toml` and `[features] codex_hooks = true`.
- Repo-local Codex hooks live in `.codex/hooks.json`.
- Current Codex `PreToolUse` and `PostToolUse` events only match `Bash`; `Edit|Write` matchers do not fire there.
- `Stop` ignores `matcher` and can continue the run by exiting `2` with a reason on stderr.
- explicit hook entry points for Codex are `explicit hooks codex check-fixme`, `explicit hooks codex check-code`, and `explicit hooks codex stop`.
