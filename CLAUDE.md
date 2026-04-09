# explicit — Elixir Code Analysis Tool

Client-server tool for real-time Elixir code analysis. Zig CLI + Elixir server (OTP release), designed for Claude Code integration.

## Project Status

MVP working end-to-end. Server boots, auto-finds git root, scans all .ex/.exs files, listens on Unix socket. CLI communicates via JSONL.

### What works
- Elixir server: boots, finds git root, auto-scans project, listens on `/tmp/explicit-{hash}.sock`
- Server distributed as OTP release with ERTS bundled (no Elixir/Erlang needed)
- Zig CLI: `watch`, `status`, `violations`, `check <file>`, `stop` commands
- `watch` spawns server as daemon, waits for socket
- 6 Iron Law checks detect violations via Credo AST analysis
- `--json` flag for machine-readable output
- Socket path derived from git root (supports multiple projects)
- Claude Code Stop hook blocks if violations found

### What's not done yet
- Human-readable table output (currently prints raw JSON in non-json mode)
- Tests for ViolationStore and Checker

## Installation

```bash
# Via Homebrew (after org + tap setup)
brew install explicit-sh/tap/explicit

# Or build from source
make build-cli       # Zig CLI
make build-server    # Elixir OTP release
```

## Quick Start

```bash
# Initialize project (git, devenv, claude hooks)
explicit init

# Start server (finds git root, scans project, backgrounds as daemon)
explicit watch

# Query violations
explicit status
explicit violations --json
explicit check path/to/file.ex

# Stop server
explicit stop
```

### Dev mode (no release build needed)

```bash
cd server && mix deps.get && mix run --no-halt
```

## Claude Code Integration

Run `explicit init` in your project to set up git, devenv, and Claude Code hooks automatically.

Or manually add to `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "explicit hooks claude stop"
      }]
    }]
  }
}
```

The stop hook blocks Claude when violations are found, forcing it to fix them.

## Codex Integration

`explicit init` also creates repo-local Codex hook config in `.codex/hooks.json` and enables hooks in `.codex/config.toml`.

Run `codex` from the repo root and Codex will pick up those hook files automatically.

Codex hook reference: <https://developers.openai.com/codex/hooks>

## OpenCode Integration

`explicit init` also creates `opencode.json` and a project-local plugin in `.opencode/plugins/explicit.js`.

The plugin listens for `session.idle` and runs `explicit hooks stop opencode`.

OpenCode plugin reference: <https://opencode.ai/docs/plugins/>

## Gemini CLI Integration

`explicit init` also creates `GEMINI.md` and `.gemini/settings.json`.

Gemini loads `AGENTS.md` as project context and runs explicit hooks after file edits and after the agent turn.

Gemini hook reference: <https://geminicli.com/docs/hooks/>

## Building

```bash
make build-cli          # Debug CLI
make build-cli-release  # Release CLI
make build-server       # OTP release (needs MIX_ENV=prod)
make dev                # Dev server via mix
```

### Requirements
- Zig 0.15.2 (CLI build)
- Elixir 1.20-rc4 + OTP 28 (server build)

### macOS 26 (Tahoe)
Zig linker doesn't know macOS 26. CLI uses `-target aarch64-macos.15.0-none` via Makefile.

### Nix + mix release
`include_erts: true` fails on nix (read-only store). Use `INCLUDE_ERTS=false` locally. CI builds with ERTS bundled.

## Architecture

```
┌─────────────┐    Unix socket     ┌──────────────────────────┐
│  Zig CLI    │◄──────────────────►│  OTP Release Server      │
│  explicit   │   /tmp/explicit-   │  (ERTS bundled)          │
│             │   {git_root_hash}  │                          │
│ subcommands:│   .sock            │  ┌─ Application          │
│  init       │                    │  │  (finds git root)     │
│  watch      │   JSONL protocol   │  ├─ SocketServer         │
│  status     │   (one JSON/line)  │  ├─ ConnectionHandler    │
│  violations │                    │  ├─ Watcher (FileSystem) │
│  check      │                    │  ├─ Checker (Credo AST)  │
│  stop       │                    │  ├─ ViolationStore (ETS) │
│  hooks      │                    │  └─ 6 Iron Law checks    │
│  claude     │                    └──────────────────────────┘
│    stop     │   Server binary searched in:
└─────────────┘   1. Same dir as CLI
                  2. ~/.explicit/explicit-server
                  3. $PATH
```

## Startup Flow

1. `explicit watch` — CLI finds git root from CWD
2. CLI computes socket path: `/tmp/explicit-{md5(git_root)[0:8]}.sock`
3. If socket exists and connects → server already running
4. Otherwise, CLI spawns `explicit-server daemon` with `EXPLICIT_PROJECT_DIR` env var
5. Server finds git root, starts Watcher, scans all .ex/.exs files
6. Server listens on socket, CLI connects and queries

## JSON Protocol

Unix socket, one JSON per line, request-response (connect → send → recv → close).

```json
{"method":"status"}
{"method":"violations"}
{"method":"violations","params":{"file":"/path/to/file.ex"}}
{"method":"check","params":{"file":"/path/to/file.ex"}}
{"method":"watch","params":{"dir":"/path/to/project"}}
{"method":"stop"}
```

Responses: `{"ok":true,"data":{...}}` or `{"ok":false,"error":"msg"}`

## Iron Law Checks

| Check | Iron Law | Detects |
|-------|----------|---------|
| `NoStringToAtom` | #10 | `String.to_atom/1` (skips test files) |
| `NoFloatForMoney` | #4 | `:float` on money fields in schemas + migrations |
| `NoRawWithVariable` | #12 | `raw(variable)` XSS |
| `NoImplicitCrossJoin` | #15 | Multiple `in` bindings in `from()` |
| `NoBareStartLink` | #13/14 | Unsupervised `GenServer/Agent.start_link` |
| `NoAssignNewForMountValues` | #21 | `assign_new` for `:current_user` etc |

## Key Files

```
server/lib/explicit/
├── application.ex          # OTP supervisor, git root detection
├── socket_server.ex        # gen_tcp Unix socket listener
├── connection_handler.ex   # JSON request dispatch
├── watcher.ex              # FileSystem watcher, auto-starts on boot
├── violation_store.ex      # ETS-backed violation cache
├── checker.ex              # Runs Credo checks on a file
├── protocol.ex             # JSON encode/decode helpers
└── checks/                 # 6 Credo AST checks

cli/src/main.zig            # Zig CLI — thin client, spawns server, hooks
.github/workflows/release.yml  # CI: build + release
```

## Distribution

### Homebrew tap
- Org: `explicit-sh` on GitHub
- Tap repo: `explicit-sh/homebrew-tap`
- Formula downloads pre-built tarball from GitHub Releases
- Tarball contains: Zig CLI + OTP release (with ERTS) + hook script
- Install: `brew install explicit-sh/tap/explicit`

### Release tarball structure
```
bin/explicit              # Zig CLI
bin/explicit-server       # Wrapper → lib/bin/explicit_server
lib/                      # OTP release (ERTS + compiled beams)
hooks/explicit-stop.sh    # Claude Code hook
```

## Technical Decisions

- **OTP release over Burrito**: Standard `mix release` with ERTS. Simpler, no Zig wrapper issues
- **gen_tcp over Plug/Cowboy**: No HTTP overhead for local JSONL protocol
- **ETS over GenServer state**: Concurrent reads from multiple connection handlers
- **packet: :line**: Erlang handles JSONL framing automatically
- **Per-project socket**: `/tmp/explicit-{md5_hash_of_git_root}.sock` for multi-project support
- **EXPLICIT_PROJECT_DIR env var**: Mix release boot scripts don't pass argv cleanly
- **daemon command**: Mix release `daemon` backgrounds the BEAM properly
- **Credo.SourceFile.parse/2**: Creates SourceFile from raw source string, runs check modules' `run/2` directly
- **No MCP**: Claude uses CLI via Bash tool. `--json` flag for machine output.

## For Claude: Using explicit

When an explicit server is running, use these to check code quality:

```bash
# Start server (if not running)
explicit watch

# After editing files
explicit violations --json

# Check specific file
explicit check /absolute/path/to/file.ex --json

# Server health
explicit status --json
```
