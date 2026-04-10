const std = @import("std");
const fs = std.fs;
const net = std.net;
const mem = std.mem;
const process = std.process;

fn stderr() fs.File.DeprecatedWriter {
    return fs.File.stderr().deprecatedWriter();
}

fn stdout() fs.File.DeprecatedWriter {
    return fs.File.stdout().deprecatedWriter();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Ensure our binary's directory is in PATH so hooks can find `explicit`
    ensureSelfInPath(allocator);

    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip argv[0]

    const command = args.next() orelse {
        printUsage();
        return;
    };

    // Collect remaining positional args + flags
    var json_output = false;
    var no_sandbox = false;
    var positional: [8]?[]const u8 = .{null} ** 8;
    var pos_count: usize = 0;

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (mem.eql(u8, arg, "--no-sandbox")) {
            no_sandbox = true;
        } else if (pos_count < 8) {
            positional[pos_count] = arg;
            pos_count += 1;
        }
    }

    const p0 = positional[0];
    const p1 = positional[1];
    const p2 = positional[2];

    // ─── Commands that don't need a running server ─────────────────────
    if (mem.eql(u8, command, "watch")) {
        try cmdWatch(allocator, json_output);
        return;
    } else if (mem.eql(u8, command, "hooks")) {
        try cmdHooks(allocator, p0, p1);
        return;
    } else if (mem.eql(u8, command, "claude")) {
        if (p0 != null and (mem.eql(u8, p0.?, "--help") or mem.eql(u8, p0.?, "-h"))) {
            stderr().writeAll(
                \\explicit claude — Launch Claude Code with explicit context
                \\
                \\Usage: explicit claude [flags] [-- claude-args...]
                \\
                \\Flags:
                \\  --no-sandbox    Skip nono sandbox for this session
                \\  -c              Continue last conversation
                \\  -p "prompt"     Start with a prompt
                \\
                \\Extra flags after explicit's own are passed to claude directly.
                \\
            ) catch {};
            return;
        }
        try cmdLaunchAI(allocator, "claude", .file_flag, &.{ "--dangerously-skip-permissions", "--append-system-prompt-file" }, positional[0..pos_count], no_sandbox);
        return;
    } else if (mem.eql(u8, command, "codex")) {
        if (p0 != null and (mem.eql(u8, p0.?, "--help") or mem.eql(u8, p0.?, "-h"))) {
            stderr().writeAll(
                \\explicit codex — Launch Codex with explicit context
                \\
                \\Usage: explicit codex [flags] [-- codex-args...]
                \\
                \\Flags:
                \\  --no-sandbox    Skip nono sandbox for this session
                \\
                \\Extra flags after explicit's own are passed to codex directly.
                \\
            ) catch {};
            return;
        }
        try cmdLaunchAI(allocator, "codex", .none, &.{}, positional[0..pos_count], no_sandbox);
        return;
    } else if (mem.eql(u8, command, "gemini")) {
        try cmdLaunchAI(allocator, "gemini", .text_flag, &.{ "--yolo", "-i" }, positional[0..pos_count], no_sandbox);
        return;
    } else if (mem.eql(u8, command, "opencode")) {
        if (p0 != null and (mem.eql(u8, p0.?, "--help") or mem.eql(u8, p0.?, "-h"))) {
            stderr().writeAll(
                \\explicit opencode — Launch OpenCode with explicit context
                \\
                \\Usage: explicit opencode [flags] [-- opencode-args...]
                \\
                \\Flags:
                \\  --no-sandbox    Skip nono sandbox for this session
                \\
                \\Extra flags after explicit's own are passed to opencode directly.
                \\
            ) catch {};
            return;
        }
        try cmdLaunchAI(allocator, "opencode", .none, &.{}, positional[0..pos_count], no_sandbox);
        return;
    } else if (mem.eql(u8, command, "init") and p0 != null and (mem.eql(u8, p0.?, "--help") or mem.eql(u8, p0.?, "-h"))) {
        stderr().writeAll(
            \\explicit init — Initialize explicit in a project
            \\
            \\Usage:
            \\  explicit init            Initialize explicit in the current project
            \\  explicit init <name>     Create a new project directory, then initialize it
            \\
        ) catch {};
        return;
    } else if (mem.eql(u8, command, "init") and p0 != null) {
        try cmdInitNew(allocator, p0.?);
        return;
    } else if (mem.eql(u8, command, "init")) {
        try cmdInitHere(allocator);
        return;
    } else if (mem.eql(u8, command, "help") or mem.eql(u8, command, "--help") or mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    } else if (mem.eql(u8, command, "version") or mem.eql(u8, command, "--version") or mem.eql(u8, command, "-v")) {
        stdout().writeAll("0.3.15\n") catch {};
        return;
    }

    // ─── Commands that send to the server ──────────────────────────────
    const request = try buildRequest(allocator, command, p0, p1, p2);
    defer if (request) |r| allocator.free(r);

    if (request) |req| {
        try cmdSend(allocator, req, json_output);
    } else {
        stderr().print("Unknown command: {s}\n", .{command}) catch {};
        printUsage();
        process.exit(1);
    }
}

/// Build a JSONL request string for the given command + args
fn buildRequest(allocator: mem.Allocator, command: []const u8, p0: ?[]const u8, p1: ?[]const u8, p2: ?[]const u8) !?[]const u8 {
    // Simple commands (no params)
    if (mem.eql(u8, command, "validate"))
        return try allocator.dupe(u8, "{\"method\":\"validate\"}\n");
    if (mem.eql(u8, command, "status"))
        return try allocator.dupe(u8, "{\"method\":\"status\"}\n");
    if (mem.eql(u8, command, "quality"))
        return try allocator.dupe(u8, "{\"method\":\"quality\"}\n");
    if (mem.eql(u8, command, "test"))
        return try allocator.dupe(u8, "{\"method\":\"test.run\"}\n");
    if (mem.eql(u8, command, "sarif"))
        return try allocator.dupe(u8, "{\"method\":\"sarif\"}\n");
    if (mem.eql(u8, command, "stop"))
        return try allocator.dupe(u8, "{\"method\":\"stop\"}\n");
    if (mem.eql(u8, command, "init")) {
        if (p0) |name| {
            // Pass CWD so server creates project relative to where user ran the command
            var cwd_buf: [fs.max_path_bytes]u8 = undefined;
            const cwd = try std.process.getCwd(&cwd_buf);
            return try std.fmt.allocPrint(allocator, "{{\"method\":\"init\",\"params\":{{\"name\":\"{s}\",\"dir\":\"{s}\"}}}}\n", .{ name, cwd });
        }
        return try allocator.dupe(u8, "{\"method\":\"init\"}\n");
    }

    // violations [file]
    if (mem.eql(u8, command, "violations")) {
        if (p0) |f|
            return try std.fmt.allocPrint(allocator, "{{\"method\":\"violations\",\"params\":{{\"file\":\"{s}\"}}}}\n", .{f});
        return try allocator.dupe(u8, "{\"method\":\"violations\"}\n");
    }

    // check <file>
    if (mem.eql(u8, command, "check")) {
        const f = p0 orelse {
            stderr().writeAll("Usage: explicit check <file>\n") catch {};
            process.exit(1);
        };
        return try std.fmt.allocPrint(allocator, "{{\"method\":\"check\",\"params\":{{\"file\":\"{s}\"}}}}\n", .{f});
    }

    // scaffold <name>
    if (mem.eql(u8, command, "scaffold")) {
        const name = p0 orelse {
            stderr().writeAll("Usage: explicit scaffold <name>\n") catch {};
            process.exit(1);
        };
        return try std.fmt.allocPrint(allocator, "{{\"method\":\"scaffold\",\"params\":{{\"name\":\"{s}\"}}}}\n", .{name});
    }

    // docs <subcmd> [arg]
    if (mem.eql(u8, command, "docs")) {
        return try buildDocsRequest(allocator, p0, p1, p2);
    }

    return null;
}

fn buildDocsRequest(allocator: mem.Allocator, p0: ?[]const u8, p1: ?[]const u8, p2: ?[]const u8) ![]const u8 {
    if (p0 != null and (mem.eql(u8, p0.?, "--help") or mem.eql(u8, p0.?, "-h"))) {
        stderr().writeAll(
            \\Usage: explicit docs <command>
            \\
            \\Commands:
            \\  validate       Validate all docs against schema
            \\  lint           Validate + graph health + fixme check
            \\  new <type>     Create new document (run with --help for details)
            \\  list [type]    List documents
            \\  get <id>       Show document details
            \\  describe       Show schema types
            \\  diagnostics    Show all diagnostics
            \\
        ) catch {};
        process.exit(0);
    }
    const subcmd = p0 orelse {
        stderr().writeAll("Usage: explicit docs <validate|new|list|get|describe|lint|diagnostics>\n") catch {};
        process.exit(1);
    };

    if (mem.eql(u8, subcmd, "validate"))
        return try allocator.dupe(u8, "{\"method\":\"doc.validate\"}\n");
    if (mem.eql(u8, subcmd, "lint"))
        return try allocator.dupe(u8, "{\"method\":\"doc.lint\"}\n");
    if (mem.eql(u8, subcmd, "diagnostics"))
        return try allocator.dupe(u8, "{\"method\":\"doc.diagnostics\"}\n");
    if (mem.eql(u8, subcmd, "describe")) {
        if (p1) |t|
            return try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.describe\",\"params\":{{\"type\":\"{s}\"}}}}\n", .{t});
        return try allocator.dupe(u8, "{\"method\":\"doc.describe\"}\n");
    }
    if (mem.eql(u8, subcmd, "list")) {
        if (p1) |t|
            return try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.list\",\"params\":{{\"type\":\"{s}\"}}}}\n", .{t});
        return try allocator.dupe(u8, "{\"method\":\"doc.list\"}\n");
    }
    if (mem.eql(u8, subcmd, "get")) {
        const id = p1 orelse {
            stderr().writeAll("Usage: explicit docs get <id>\n") catch {};
            process.exit(1);
        };
        return try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.get\",\"params\":{{\"id\":\"{s}\"}}}}\n", .{id});
    }
    if (mem.eql(u8, subcmd, "new")) {
        if (p1 != null and (mem.eql(u8, p1.?, "--help") or mem.eql(u8, p1.?, "-h"))) {
            stderr().writeAll(
                \\Usage: explicit docs new <type> [title]
                \\
                \\Create a new document of the given type.
                \\Type must match a typedef in your schema.kdl.
                \\
                \\Examples:
                \\  explicit docs new adr "Use PostgreSQL for storage"
                \\  explicit docs new opportunity "Improve crawler throughput"
                \\  explicit docs new incident "API outage 2026-04-06"
                \\
            ) catch {};
            process.exit(0);
        }
        const type_name = p1 orelse {
            stderr().writeAll("Usage: explicit docs new <type> [title]\n") catch {};
            process.exit(1);
        };
        const title_raw = p2 orelse "Untitled";
        // JSON-escape title: replace \ then " to avoid breaking the JSON string
        const title_bs = try std.mem.replaceOwned(u8, allocator, title_raw, "\\", "\\\\");
        defer allocator.free(title_bs);
        const title_escaped = try std.mem.replaceOwned(u8, allocator, title_bs, "\"", "\\\"");
        defer allocator.free(title_escaped);
        return try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.new\",\"params\":{{\"type\":\"{s}\",\"title\":\"{s}\"}}}}\n", .{ type_name, title_escaped });
    }

    stderr().print("Unknown docs command: {s}\n", .{subcmd}) catch {};
    process.exit(1);
}

fn printUsage() void {
    stderr().writeAll(
        \\explicit — Elixir code analysis + documentation tool
        \\
        \\Usage:
        \\  explicit init              Initialize explicit in current project
        \\  explicit scaffold <name>   Scaffold a full-stack Elixir monorepo
        \\  explicit watch             Start analysis server
        \\  explicit validate          Validate docs + code (blocks code_paths)
        \\  explicit status            Show server status
        \\  explicit quality           Quality gate report (tests, docs, lint)
        \\  explicit test              Run mix test
        \\  explicit violations [file] List code violations
        \\  explicit check <file>      Force re-check a file
        \\  explicit claude            Launch Claude Code with explicit context
        \\  explicit codex             Launch Codex with explicit context
        \\  explicit gemini            Launch Gemini CLI with explicit context
        \\  explicit opencode          Launch OpenCode with explicit context
        \\  explicit stop              Stop the server
        \\
        \\Document commands:
        \\  explicit docs validate     Validate all docs against schema
        \\  explicit docs lint         Validate + graph health + fixme check
        \\  explicit docs new <type>   Create new document
        \\  explicit docs list [type]  List documents
        \\  explicit docs get <id>     Show document details
        \\  explicit docs describe [type]  Describe schema types
        \\
        \\Flags:
        \\  --json                     Output raw JSON
        \\  --no-sandbox               Skip nono sandbox (claude/codex/gemini/opencode)
        \\
    ) catch {};
}

const PromptMode = enum {
    none,
    file_flag,
    text_flag,
};

/// Resolve our binary's directory and store it for child process env injection.
/// Hooks need `explicit` in PATH — this ensures it's available when launching claude.
var self_dir_buf: [fs.max_path_bytes]u8 = undefined;
var self_dir: ?[]const u8 = null;

fn ensureSelfInPath(_: mem.Allocator) void {
    const exe_path = std.fs.selfExePath(&self_dir_buf) catch return;
    self_dir = std.fs.path.dirname(exe_path);
}

// ─── Socket framing (packet: 4 — 4-byte big-endian length prefix) ──────────
// Matches the server's :gen_tcp.listen with `packet: 4`. Fixes the 8192-byte
// truncation bug documented in EXPLICIT-FEEDBACK.md #10.

const max_frame_size: u32 = 16 * 1024 * 1024; // 16 MB sanity cap

/// Read exactly buf.len bytes from the stream. Returns error on EOF.
fn readExact(stream: net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}

/// Send a length-prefixed frame: 4-byte BE length + payload.
fn sendFrame(stream: net.Stream, payload: []const u8) !void {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .big);
    try stream.writeAll(&hdr);
    try stream.writeAll(payload);
}

/// Receive a length-prefixed frame. Caller owns the returned slice.
fn recvFrame(allocator: mem.Allocator, stream: net.Stream) ![]u8 {
    var hdr: [4]u8 = undefined;
    try readExact(stream, &hdr);
    const len = std.mem.readInt(u32, &hdr, .big);
    if (len > max_frame_size) return error.FrameTooLarge;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try readExact(stream, buf);
    return buf;
}

/// Send a request frame and receive a response frame. Caller owns response.
fn sendRequest(allocator: mem.Allocator, stream: net.Stream, request: []const u8) ![]u8 {
    try sendFrame(stream, request);
    return try recvFrame(allocator, stream);
}

/// Get an env map with our binary's directory prepended to PATH
fn envWithSelfInPath(allocator: mem.Allocator) !std.process.EnvMap {
    var env = try std.process.getEnvMap(allocator);
    if (self_dir) |dir| {
        if (env.get("PATH")) |existing| {
            // Check if already in PATH
            var it = mem.splitScalar(u8, existing, ':');
            while (it.next()) |d| {
                if (mem.eql(u8, d, dir)) return env;
            }
            const new_path = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ dir, existing });
            defer allocator.free(new_path);
            try env.put("PATH", new_path);
        }
    }
    return env;
}

// ─── Hooks ───────────────────────────────────────────────────────────────────

fn cmdHooks(allocator: mem.Allocator, provider: ?[]const u8, hook_name: ?[]const u8) !void {
    const a = provider orelse {
        stderr().writeAll("Usage: explicit hooks <claude|codex|opencode|gemini> <stop|check-fixme|check-code>\n") catch {};
        stderr().writeAll("   or: explicit hooks <stop|check-fixme|check-code> <claude|codex|opencode|gemini>\n") catch {};
        process.exit(1);
    };
    const b = hook_name orelse {
        stderr().writeAll("Usage: explicit hooks <claude|codex|opencode|gemini> <stop|check-fixme|check-code>\n") catch {};
        stderr().writeAll("   or: explicit hooks <stop|check-fixme|check-code> <claude|codex|opencode|gemini>\n") catch {};
        process.exit(1);
    };

    var p = a;
    var h = b;
    if (isHookName(a) and isHookProvider(b)) {
        p = b;
        h = a;
    }

    if (!isHookProvider(p)) {
        stderr().print("Unknown hook provider: {s}\n", .{p}) catch {};
        process.exit(1);
    }

    if (mem.eql(u8, h, "stop")) {
        hookStop(allocator, p) catch |err| {
            stderr().print("[FAIL] Stop hook crashed: {s}\n", .{@errorName(err)}) catch {};
            process.exit(2);
        };
    } else if (mem.eql(u8, h, "check-fixme")) {
        try hookSendQuiet(allocator, "{\"method\":\"doc.check_fixme\"}\n");
    } else if (mem.eql(u8, h, "check-code")) {
        // Advisory — just exit clean for now
        process.exit(0);
    } else {
        stderr().print("Unknown hook: {s}\n", .{h}) catch {};
        process.exit(1);
    }
}

fn isHookProvider(value: []const u8) bool {
    return mem.eql(u8, value, "claude") or mem.eql(u8, value, "codex") or mem.eql(u8, value, "opencode") or mem.eql(u8, value, "gemini");
}

fn isHookName(value: []const u8) bool {
    return mem.eql(u8, value, "stop") or mem.eql(u8, value, "check-fixme") or mem.eql(u8, value, "check-code");
}

/// Stop hook: quality gate + auto-format + compile warnings
fn hookStop(allocator: mem.Allocator, provider: []const u8) !void {
    const git_root = findGitRoot(allocator) catch {
        stderr().writeAll("No git root found, skipping checks.\n") catch {};
        process.exit(0);
    };
    defer allocator.free(git_root);

    // Ensure server is running (auto-starts if needed)
    {
        var stream = connectToSocket(allocator) catch {
            stderr().writeAll("Could not start explicit server, skipping checks.\n") catch {};
            process.exit(0);
        };
        stream.close();
    }

    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    var has_issues = false;

    // Check quality (violations + doc errors + missing tests)
    has_issues = has_issues or try checkQuality(allocator, sock_path);

    // Find the mix project dir (services/*/ or project root)
    const mix_dir = findMixDir(allocator, git_root) orelse git_root;

    // Run mix test — keep stderr concise and actionable so the agent sees
    // the next task instead of a raw bootstrap/sandbox traceback.
    const test_log = "/tmp/explicit-mix-test.log";
    test_blk: {
        const cmd = std.fmt.allocPrint(
            allocator,
            "cd {s} && mix test > {s} 2>&1",
            .{ mix_dir, test_log },
        ) catch break :test_blk;
        defer allocator.free(cmd);
        var test_proc = std.process.Child.init(&.{ "bash", "-c", cmd }, allocator);
        test_proc.stdout_behavior = .Ignore;
        test_proc.stderr_behavior = .Ignore;
        var test_env = try std.process.getEnvMap(allocator);
        defer test_env.deinit();
        try test_env.put("MIX_ENV", "test");
        test_proc.env_map = &test_env;
        _ = test_proc.spawn() catch break :test_blk;
        const test_term = test_proc.wait() catch break :test_blk;
        if (test_term.Exited != 0) {
            const content = readLogFile(allocator, test_log, 512 * 1024) orelse "";
            defer if (content.len > 0) allocator.free(content);
            printMixFailureSummary(allocator, "Tests", "mix test", mix_dir, test_log, content);
            has_issues = true;
        }
    }

    // Auto-format (don't ask Claude, just do it)
    {
        var fmt = std.process.Child.init(&.{ "mix", "format" }, allocator);
        fmt.cwd = mix_dir;
        fmt.stdout_behavior = .Ignore;
        fmt.stderr_behavior = .Ignore;
        _ = fmt.spawn() catch {};
        _ = fmt.wait() catch {};
    }

    // Compile with warnings-as-errors — redirect output to log file to avoid
    // pipe deadlock on verbose output. Same pattern as mix test above.
    const compile_log = "/tmp/explicit-mix-compile.log";
    compile_blk: {
        const cmd = std.fmt.allocPrint(
            allocator,
            "cd {s} && mix compile --warnings-as-errors > {s} 2>&1",
            .{ mix_dir, compile_log },
        ) catch break :compile_blk;
        defer allocator.free(cmd);
        var compile = std.process.Child.init(&.{ "bash", "-c", cmd }, allocator);
        compile.stdout_behavior = .Ignore;
        compile.stderr_behavior = .Ignore;
        _ = compile.spawn() catch break :compile_blk;
        const term = compile.wait() catch break :compile_blk;
        if (term.Exited != 0) {
            const content = readLogFile(allocator, compile_log, 256 * 1024) orelse "";
            defer if (content.len > 0) allocator.free(content);
            printMixFailureSummary(allocator, "Compile", "mix compile --warnings-as-errors", mix_dir, compile_log, content);
            has_issues = true;
        }
    }

    // Validate OpenTofu if infra/ is initialized (skip if tofu init hasn't been run)
    {
        const infra_dir = try std.fmt.allocPrint(allocator, "{s}/infra", .{git_root});
        defer allocator.free(infra_dir);
        const tf_dir = try std.fmt.allocPrint(allocator, "{s}/infra/.terraform", .{git_root});
        defer allocator.free(tf_dir);
        if (fs.accessAbsolute(tf_dir, .{})) {
            const tofu_log = "/tmp/explicit-tofu-validate.log";
            const cmd = std.fmt.allocPrint(
                allocator,
                "cd {s} && tofu validate > {s} 2>&1",
                .{ infra_dir, tofu_log },
            ) catch "";
            defer if (cmd.len > 0) allocator.free(cmd);
            if (cmd.len == 0) {
                has_issues = true;
            } else {
                var validate = std.process.Child.init(&.{ "bash", "-c", cmd }, allocator);
                validate.stdout_behavior = .Ignore;
                validate.stderr_behavior = .Ignore;
                _ = validate.spawn() catch {};
                if (validate.wait()) |term| {
                    if (term.Exited != 0) {
                        const content = readLogFile(allocator, tofu_log, 256 * 1024) orelse "";
                        defer if (content.len > 0) allocator.free(content);
                        printTofuFailureSummary(allocator, infra_dir, tofu_log, content);
                        has_issues = true;
                    }
                } else |_| {}
            }
        } else |_| {}
    }

    if (has_issues) {
        // Safeguard: Claude Code collapses Stop hook display to the first
        // stderr line and hides hooks with zero stderr output as "no output".
        // If we got here via a check that failed without writing anything
        // (e.g. a bug in one of the blocks above), make sure Claude sees
        // SOMETHING actionable rather than an empty "No stderr output" box.
        stderr().print("explicit hooks {s} stop: issues found (exit 2). Run `explicit quality --json` + `mix test` to see details.\n", .{provider}) catch {};
        process.exit(2);
    }
    stderr().writeAll("All checks passed.\n") catch {};
    process.exit(0);
}

fn readLogFile(allocator: mem.Allocator, path: []const u8, max_bytes: usize) ?[]const u8 {
    const file = fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes) catch null;
}

fn printMixFailureSummary(
    allocator: mem.Allocator,
    phase: []const u8,
    rerun_cmd: []const u8,
    mix_dir: []const u8,
    log_path: []const u8,
    content: []const u8,
) void {
    _ = allocator;
    const err = stderr();
    err.print("{s}: FAILED\n", .{phase}) catch {};

    var explained = false;

    if (mem.indexOf(u8, content, "Mix requires the Hex package manager") != null) {
        err.writeAll("Action: install Hex before running Mix tasks.\n") catch {};
        err.print("Run: cd {s} && mix local.hex --force\n", .{mix_dir}) catch {};
        explained = true;
    }

    if (mem.indexOf(u8, content, "Could not find an SCM for dependency") != null or
        mem.indexOf(u8, content, "Unchecked dependencies for environment") != null or
        mem.indexOf(u8, content, "dependency is not available") != null)
    {
        err.writeAll("Action: fetch Elixir dependencies before retrying.\n") catch {};
        err.print("Run: cd {s} && mix deps.get\n", .{mix_dir}) catch {};
        explained = true;
    }

    if (mem.indexOf(u8, content, "No package with name") != null and mem.indexOf(u8, content, "Hex") != null) {
        err.writeAll("Action: Hex is installed but the package index is missing or stale.\n") catch {};
        err.print("Run: cd {s} && mix local.hex --force && mix deps.get\n", .{mix_dir}) catch {};
        explained = true;
    }

    if (!explained) {
        err.print("Action: rerun the failing command directly and fix the reported error.\nRun: cd {s} && {s}\n", .{ mix_dir, rerun_cmd }) catch {};
    }

    printRelevantLogLines(content, 10);
    err.print("Full log: {s}\n", .{log_path}) catch {};
}

fn printTofuFailureSummary(
    allocator: mem.Allocator,
    infra_dir: []const u8,
    log_path: []const u8,
    content: []const u8,
) void {
    _ = allocator;
    const err = stderr();
    err.writeAll("OpenTofu: FAILED\n") catch {};

    var explained = false;

    if (mem.indexOf(u8, content, ".terraform.d") != null and mem.indexOf(u8, content, "operation not permitted") != null) {
        err.writeAll("Action: OpenTofu could not read ~/.terraform.d inside the sandbox.\n") catch {};
        err.writeAll("Either grant access to ~/.terraform.d, or bypass global config for this repo-local validation.\n") catch {};
        err.print("Run: cd {s} && TF_CLI_CONFIG_FILE=/dev/null tofu init && TF_CLI_CONFIG_FILE=/dev/null tofu validate\n", .{infra_dir}) catch {};
        explained = true;
    }

    if (mem.indexOf(u8, content, "failed to verify checksum") != null or
        mem.indexOf(u8, content, "provider") != null and mem.indexOf(u8, content, "operation not permitted") != null)
    {
        err.writeAll("Action: the cached OpenTofu provider state is unusable in this environment.\n") catch {};
        err.print("Run: cd {s} && rm -rf .terraform && TF_CLI_CONFIG_FILE=/dev/null tofu init && TF_CLI_CONFIG_FILE=/dev/null tofu validate\n", .{infra_dir}) catch {};
        explained = true;
    }

    if (mem.indexOf(u8, content, "Missing required provider") != null or
        mem.indexOf(u8, content, "Inconsistent dependency lock file") != null or
        mem.indexOf(u8, content, "Module not installed") != null)
    {
        err.writeAll("Action: initialize infra dependencies before validating.\n") catch {};
        err.print("Run: cd {s} && tofu init && tofu validate\n", .{infra_dir}) catch {};
        explained = true;
    }

    if (!explained) {
        err.print("Action: rerun OpenTofu directly and fix the reported error.\nRun: cd {s} && tofu validate\n", .{infra_dir}) catch {};
    }

    printRelevantLogLines(content, 10);
    err.print("Full log: {s}\n", .{log_path}) catch {};
}

fn printRelevantLogLines(content: []const u8, max_lines: usize) void {
    const err = stderr();
    var lines = mem.splitScalar(u8, content, '\n');
    var shown: usize = 0;

    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        if (mem.indexOf(u8, trimmed, "**") != null or
            mem.indexOf(u8, trimmed, "Error") != null or
            mem.indexOf(u8, trimmed, "error") != null or
            mem.indexOf(u8, trimmed, "FAILED") != null or
            mem.indexOf(u8, trimmed, "failed") != null or
            mem.indexOf(u8, trimmed, "Permission") != null or
            mem.indexOf(u8, trimmed, "permission") != null or
            mem.indexOf(u8, trimmed, "Hex") != null or
            mem.indexOf(u8, trimmed, "SCM") != null or
            mem.indexOf(u8, trimmed, "dependency") != null or
            mem.indexOf(u8, trimmed, "provider") != null)
        {
            err.print("  {s}\n", .{trimmed}) catch {};
            shown += 1;
            if (shown >= max_lines) break;
        }
    }

    if (shown > 0) return;

    var start: usize = content.len;
    var nl: usize = 0;
    while (start > 0 and nl < max_lines) : (start -= 1) {
        if (content[start - 1] == '\n') nl += 1;
    }

    if (start < content.len) {
        err.writeAll(mem.trim(u8, content[start..], "\n")) catch {};
        err.writeAll("\n") catch {};
    }
}

/// Check quality and output concise summary to stderr. Returns true if issues found.
fn checkQuality(allocator: mem.Allocator, sock_path: []const u8) !bool {
    var stream = net.connectUnixSocket(sock_path) catch {
        return false;
    };
    defer stream.close();

    // Set 30s read timeout for quality check
    const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    const response = sendRequest(allocator, stream, "{\"method\":\"quality\"}") catch {
        stderr().writeAll("Quality check: server not responding.\n") catch {};
        return true;
    };
    defer allocator.free(response);
    if (mem.indexOf(u8, response, "\"clean\":true") != null) return false;

    // Output concise, actionable summary to stderr (what Claude sees).
    // Fixes EXPLICIT-FEEDBACK.md #7: the old message just said a count
    // and pointed at `explicit violations`, which doesn't show doc errors.
    // Now we inline file paths + codes + messages and point at the right
    // follow-up command per category.
    const err = stderr();

    // Count non-zero categories
    const iron = extractJsonInt(response, "\"iron_law_violations\":") orelse 0;
    const docs = extractJsonInt(response, "\"missing_docs\":") orelse 0;
    const doc_errs = extractJsonInt(response, "\"doc_errors\":") orelse 0;

    err.writeAll("Quality issues: ") catch {};
    var sep: bool = false;
    if (iron > 0) {
        err.print("{d} code violations", .{iron}) catch {};
        sep = true;
    }
    if (docs > 0) {
        if (sep) err.writeAll(", ") catch {};
        err.print("{d} missing @doc", .{docs}) catch {};
        sep = true;
    }
    if (doc_errs > 0) {
        if (sep) err.writeAll(", ") catch {};
        err.print("{d} doc errors", .{doc_errs}) catch {};
    }
    err.writeAll("\n") catch {};

    // Walk the `files` array from the quality response. Each entry is either:
    //   - a doc-error entry: {file, code, message, id?}
    //   - a code-file entry: {file, mtime, count, issues: {...}}
    // We print whichever fields are present, capping at 10 items.
    const files_marker = "\"files\":[";
    if (mem.indexOf(u8, response, files_marker)) |files_pos| {
        const body = response[files_pos + files_marker.len ..];
        var idx: usize = 0;
        var shown: u32 = 0;
        while (idx < body.len and shown < 10) {
            // Stop if we hit the end of the array
            while (idx < body.len and (body[idx] == ',' or body[idx] == ' ')) : (idx += 1) {}
            if (idx >= body.len or body[idx] == ']') break;
            if (body[idx] != '{') break;

            // Find matching '}' — the objects are flat except for the
            // `issues` sub-object. Count braces.
            var depth: u32 = 0;
            var obj_end: usize = idx;
            while (obj_end < body.len) : (obj_end += 1) {
                if (body[obj_end] == '{') depth += 1;
                if (body[obj_end] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (obj_end >= body.len) break;

            const obj = body[idx .. obj_end + 1];
            const file = extractJsonString(obj, "\"file\":\"") orelse "";
            const code = extractJsonString(obj, "\"code\":\"");
            const message = extractJsonString(obj, "\"message\":\"");
            const count = extractJsonInt(obj, "\"count\":");

            if (code) |c| {
                // Doc-error entry
                err.print("  {s}  {s}  {s}\n", .{ file, c, message orelse "" }) catch {};
            } else if (count) |n| {
                // Code-file entry (aggregated per file)
                err.print("  {s}  ({d} issue(s))\n", .{ file, n }) catch {};
            } else {
                err.print("  {s}\n", .{file}) catch {};
            }

            shown += 1;
            idx = obj_end + 1;
        }
    }

    // Context-aware follow-up commands
    if (doc_errs > 0) err.writeAll("Fix doc errors: explicit docs validate\n") catch {};
    if (iron > 0) err.writeAll("Fix code violations: explicit violations --json\n") catch {};
    if (docs > 0) err.writeAll("Add missing @doc attributes to the flagged public functions.\n") catch {};

    return true;
}

/// Send method, check if response contains the "clean" marker. Returns true if issues found.
/// Output goes to stderr (for stop hook visibility).
fn checkMethod(allocator: mem.Allocator, sock_path: []const u8, request: []const u8, clean_marker: []const u8) !bool {
    var stream = net.connectUnixSocket(sock_path) catch {
        stderr().writeAll("Test check: could not connect to server.\n") catch {};
        return true;
    };
    defer stream.close();

    // Set 120s read timeout (mix test --cover can be slow)
    const timeout = std.posix.timeval{ .sec = 120, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    const response = sendRequest(allocator, stream, request) catch {
        stderr().writeAll("Test check: server communication failed or timed out.\n") catch {};
        return true;
    };
    defer allocator.free(response);
    if (mem.indexOf(u8, response, clean_marker) != null) return false;
    // Output test results to stderr so stop hook sees them
    const err = stderr();
    if (mem.indexOf(u8, response, "\"passed\":false") != null or mem.indexOf(u8, response, "\"passed\":true") == null) {
        err.writeAll("Tests: FAILED\n") catch {};
    }
    if (extractJsonInt(response, "\"tests\":")) |t| err.print("  Total: {d}\n", .{t}) catch {};
    if (extractJsonInt(response, "\"failures\":")) |f| {
        if (f > 0) err.print("  Failures: {d}\n", .{f}) catch {};
    }
    if (mem.indexOf(u8, response, "\"coverage\":")) |pos| {
        const start = pos + "\"coverage\":".len;
        var end: usize = start;
        while (end < response.len and response[end] != ',' and response[end] != '}') : (end += 1) {}
        if (end > start) {
            const cov_str = mem.trim(u8, response[start..end], " ");
            if (!mem.eql(u8, cov_str, "null")) {
                err.print("  Coverage: {s}%\n", .{cov_str}) catch {};
            }
        }
    }
    if (mem.indexOf(u8, response, "\"coverage_below_threshold\":true") != null) {
        err.writeAll("  Coverage below threshold!\n") catch {};
    }
    return true;
}

/// Send a method to server, output to stderr if non-empty result, exit 0 (advisory)
fn hookSendQuiet(allocator: mem.Allocator, request: []const u8) !void {
    const git_root = findGitRoot(allocator) catch {
        process.exit(0);
    };
    defer allocator.free(git_root);
    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    var stream = net.connectUnixSocket(sock_path) catch {
        process.exit(0);
    };
    defer stream.close();

    const response = sendRequest(allocator, stream, request) catch {
        process.exit(0);
    };
    defer allocator.free(response);
    if (mem.indexOf(u8, response, "\"total\":0") == null) {
        stderr().writeAll(response) catch {};
        stderr().writeAll("\n") catch {};
    }
    process.exit(0);
}

// ─── Init new project ────────────────────────────────────────────────────────

fn cmdInitNew(allocator: mem.Allocator, name: []const u8) !void {
    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&cwd_buf) catch {
        stderr().writeAll("Error: Cannot get current directory\n") catch {};
        process.exit(1);
    };

    const project_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, name });
    defer allocator.free(project_dir);

    var project_exists = true;
    fs.accessAbsolute(project_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            project_exists = false;
            fs.makeDirAbsolute(project_dir) catch {
                stderr().print("Error: Cannot create directory {s}\n", .{name}) catch {};
                process.exit(1);
            };
        },
        else => {
            stderr().print("Error: Cannot access directory {s}\n", .{name}) catch {};
            process.exit(1);
        },
    };

    const overwrites = try collectInitOverwrites(allocator, project_dir);
    defer freeOwnedStrings(allocator, overwrites);

    stderr().print("Creating {s}...\n", .{name}) catch {};

    // git init + devenv init (creates devenv.yaml + bootstrap files)
    runIn(allocator, project_dir, &.{ "git", "init" });
    if (!project_exists or !fileExistsAbsolute(allocator, project_dir, "devenv.yaml")) {
        runIn(allocator, project_dir, &.{ "devenv", "init" });
    }

    // Start server for the new project and run init (schema, hooks, skills)
    const server_bin = findServerBinary(allocator) catch null;
    if (server_bin) |bin| {
        defer allocator.free(bin);

        stderr().writeAll("Starting server...\n") catch {};

        var child = std.process.Child.init(&.{ bin, "daemon" }, allocator);
        child.pgid = 0;
        var env = std.process.getEnvMap(allocator) catch unreachable;
        defer env.deinit();
        env.put("EXPLICIT_PROJECT_DIR", project_dir) catch {};
        child.env_map = &env;
        _ = child.spawn() catch {
            stderr().print(
                "Created {s}/ (server not available — run 'explicit init' inside to finish setup)\nNext:\n  cd {s}\n  explicit init\n  opencode\n  codex\n  explicit claude\n  explicit gemini\n",
                .{ name, name },
            ) catch {};
            return;
        };

        // Wait for socket
        const new_sock = socketPathForDir(allocator, project_dir) catch {
            stderr().print("Created {s}/\n", .{name}) catch {};
            return;
        };
        defer allocator.free(new_sock);

        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            if (net.connectUnixSocket(new_sock)) |stream| {
                // Send init command
                const req = try buildInitRequestWithOverwrites(allocator, project_dir, null, overwrites);
                defer allocator.free(req);
                if (sendRequest(allocator, stream, req)) |response| {
                    defer allocator.free(response);
                    try printHuman(response);
                } else |_| {}
                stream.close();

                // Stop server
                if (net.connectUnixSocket(new_sock)) |s2| {
                    sendFrame(s2, "{\"method\":\"stop\"}") catch {};
                    s2.close();
                } else |_| {}

                stderr().print(
                    "\nReady! Next:\n  cd {s}\n  opencode\n  codex\n  explicit claude\n  explicit gemini\n",
                    .{name},
                ) catch {};
                return;
            } else |_| {}
        }

        stderr().print(
            "Created {s}/ (server timed out — run 'explicit init' inside to finish)\nNext:\n  cd {s}\n  explicit init\n  opencode\n  codex\n  explicit claude\n  explicit gemini\n",
            .{ name, name },
        ) catch {};
    } else {
        stderr().print(
            "Created {s}/\nNext:\n  cd {s}\n  explicit init\n  opencode\n  codex\n  explicit claude\n  explicit gemini\n",
            .{ name, name },
        ) catch {};
    }
}

fn cmdInitHere(allocator: mem.Allocator) !void {
    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&cwd_buf) catch {
        stderr().writeAll("Error: Cannot get current directory\n") catch {};
        process.exit(1);
    };

    const overwrites = try collectInitOverwrites(allocator, cwd);
    defer freeOwnedStrings(allocator, overwrites);

    var stream = try connectToSocket(allocator);
    defer stream.close();

    const req = try buildInitRequestWithOverwrites(allocator, cwd, null, overwrites);
    defer allocator.free(req);

    const response = sendRequest(allocator, stream, req) catch |err| {
        stderr().print("Error: server communication failed: {s}\n", .{@errorName(err)}) catch {};
        process.exit(1);
    };
    defer allocator.free(response);

    try printHuman(response);
}

fn collectInitOverwrites(allocator: mem.Allocator, project_dir: []const u8) ![][]const u8 {
    const managed = [_][]const u8{
        ".explicit/org.kdl",
        ".claude/settings.json",
        ".codex/hooks.json",
        ".codex/config.toml",
        ".gemini/settings.json",
        "opencode.json",
        ".opencode/plugins/explicit.js",
        ".claude/skills/adr/skill.md",
        ".claude/skills/opportunity/skill.md",
        ".claude/skills/incident/skill.md",
        ".claude/skills/spec/skill.md",
        ".claude/skills/test/skill.md",
        ".claude/skills/elixir-quality/skill.md",
        ".claude/skills/phoenix-patterns/skill.md",
        "README.md",
        "CLAUDE.md",
        "GEMINI.md",
        ".agents/AGENTS.md",
        "AGENTS.md",
        ".lsp.json",
        "devenv.nix",
        "devenv.yaml",
        "infra/main.tf",
        "infra/.gitignore",
        ".vscode/extensions.json",
        ".vscode/settings.json",
    };

    var chosen = std.ArrayList([]const u8){};
    defer chosen.deinit(allocator);
    var overwrite_all = false;

    for (managed) |rel_path| {
        if (!fileExistsAbsolute(allocator, project_dir, rel_path)) continue;

        if (overwrite_all) {
            try chosen.append(allocator, try allocator.dupe(u8, rel_path));
            continue;
        }

        while (true) {
            stderr().print("Overwrite existing {s}? [y/N/a/q] ", .{rel_path}) catch {};
            const answer = try readPromptReply();

            if (answer == 'y' or answer == 'Y') {
                try chosen.append(allocator, try allocator.dupe(u8, rel_path));
                break;
            }
            if (answer == 'a' or answer == 'A') {
                overwrite_all = true;
                try chosen.append(allocator, try allocator.dupe(u8, rel_path));
                break;
            }
            if (answer == 'q' or answer == 'Q') process.exit(1);
            if (answer == 'n' or answer == 'N' or answer == '\n' or answer == '\r' or answer == 0) break;
        }
    }

    return chosen.toOwnedSlice(allocator);
}

fn readPromptReply() !u8 {
    const stdin_file = std.fs.File.stdin();
    var one: [1]u8 = undefined;
    const first_len = stdin_file.read(&one) catch return 0;
    if (first_len == 0) return 0;
    const first = one[0];

    if (first != '\n' and first != '\r') {
        while (true) {
            const next_len = stdin_file.read(&one) catch break;
            if (next_len == 0 or one[0] == '\n') break;
        }
    }

    return first;
}

fn fileExistsAbsolute(allocator: mem.Allocator, base_dir: []const u8, rel_path: []const u8) bool {
    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, rel_path }) catch return false;
    defer allocator.free(full);
    fs.accessAbsolute(full, .{}) catch return false;
    return true;
}

fn freeOwnedStrings(allocator: mem.Allocator, items: [][]const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn buildInitRequestWithOverwrites(allocator: mem.Allocator, dir: []const u8, name: ?[]const u8, overwrite_paths: [][]const u8) ![]const u8 {
    const dir_escaped = try escapeJsonString(allocator, dir);
    defer allocator.free(dir_escaped);

    var overwrite_json = std.ArrayList(u8){};
    defer overwrite_json.deinit(allocator);
    try overwrite_json.append(allocator, '[');
    for (overwrite_paths, 0..) |path, idx| {
        if (idx > 0) try overwrite_json.append(allocator, ',');
        const escaped = try escapeJsonString(allocator, path);
        defer allocator.free(escaped);
        try overwrite_json.writer(allocator).print("\"{s}\"", .{escaped});
    }
    try overwrite_json.append(allocator, ']');

    if (name) |n| {
        const name_escaped = try escapeJsonString(allocator, n);
        defer allocator.free(name_escaped);
        return try std.fmt.allocPrint(allocator, "{{\"method\":\"init\",\"params\":{{\"name\":\"{s}\",\"dir\":\"{s}\",\"overwrite_paths\":{s}}}}}\n", .{ name_escaped, dir_escaped, overwrite_json.items });
    }

    return try std.fmt.allocPrint(allocator, "{{\"method\":\"init\",\"params\":{{\"dir\":\"{s}\",\"overwrite_paths\":{s}}}}}\n", .{ dir_escaped, overwrite_json.items });
}

fn escapeJsonString(allocator: mem.Allocator, value: []const u8) ![]const u8 {
    const bs = try std.mem.replaceOwned(u8, allocator, value, "\\", "\\\\");
    defer allocator.free(bs);
    return try std.mem.replaceOwned(u8, allocator, bs, "\"", "\\\"");
}

fn runIn(allocator: mem.Allocator, dir: []const u8, argv: []const []const u8) void {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = dir;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return;
    _ = child.wait() catch return;
}

// ─── AI launcher ─────────────────────────────────────────────────────────────

fn cmdLaunchAI(allocator: mem.Allocator, tool_name: []const u8, prompt_mode: PromptMode, prompt_flag: []const []const u8, extra_args: []const ?[]const u8, no_sandbox: bool) !void {
    if (!binaryInPath(allocator, "rtk")) {
        stderr().print("Error: `rtk` is required to launch explicit {s}. Install rtk and try again.\n", .{tool_name}) catch {};
        stderr().writeAll("See: https://github.com/rtk-ai/rtk#installation\n") catch {};
        process.exit(1);
    }

    var prompt_arg: ?[]const u8 = null;
    var unescaped: ?[]u8 = null;
    defer if (unescaped) |buf| allocator.free(buf);

    if (prompt_mode != .none) {
        // 1. Connect to server (auto-starts if needed)
        var stream = try connectToSocket(allocator);

        // 2. Fetch system prompt
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"system_prompt\",\"params\":{{\"tool\":\"{s}\"}}}}", .{tool_name});
        defer allocator.free(req);

        const response = sendRequest(allocator, stream, req) catch |err| {
            stderr().print("Error: server communication failed: {s}\n", .{@errorName(err)}) catch {};
            process.exit(1);
        };
        defer allocator.free(response);
        stream.close();

        // 3. Extract prompt text from JSON response
        const prompt = extractJsonString(response, "\"prompt\":\"") orelse {
            stderr().writeAll("Error: Could not extract system prompt\n") catch {};
            process.exit(1);
        };

        // Unescape \\n to real newlines and optionally drop sandbox instructions.
        unescaped = try std.mem.replaceOwned(u8, allocator, prompt, "\\n", "\n");

        if (prompt_mode == .text_flag) {
            prompt_arg = unescaped.?;
        } else {
            const prompt_path = "/tmp/explicit-system-prompt.txt";
            const f = try fs.createFileAbsolute(prompt_path, .{});
            defer f.close();
            try f.writeAll(unescaped.?);
            prompt_arg = prompt_path;
        }
    }

    // If devenv.nix exists but we're not inside devenv shell, re-exec through devenv
    const devenv_dir = findDevenvDir(allocator);
    defer if (devenv_dir) |d| allocator.free(d);
    const devenv_root = std.process.getEnvVarOwned(allocator, "DEVENV_ROOT") catch null;
    defer if (devenv_root) |v| allocator.free(v);
    const in_nix_shell = std.process.getEnvVarOwned(allocator, "IN_NIX_SHELL") catch null;
    defer if (in_nix_shell) |v| allocator.free(v);
    const in_devenv = devenv_root != null or in_nix_shell != null;

    if (devenv_dir) |d| {
        if (!in_devenv) {
            // Verify devenv shell works; if stale lock, auto-update
            {
                var probe = std.process.Child.init(&.{ "devenv", "shell", "--", "true" }, allocator);
                probe.cwd = d;
                probe.stdout_behavior = .Ignore;
                probe.stderr_behavior = .Ignore;
                if (probe.spawn()) |_| {
                    const pt = probe.wait() catch null;
                    if (pt == null or pt.?.Exited != 0) {
                        stderr().writeAll("devenv shell failed, clearing cache + updating...\n") catch {};
                        const cache_path = std.fmt.allocPrint(allocator, "{s}/.devenv/nix-eval-cache.db", .{d}) catch null;
                        if (cache_path) |cp| {
                            fs.deleteFileAbsolute(cp) catch {};
                            allocator.free(cp);
                        }
                        var upd = std.process.Child.init(&.{ "devenv", "update" }, allocator);
                        upd.cwd = d;
                        upd.stdout_behavior = .Inherit;
                        upd.stderr_behavior = .Inherit;
                        _ = upd.spawn() catch {};
                        _ = upd.wait() catch {};
                    }
                } else |_| {}
            }

            // Start devenv services BEFORE entering shell (avoids cache conflicts)
            {
                stderr().writeAll("Starting devenv services...\n") catch {};
                var up = std.process.Child.init(&.{ "devenv", "up", "--detach" }, allocator);
                up.cwd = d;
                up.stdout_behavior = .Ignore;
                up.stderr_behavior = .Pipe;
                var up_ok = false;
                if (up.spawn()) |_| {
                    const up_term = up.wait() catch null;
                    if (up_term) |t| {
                        if (t.Exited == 0) {
                            up_ok = true;
                        } else {
                            if (up.stderr) |pipe| {
                                var ubuf: [2048]u8 = undefined;
                                const un = pipe.read(&ubuf) catch 0;
                                if (un > 0) stderr().writeAll(ubuf[0..un]) catch {};
                            }
                        }
                    }
                } else |_| {}

                // Wait for services to be healthy (postgres etc.)
                if (up_ok) {
                    stderr().writeAll("Waiting for devenv services to be ready...\n") catch {};
                    var wait_proc = std.process.Child.init(&.{ "devenv", "processes", "wait", "--timeout", "60" }, allocator);
                    wait_proc.cwd = d;
                    wait_proc.stdout_behavior = .Ignore;
                    wait_proc.stderr_behavior = .Inherit;
                    _ = wait_proc.spawn() catch {};
                    _ = wait_proc.wait() catch {};
                }
            }

            // Re-exec ourselves inside devenv shell (interactive, with watcher)
            stderr().print("Entering devenv shell from {s}...\n", .{d}) catch {};

            // Get path to this binary
            var exe_buf2: [fs.max_path_bytes]u8 = undefined;
            const self_path = std.fs.selfExePath(&exe_buf2) catch {
                stderr().writeAll("Error: cannot find self path\n") catch {};
                process.exit(1);
            };

            // Build: devenv shell -- /path/to/explicit claude [extra_args...]
            var reexec_buf: [24][]const u8 = undefined;
            var rc: usize = 0;
            reexec_buf[rc] = "devenv";
            rc += 1;
            reexec_buf[rc] = "shell";
            rc += 1;
            reexec_buf[rc] = "--";
            rc += 1;
            reexec_buf[rc] = self_path;
            rc += 1;
            reexec_buf[rc] = tool_name;
            rc += 1;
            if (no_sandbox) {
                reexec_buf[rc] = "--no-sandbox";
                rc += 1;
            }
            // Pass through extra args
            for (extra_args) |ea| {
                if (ea) |a| {
                    if (rc < reexec_buf.len) {
                        reexec_buf[rc] = a;
                        rc += 1;
                    }
                }
            }

            var reexec = std.process.Child.init(reexec_buf[0..rc], allocator);
            reexec.stdin_behavior = .Inherit;
            reexec.stdout_behavior = .Inherit;
            reexec.stderr_behavior = .Inherit;
            reexec.cwd = d;
            // Ensure our binary dir is in PATH for hooks inside devenv shell
            var reexec_env = try envWithSelfInPath(allocator);
            defer reexec_env.deinit();
            reexec.env_map = &reexec_env;
            _ = try reexec.spawn();
            const rt = try reexec.wait();
            process.exit(rt.Exited);
        }
    }

    // Check if expert LSP is available
    {
        var check = std.process.Child.init(&.{ "expert", "--version" }, allocator);
        check.stdout_behavior = .Ignore;
        check.stderr_behavior = .Ignore;
        const has_expert = if (check.spawn()) |_| blk2: {
            const t = check.wait() catch break :blk2 false;
            break :blk2 t.Exited == 0;
        } else |_| false;

        if (!has_expert) {
            stderr().writeAll("Warning: expert LSP not found. Install: brew install expert\n") catch {};
        }
    }

    // Check if nono is available (skip if --no-sandbox)
    const has_nono = if (no_sandbox) false else blk: {
        var check = std.process.Child.init(&.{ "nono", "--version" }, allocator);
        check.stdout_behavior = .Ignore;
        check.stderr_behavior = .Ignore;
        _ = check.spawn() catch break :blk false;
        const t = check.wait() catch break :blk false;
        break :blk t.Exited == 0;
    };

    if (no_sandbox) {
        stderr().print("Starting {s} (sandbox disabled)...\n", .{tool_name}) catch {};
    } else if (has_nono) {
        stderr().print("Starting {s} with nono sandbox...\n", .{tool_name}) catch {};
    } else {
        stderr().print("Starting {s}...\n", .{tool_name}) catch {};
        stderr().writeAll("Warning: nono not found, running without sandbox. Install: brew install nono\n") catch {};
    }

    // Build argv: [nono wrap --profile <tool> --allow . --] tool [flags] [prompt]
    var argv_buf: [64][]const u8 = undefined;
    var argc: usize = 0;

    if (has_nono) {
        argv_buf[argc] = "nono";
        argc += 1;
        argv_buf[argc] = "wrap";
        argc += 1;
        argv_buf[argc] = "--profile";
        argc += 1;
        argv_buf[argc] = nonoProfileForTool(tool_name);
        argc += 1;
        // Expand $HOME for paths nono needs
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
        const mix_home = try std.fmt.allocPrint(allocator, "{s}/.mix", .{home});
        const terraform_home = try std.fmt.allocPrint(allocator, "{s}/.terraform.d", .{home});
        const cargo_home = try std.fmt.allocPrint(allocator, "{s}/.cargo", .{home});
        const rustup_home = try std.fmt.allocPrint(allocator, "{s}/.rustup", .{home});
        const go_path = try std.fmt.allocPrint(allocator, "{s}/go", .{home});
        const go_cache = try std.fmt.allocPrint(allocator, "{s}/Library/Caches/go-build", .{home});
        const mcp_json = try std.fmt.allocPrint(allocator, "{s}/.mcp.json", .{home});
        const shell_profile = try std.fmt.allocPrint(allocator, "{s}/.profile", .{home});

        if (binaryInPath(allocator, "mix")) {
            argv_buf[argc] = "--allow";
            argc += 1;
            argv_buf[argc] = mix_home;
            argc += 1;
        }

        if (binaryInPath(allocator, "tofu") or binaryInPath(allocator, "terraform")) {
            argv_buf[argc] = "--allow";
            argc += 1;
            argv_buf[argc] = terraform_home;
            argc += 1;
        }

        if (binaryInPath(allocator, "cargo") or binaryInPath(allocator, "rustc") or binaryInPath(allocator, "rustup")) {
            argv_buf[argc] = "--allow";
            argc += 1;
            argv_buf[argc] = cargo_home;
            argc += 1;
            argv_buf[argc] = "--allow";
            argc += 1;
            argv_buf[argc] = rustup_home;
            argc += 1;
        }

        if (binaryInPath(allocator, "go")) {
            argv_buf[argc] = "--allow";
            argc += 1;
            argv_buf[argc] = go_path;
            argc += 1;
            argv_buf[argc] = "--allow";
            argc += 1;
            argv_buf[argc] = go_cache;
            argc += 1;
        }

        argv_buf[argc] = "--allow-file";
        argc += 1;
        argv_buf[argc] = mcp_json;
        argc += 1;
        if (fs.accessAbsolute(shell_profile, .{})) |_| {
            argv_buf[argc] = "--override-deny";
            argc += 1;
            argv_buf[argc] = shell_profile;
            argc += 1;
            argv_buf[argc] = "--read-file";
            argc += 1;
            argv_buf[argc] = shell_profile;
            argc += 1;
        } else |_| {}
        argv_buf[argc] = "--allow";
        argc += 1;
        argv_buf[argc] = ".";
        argc += 1;
        argv_buf[argc] = "--";
        argc += 1;
    }

    // The actual AI tool command
    argv_buf[argc] = tool_name;
    argc += 1;

    // Pass through extra args (e.g. -c, -p "prompt", --model, etc)
    for (extra_args) |arg| {
        if (arg) |a| {
            if (argc < argv_buf.len) {
                argv_buf[argc] = a;
                argc += 1;
            }
        }
    }

    if (prompt_arg) |pa| {
        for (prompt_flag) |flag| {
            argv_buf[argc] = flag;
            argc += 1;
        }
        argv_buf[argc] = pa;
        argc += 1;
    }
    const argv_slice = argv_buf[0..argc];

    var child = std.process.Child.init(argv_slice, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    // Run devenv shell from the directory that has devenv.nix
    if (devenv_dir) |d| {
        child.cwd = d;
    }

    // Ensure our binary's dir is in PATH so hooks can find `explicit`
    var env = try envWithSelfInPath(allocator);
    defer env.deinit();
    child.env_map = &env;

    // Ensure RTK hooks are configured where the tool supports them.
    if (findGitRoot(allocator)) |git_root| {
        defer allocator.free(git_root);
        if (mem.eql(u8, tool_name, "claude")) {
            ensureClaudeRtkHook(allocator, git_root) catch {};
        } else if (mem.eql(u8, tool_name, "gemini")) {
            ensureGeminiRtkHook(allocator, git_root) catch {};
        }
    } else |_| {}

    _ = try child.spawn();
    const term = try child.wait();
    process.exit(term.Exited);
}

fn nonoProfileForTool(tool_name: []const u8) []const u8 {
    if (mem.eql(u8, tool_name, "codex")) return "codex";
    if (mem.eql(u8, tool_name, "opencode")) return "opencode";
    return "claude-code";
}

/// Inject RTK Bash hook into .claude/settings.json.
/// Idempotent — checks for "rtk-rewrite" before modifying.
fn ensureClaudeRtkHook(allocator: mem.Allocator, git_root: []const u8) !void {
    // 2. Ensure ~/.claude/hooks/rtk-rewrite.sh exists
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
    defer allocator.free(home);

    const hook_path = try std.fmt.allocPrint(allocator, "{s}/.claude/hooks/rtk-rewrite.sh", .{home});
    defer allocator.free(hook_path);

    if (fs.accessAbsolute(hook_path, .{})) |_| {
        // Already exists — nothing to do
    } else |_| {
        // Run rtk init -g to create the hook script
        var rtk_init = std.process.Child.init(&.{ "rtk", "init", "-g" }, allocator);
        rtk_init.stdout_behavior = .Ignore;
        rtk_init.stderr_behavior = .Ignore;
        _ = rtk_init.spawn() catch return;
        _ = rtk_init.wait() catch {};
        // Verify the script was created
        fs.accessAbsolute(hook_path, .{}) catch return;
    }

    // 3. Read project's .claude/settings.json
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/.claude/settings.json", .{git_root});
    defer allocator.free(settings_path);

    const f = fs.openFileAbsolute(settings_path, .{}) catch return;
    const content = f.readToEndAlloc(allocator, 65536) catch {
        f.close();
        return;
    };
    f.close();
    defer allocator.free(content);

    // 4. Idempotency check
    if (mem.indexOf(u8, content, "rtk-rewrite") != null) return;

    // 5. Inject the hook
    const rtk_hook =
        \\{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/rtk-rewrite.sh"}]}
    ;
    const new_content = try injectNamedHook(allocator, content, "PreToolUse", rtk_hook);
    defer allocator.free(new_content);

    if (mem.eql(u8, new_content, content)) return; // no change

    const out = try fs.createFileAbsolute(settings_path, .{});
    defer out.close();
    try out.writeAll(new_content);

    stderr().writeAll("RTK: Added Bash hook to .claude/settings.json\n") catch {};
}

/// Inject RTK BeforeTool hook into .gemini/settings.json.
fn ensureGeminiRtkHook(allocator: mem.Allocator, git_root: []const u8) !void {
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/.gemini/settings.json", .{git_root});
    defer allocator.free(settings_path);

    const f = fs.openFileAbsolute(settings_path, .{}) catch return;
    const content = f.readToEndAlloc(allocator, 65536) catch {
        f.close();
        return;
    };
    f.close();
    defer allocator.free(content);

    if (mem.indexOf(u8, content, "rtk hook gemini") != null) return;

    const rtk_hook =
        \\{"matcher":"run_shell_command","hooks":[{"type":"command","command":"rtk hook gemini"}]}
    ;
    const new_content = try injectNamedHook(allocator, content, "BeforeTool", rtk_hook);
    defer allocator.free(new_content);

    if (mem.eql(u8, new_content, content)) return;

    const out = try fs.createFileAbsolute(settings_path, .{});
    defer out.close();
    try out.writeAll(new_content);

    stderr().writeAll("RTK: Added BeforeTool hook to .gemini/settings.json\n") catch {};
}

/// Return true if binary name exists in PATH.
fn binaryInPath(allocator: mem.Allocator, name: []const u8) bool {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return false;
    defer allocator.free(path_env);
    var it = mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const p = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }) catch continue;
        defer allocator.free(p);
        if (fs.accessAbsolute(p, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Insert hook_entry into the named hook array in JSON content.
/// If the hook event doesn't exist, creates it. Returns new JSON string.
fn injectNamedHook(allocator: mem.Allocator, content: []const u8, event_name: []const u8, hook_entry: []const u8) ![]const u8 {
    const quoted_event = try std.fmt.allocPrint(allocator, "\"{s}\"", .{event_name});
    defer allocator.free(quoted_event);

    // Case 1: hook event already exists — insert at start of its array
    if (mem.indexOf(u8, content, quoted_event)) |pre_pos| {
        var scan = pre_pos + quoted_event.len;
        while (scan < content.len and content[scan] != '[') : (scan += 1) {}
        if (scan < content.len) {
            const insert_pos = scan + 1;
            return try std.fmt.allocPrint(allocator, "{s}{s},{s}", .{
                content[0..insert_pos], hook_entry, content[insert_pos..],
            });
        }
    }

    // Case 2: No such hook event — add it after "hooks": {
    if (mem.indexOf(u8, content, "\"hooks\"")) |hooks_pos| {
        var scan = hooks_pos + "\"hooks\"".len;
        while (scan < content.len and content[scan] != '{') : (scan += 1) {}
        if (scan < content.len) {
            const insert_pos = scan + 1;
            const entry = try std.fmt.allocPrint(allocator, "\"{s}\":[{s}],", .{ event_name, hook_entry });
            defer allocator.free(entry);
            return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
                content[0..insert_pos], entry, content[insert_pos..],
            });
        }
    }

    // Fallback: return unchanged
    return try allocator.dupe(u8, content);
}

/// Find the mix project directory. Checks services/*/ first, then project root.
fn findMixDir(allocator: mem.Allocator, project_dir: []const u8) ?[]const u8 {
    // Check project root first
    const root_mix = std.fmt.allocPrint(allocator, "{s}/mix.exs", .{project_dir}) catch return null;
    if (fs.accessAbsolute(root_mix, .{})) {
        allocator.free(root_mix);
        return project_dir;
    } else |_| {}
    allocator.free(root_mix);

    // Check services/*/mix.exs
    const services_dir = std.fmt.allocPrint(allocator, "{s}/services", .{project_dir}) catch return null;
    defer allocator.free(services_dir);

    var dir = fs.openDirAbsolute(services_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            const candidate = std.fmt.allocPrint(allocator, "{s}/services/{s}", .{ project_dir, entry.name }) catch continue;
            const mix_path = std.fmt.allocPrint(allocator, "{s}/mix.exs", .{candidate}) catch {
                allocator.free(candidate);
                continue;
            };
            defer allocator.free(mix_path);

            if (fs.accessAbsolute(mix_path, .{})) {
                return candidate;
            } else |_| {
                allocator.free(candidate);
            }
        }
    }

    return null;
}

/// Find devenv.nix in CWD or parent dirs. Returns the directory path or null.
fn findDevenvDir(allocator: mem.Allocator) ?[]const u8 {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&path_buf) catch return null;
    var dir = allocator.dupe(u8, cwd) catch return null;

    while (true) {
        const devenv_path = std.fmt.allocPrint(allocator, "{s}/devenv.nix", .{dir}) catch return null;
        const found = if (fs.accessAbsolute(devenv_path, .{})) true else |_| false;
        allocator.free(devenv_path);
        if (found) return dir;

        const parent = std.fs.path.dirname(dir) orelse {
            allocator.free(dir);
            return null;
        };
        if (mem.eql(u8, parent, dir)) {
            allocator.free(dir);
            return null;
        }
        const parent_owned = allocator.dupe(u8, parent) catch {
            allocator.free(dir);
            return null;
        };
        allocator.free(dir);
        dir = parent_owned;
    }
}

// ─── Socket helpers ──────────────────────────────────────────────────────────

fn findGitRoot(allocator: mem.Allocator) ![]const u8 {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&path_buf) catch {
        stderr().writeAll("Error: Current directory does not exist.\n") catch {};
        stderr().writeAll("This happens when the directory was deleted and recreated.\n") catch {};
        stderr().writeAll("Fix: cd .. && cd $(basename $PWD)\n") catch {};
        process.exit(1);
    };
    const cwd_owned = try allocator.dupe(u8, cwd);
    var dir = try allocator.dupe(u8, cwd);

    while (true) {
        const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
        const found = if (fs.accessAbsolute(git_path, .{})) true else |_| false;
        allocator.free(git_path);
        if (found) {
            allocator.free(cwd_owned);
            return dir;
        }

        // dirname returns a slice INTO dir, so dupe parent BEFORE freeing dir
        const parent = std.fs.path.dirname(dir) orelse {
            // No parent — fall back to CWD instead of returning "/"
            allocator.free(dir);
            return cwd_owned;
        };
        if (mem.eql(u8, parent, dir)) {
            // Reached filesystem root without finding .git — fall back to CWD
            allocator.free(dir);
            return cwd_owned;
        }
        const parent_owned = try allocator.dupe(u8, parent);
        allocator.free(dir);
        dir = parent_owned;
    }
}

fn socketPathForDir(allocator: mem.Allocator, dir: []const u8) ![]const u8 {
    const Md5 = std.crypto.hash.Md5;
    var hash: [Md5.digest_length]u8 = undefined;
    Md5.hash(dir, &hash, .{});
    const hex_chars = "0123456789abcdef";
    var hex_str: [8]u8 = undefined;
    for (hash[0..4], 0..) |byte, i| {
        hex_str[i * 2] = hex_chars[byte >> 4];
        hex_str[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return try std.fmt.allocPrint(allocator, "/tmp/explicit-{s}.sock", .{hex_str});
}

fn connectToSocket(allocator: mem.Allocator) !net.Stream {
    const git_root = try findGitRoot(allocator);
    defer allocator.free(git_root);
    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    // Try connecting to existing server
    if (net.connectUnixSocket(sock_path)) |stream| {
        return stream;
    } else |_| {}

    // Auto-start the server
    const server_bin = try findServerBinary(allocator) orelse {
        stderr().writeAll("Error: explicit-server not found.\n") catch {};
        stderr().writeAll("Install: brew install explicit-sh/tap/explicit\n") catch {};
        process.exit(1);
    };
    defer allocator.free(server_bin);

    stderr().print("Starting server for {s}...\n", .{git_root}) catch {};

    var child = std.process.Child.init(&.{ server_bin, "daemon" }, allocator);
    child.pgid = 0;
    var env = try envWithSelfInPath(allocator);
    defer env.deinit();
    try env.put("EXPLICIT_PROJECT_DIR", git_root);
    child.env_map = &env;
    _ = try child.spawn();

    // Wait for socket (up to 10s)
    var attempts: u32 = 0;
    while (attempts < 50) : (attempts += 1) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        if (net.connectUnixSocket(sock_path)) |stream| {
            stderr().writeAll("Server started.\n") catch {};
            return stream;
        } else |_| {}
    }

    stderr().writeAll("Error: Server did not start within 10 seconds.\n") catch {};
    stderr().writeAll("Check the startup log: /tmp/explicit-server.log\n") catch {};
    stderr().writeAll("Try: `which explicit-server` and `explicit-server daemon`\n") catch {};
    if (!binaryInPath(allocator, "mix")) {
        stderr().writeAll("Note: `mix` is not on PATH in this shell. That can break source/dev explicit-server setups and project scaffolding.\n") catch {};
    }
    process.exit(1);
}

fn cmdSend(allocator: mem.Allocator, request: []const u8, json_output: bool) !void {
    var stream = try connectToSocket(allocator);
    defer stream.close();

    const response = sendRequest(allocator, stream, request) catch |err| {
        stderr().print("Error: server communication failed: {s}\n", .{@errorName(err)}) catch {};
        process.exit(1);
    };
    defer allocator.free(response);

    if (json_output) {
        try stdout().writeAll(response);
        try stdout().writeAll("\n");
    } else {
        try printHuman(response);
    }
}

fn printHuman(response: []const u8) !void {
    const out = stdout();
    const err = stderr();

    // Error responses
    if (mem.indexOf(u8, response, "\"ok\":false") != null) {
        if (extractJsonString(response, "\"error\":\"")) |msg| {
            try err.writeAll("Error: ");
            try err.writeAll(msg);
            try err.writeAll("\n");
        } else {
            try err.writeAll(response);
        }
        return;
    }

    // ── status ──────────────────────────────────────────────────────
    if (mem.indexOf(u8, response, "\"watching\":") != null and
        mem.indexOf(u8, response, "\"files_checked\":") != null)
    {
        if (extractJsonString(response, "\"watching\":\"")) |dir| {
            try out.print("Watching: {s}\n", .{dir});
        }
        if (extractJsonInt(response, "\"files_checked\":")) |n| {
            try out.print("Code files: {d}\n", .{n});
        }
        if (extractJsonInt(response, "\"total_violations\":")) |n| {
            if (n == 0) {
                try out.writeAll("Violations: none\n");
            } else {
                try out.print("Violations: {d}\n", .{n});
            }
        }
        const doc_errors = extractJsonInt(response, "\"doc_errors\":") orelse 0;
        const doc_warnings = extractJsonInt(response, "\"doc_warnings\":") orelse 0;
        if (doc_errors > 0) {
            try out.print("Doc errors: {d}\n", .{doc_errors});
        }
        if (doc_warnings > 0) {
            try out.print("Doc warnings: {d}\n", .{doc_warnings});
        }
        return;
    }

    // ── validate / quality ────────────────────────────────────────
    if (mem.indexOf(u8, response, "\"clean\":true") != null and
        mem.indexOf(u8, response, "\"doc_refs_in_code\"") != null)
    {
        try out.writeAll("Validate: clean\n");
        return;
    }
    if (mem.indexOf(u8, response, "\"clean\":true") != null) {
        // Clean — no output needed, hook passes silently
        return;
    }
    if (mem.indexOf(u8, response, "\"clean\":false") != null) {
        // Build concise summary line — only non-zero categories
        try out.writeAll("[FAIL] ");
        var sep: bool = false;
        inline for (.{
            .{ "\"iron_law_violations\":", "iron_law" },
            .{ "\"missing_specs\":", "missing_specs" },
            .{ "\"missing_docs\":", "missing_docs" },
            .{ "\"tests_in_lib\":", "tests_in_lib" },
            .{ "\"doc_errors\":", "doc_errors" },
        }) |pair| {
            if (extractJsonInt(response, pair[0])) |n| {
                if (n > 0) {
                    if (sep) try out.writeAll(", ");
                    try out.print("{d} {s}", .{ n, pair[1] });
                    sep = true;
                }
            }
        }
        try out.writeAll("\n");

        // Files: walk the `files` array and print each entry with code+message
        // (for doc errors) or count (for code-file aggregates). Cap at 10.
        try printQualityFileList(response, out);

        // Fix instructions (compact, one line each)
        {
            var it = mem.splitSequence(u8, response, "\"fix\":[\"");
            _ = it.next();
            if (it.next()) |chunk| {
                if (mem.indexOf(u8, chunk, "]")) |end| {
                    try out.writeAll("Fix: ");
                    var fit = mem.splitSequence(u8, chunk[0..end], "\",\"");
                    var first = true;
                    while (fit.next()) |f| {
                        const clean = mem.trimRight(u8, mem.trimLeft(u8, f, "\""), "\"");
                        if (clean.len > 0) {
                            if (!first) try out.writeAll("; ");
                            // Take just the first line of each fix
                            if (mem.indexOf(u8, clean, "\\n")) |nl| {
                                try out.writeAll(clean[0..nl]);
                            } else {
                                try out.writeAll(clean);
                            }
                            first = false;
                        }
                    }
                    try out.writeAll("\n");
                }
            }
        }

        return;
    }

    // ── violations ──────────────────────────────────────────────────
    if (mem.indexOf(u8, response, "\"violations\":[]") != null) {
        try out.writeAll("No violations found.\n");
        return;
    }
    if (mem.indexOf(u8, response, "\"violations\":[") != null) {
        if (extractJsonInt(response, "\"total\":")) |n| {
            try out.print("{d} violation(s):\n", .{n});
        }
        // Extract path:line CHECK message for each violation.
        // Fixes EXPLICIT-FEEDBACK.md #12 — old output was just message text,
        // which is not actionable without a code and file path.
        try printViolationList(response, out);
        return;
    }

    // ── stopped ─────────────────────────────────────────────────────
    if (mem.indexOf(u8, response, "\"stopped\":true") != null) {
        try out.writeAll("Server stopped.\n");
        return;
    }

    // ── init/scaffold ───────────────────────────────────────────────
    if (mem.indexOf(u8, response, "\"created\":[") != null) {
        if (extractJsonString(response, "\"project\":\"")) |dir| {
            try out.print("Project: {s}\n", .{dir});
        }
        try out.writeAll("\nWhat explicit set up:\n");
        try out.writeAll("  docs/                 Project documentation: ADRs, opportunities, incidents, specs. Use `explicit docs ...`\n");
        try out.writeAll("  .explicit/            explicit config and org registry for doc authors/owners\n");
        try out.writeAll("  services/             App code workspace; Phoenix app may be scaffolded here\n");
        try out.writeAll("  infra/                OpenTofu/Terraform starter config for infrastructure\n");
        try out.writeAll("\nAgent instructions:\n");
        try out.writeAll("  AGENTS.md             Shared repo instructions for Codex, Gemini, and OpenCode\n");
        try out.writeAll("                        https://developers.openai.com/codex/guides/agents-md\n");
        try out.writeAll("  GEMINI.md             Gemini CLI context entrypoint; points Gemini at AGENTS.md\n");
        try out.writeAll("                        https://geminicli.com/docs/cli/gemini-md/\n");
        try out.writeAll("  CLAUDE.md             Claude Code entrypoint; points Claude at AGENTS.md\n");
        try out.writeAll("  .agents/AGENTS.md     Antigravity-compatible mirror of the root AGENTS.md\n");
        try out.writeAll("  opencode.json         OpenCode project config; points instructions at AGENTS.md\n");
        try out.writeAll("                        https://opencode.ai/docs/config/\n");
        try out.writeAll("\nHooks:\n");
        try out.writeAll("  .claude/settings.json Claude Code hooks that run explicit checks automatically\n");
        try out.writeAll("  .codex/hooks.json     Codex hook commands for stop/post-tool checks\n");
        try out.writeAll("  .codex/config.toml    Enables Codex hooks via `[features] codex_hooks = true`\n");
        try out.writeAll("  .gemini/settings.json Gemini CLI hooks for AfterTool and AfterAgent checks\n");
        try out.writeAll("                        https://geminicli.com/docs/hooks/\n");
        try out.writeAll("  .opencode/plugins/    OpenCode plugin that runs explicit stop checks on session idle\n");
        try out.writeAll("                        OpenCode plugins are event-based rather than native blocking stop hooks\n");
        try out.writeAll("                        https://opencode.ai/docs/plugins/\n");
        try out.writeAll("                        Hooks are deterministic commands fired on lifecycle events like Stop and PostToolUse\n");
        try out.writeAll("                        https://developers.openai.com/codex/hooks\n");
        try out.writeAll("\nEnvironment and editor:\n");
        try out.writeAll("  devenv.nix            Reproducible dev shell, services, and process definitions\n");
        try out.writeAll("  devenv.yaml           Generated by `devenv init` for upstream inputs/bootstrap\n");
        try out.writeAll("  .lsp.json             Language server configuration for the repo\n");
        try out.writeAll("  .vscode/              Recommended editor settings and extensions\n");
        try out.writeAll("                        https://devenv.sh\n");
        try printCreatedList(response, out);
        return;
    }

    // ── doc.list ────────────────────────────────────────────────────
    if (mem.indexOf(u8, response, "\"docs\":[") != null) {
        if (extractJsonInt(response, "\"total\":")) |n| {
            try out.print("{d} document(s):\n", .{n});
        }
        var it = mem.splitSequence(u8, response, "\"id\":\"");
        _ = it.next();
        while (it.next()) |chunk| {
            if (mem.indexOf(u8, chunk, "\"")) |end| {
                const id = chunk[0..end];
                try out.writeAll("  ");
                try out.writeAll(id);
                // Extract title for this entry
                if (mem.indexOf(u8, chunk, "\"title\":\"")) |tstart| {
                    const after_title = chunk[tstart + 9 ..];
                    if (mem.indexOf(u8, after_title, "\"")) |tend| {
                        try out.writeAll(" — ");
                        try out.writeAll(after_title[0..tend]);
                    }
                }
                try out.writeAll("\n");
            }
        }
        return;
    }

    // ── test results ────────────────────────────────────────────────
    if (mem.indexOf(u8, response, "\"tests\":") != null and
        mem.indexOf(u8, response, "\"failures\":") != null)
    {
        if (mem.indexOf(u8, response, "\"passed\":true") != null) {
            try out.writeAll("Tests: passed\n");
        } else {
            try out.writeAll("Tests: FAILED\n");
        }
        if (extractJsonInt(response, "\"tests\":")) |n| try out.print("  Total: {d}\n", .{n});
        if (extractJsonInt(response, "\"failures\":")) |n| {
            if (n > 0) try out.print("  Failures: {d}\n", .{n});
        }
        // Coverage info
        if (mem.indexOf(u8, response, "\"coverage\":")) |pos| {
            const start = pos + "\"coverage\":".len;
            var end: usize = start;
            while (end < response.len and response[end] != ',' and response[end] != '}') : (end += 1) {}
            if (end > start) {
                const cov_str = mem.trim(u8, response[start..end], " ");
                if (!mem.eql(u8, cov_str, "null")) {
                    try out.print("  Coverage: {s}%\n", .{cov_str});
                }
            }
        }
        if (mem.indexOf(u8, response, "\"coverage_below_threshold\":true") != null) {
            try out.writeAll("  Coverage below threshold!\n");
        }
        return;
    }

    // ── fallback: dump raw JSON ─────────────────────────────────────
    try out.writeAll(response);
}

fn printIfNonZero(out: anytype, response: []const u8, key: []const u8, label: []const u8) !void {
    if (extractJsonInt(response, key)) |n| {
        if (n > 0) try out.print("{s}: {d}\n", .{ label, n });
    }
}

fn printCreatedList(response: []const u8, out: fs.File.DeprecatedWriter) !void {
    var it = mem.splitSequence(u8, response, "\"created\":[\"");
    _ = it.next();
    if (it.next()) |chunk| {
        if (mem.indexOf(u8, chunk, "]")) |end| {
            const files_str = chunk[0..end];
            var fit = mem.splitSequence(u8, files_str, "\",\"");
            try out.writeAll("\nNew files this run:\n");
            var any = false;
            while (fit.next()) |f| {
                const clean = mem.trimRight(u8, f, "\"");
                if (clean.len > 0) {
                    any = true;
                    try out.writeAll("  ");
                    try out.writeAll(clean);
                    try out.writeAll("\n");
                }
            }
            if (!any) {
                try out.writeAll("  (none — files already existed)\n");
            }
        }
    }
}

fn extractJsonString(response: []const u8, key: []const u8) ?[]const u8 {
    const start = (mem.indexOf(u8, response, key) orelse return null) + key.len;
    const end = mem.indexOf(u8, response[start..], "\"") orelse return null;
    return response[start .. start + end];
}

fn extractJsonInt(response: []const u8, key: []const u8) ?i64 {
    const start = (mem.indexOf(u8, response, key) orelse return null) + key.len;
    var end: usize = start;
    while (end < response.len and (response[end] >= '0' and response[end] <= '9')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, response[start..end], 10) catch null;
}

/// Print the `files` array from a quality response. Each entry is either:
///   - doc-error: {file, code, message, id?}
///   - code-file aggregate: {file, count, issues, mtime}
/// Prints up to `max` items.
fn printQualityFileList(response: []const u8, out: fs.File.DeprecatedWriter) !void {
    const files_marker = "\"files\":[";
    const files_pos = mem.indexOf(u8, response, files_marker) orelse return;
    const body = response[files_pos + files_marker.len ..];

    var idx: usize = 0;
    var shown: u32 = 0;
    const max: u32 = 10;
    while (idx < body.len and shown < max) {
        while (idx < body.len and (body[idx] == ',' or body[idx] == ' ')) : (idx += 1) {}
        if (idx >= body.len or body[idx] == ']') break;
        if (body[idx] != '{') break;

        // Find matching close brace, counting depth (entries may contain nested `issues` obj)
        var depth: u32 = 0;
        var obj_end: usize = idx;
        while (obj_end < body.len) : (obj_end += 1) {
            if (body[obj_end] == '{') depth += 1;
            if (body[obj_end] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (obj_end >= body.len) break;

        const obj = body[idx .. obj_end + 1];
        const file = extractJsonString(obj, "\"file\":\"") orelse "";
        const code = extractJsonString(obj, "\"code\":\"");
        const message = extractJsonString(obj, "\"message\":\"");
        const count = extractJsonInt(obj, "\"count\":");

        if (code) |c| {
            try out.print("  {s}  {s}  {s}\n", .{ file, c, message orelse "" });
        } else if (count) |n| {
            try out.print("  {s}  ({d} issue(s))\n", .{ file, n });
        } else if (file.len > 0) {
            try out.print("  {s}\n", .{file});
        }

        shown += 1;
        idx = obj_end + 1;
    }
}

/// Print `violations` array entries in `path:line  CHECK  message` format.
/// Each entry in the array is a JSON object with at least file/line/check/message.
fn printViolationList(response: []const u8, out: fs.File.DeprecatedWriter) !void {
    // Find start of the violations array
    const arr_marker = "\"violations\":[";
    const arr_start = mem.indexOf(u8, response, arr_marker) orelse return;
    const body = response[arr_start + arr_marker.len ..];

    // Walk objects separated by "},{" (or bounded by initial "{" and final "}")
    var idx: usize = 0;
    while (idx < body.len) {
        // Find the next object start
        const obj_start = mem.indexOfScalarPos(u8, body, idx, '{') orelse return;
        // Find the matching closing brace (simple: next '}' since violations have
        // no nested objects in the current server output).
        const obj_end_rel = mem.indexOfScalarPos(u8, body, obj_start + 1, '}') orelse return;
        const obj = body[obj_start .. obj_end_rel + 1];

        const file = extractJsonString(obj, "\"file\":\"") orelse "";
        const check = extractJsonString(obj, "\"check\":\"") orelse "";
        const message = extractJsonString(obj, "\"message\":\"") orelse "";
        const line = extractJsonInt(obj, "\"line\":") orelse 0;

        if (file.len > 0 or message.len > 0) {
            if (line > 0) {
                try out.print("  {s}:{d}  {s}  {s}\n", .{ file, line, check, message });
            } else {
                try out.print("  {s}  {s}  {s}\n", .{ file, check, message });
            }
        }

        idx = obj_end_rel + 1;
        // Stop at end of array
        if (idx < body.len and body[idx] == ']') return;
    }
}

fn findServerBinary(allocator: mem.Allocator) !?[]const u8 {
    // 1. Same dir as CLI
    var exe_buf: [fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExePath(&exe_buf)) |exe_path| {
        if (std.fs.path.dirname(exe_path)) |exe_dir| {
            const sibling = try std.fmt.allocPrint(allocator, "{s}/explicit-server", .{exe_dir});
            if (fs.cwd().statFile(sibling)) |_| return sibling else |_| allocator.free(sibling);
        }
    } else |_| {}

    // 2. ~/.explicit/explicit-server
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const p = try std.fmt.allocPrint(allocator, "{s}/.explicit/explicit-server", .{home});
        if (fs.cwd().statFile(p)) |_| return p else |_| allocator.free(p);
    } else |_| {}

    // 3. PATH
    if (std.process.getEnvVarOwned(allocator, "PATH")) |path_env| {
        defer allocator.free(path_env);
        var it = mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            const p = try std.fmt.allocPrint(allocator, "{s}/explicit-server", .{dir});
            if (fs.cwd().statFile(p)) |_| return p else |_| allocator.free(p);
        }
    } else |_| {}

    return null;
}

fn cmdWatch(allocator: mem.Allocator, json_output: bool) !void {
    // connectToSocket auto-starts the server if needed
    var stream = try connectToSocket(allocator);
    defer stream.close();

    // Confirm it's running via status
    const response = try sendRequest(allocator, stream, "{\"method\":\"status\"}");
    defer allocator.free(response);
    if (json_output) {
        try stdout().writeAll(response);
        try stdout().writeAll("\n");
    } else {
        try stderr().writeAll("Server is running.\n");
    }
}
