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

    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip argv[0]

    const command = args.next() orelse {
        printUsage();
        return;
    };

    // Collect remaining args
    var json_output = false;
    var file_arg: ?[]const u8 = null;
    var sub1: ?[]const u8 = null;
    var sub2: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else {
            if (sub1 == null) {
                sub1 = arg;
            } else if (sub2 == null) {
                sub2 = arg;
            }
            if (file_arg == null) file_arg = arg;
        }
    }

    if (mem.eql(u8, command, "init")) {
        try cmdInit(allocator);
    } else if (mem.eql(u8, command, "hooks")) {
        try cmdHooks(allocator, sub1, sub2);
    } else if (mem.eql(u8, command, "watch")) {
        try cmdWatch(allocator, json_output);
    } else if (mem.eql(u8, command, "status")) {
        try cmdSend(allocator, "{\"method\":\"status\"}\n", json_output);
    } else if (mem.eql(u8, command, "violations")) {
        if (file_arg) |f| {
            const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"violations\",\"params\":{{\"file\":\"{s}\"}}}}\n", .{f});
            defer allocator.free(req);
            try cmdSend(allocator, req, json_output);
        } else {
            try cmdSend(allocator, "{\"method\":\"violations\"}\n", json_output);
        }
    } else if (mem.eql(u8, command, "check")) {
        const f = file_arg orelse {
            try stderr().writeAll("Usage: explicit check <file>\n");
            process.exit(1);
        };
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"check\",\"params\":{{\"file\":\"{s}\"}}}}\n", .{f});
        defer allocator.free(req);
        try cmdSend(allocator, req, json_output);
    } else if (mem.eql(u8, command, "stop")) {
        try cmdSend(allocator, "{\"method\":\"stop\"}\n", json_output);
    } else if (mem.eql(u8, command, "help") or mem.eql(u8, command, "--help") or mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        stderr().print("Unknown command: {s}\n", .{command}) catch {};
        printUsage();
        process.exit(1);
    }
}

fn printUsage() void {
    stderr().writeAll(
        \\explicit — Elixir code analysis tool
        \\
        \\Usage:
        \\  explicit init              Initialize project (git, devenv, claude hooks)
        \\  explicit watch             Start server for current project (finds git root)
        \\  explicit status            Show server status
        \\  explicit violations [file] List violations (optionally for one file)
        \\  explicit check <file>      Force re-check a file
        \\  explicit stop              Stop the server
        \\  explicit hooks claude stop Claude Code stop hook (used internally)
        \\
        \\Flags:
        \\  --json                     Output raw JSON (machine-readable)
        \\
    ) catch {};
}

// ─── Init command ────────────────────────────────────────────────────────────

fn cmdInit(allocator: mem.Allocator) !void {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&path_buf);

    // 1. git init
    try initGit(allocator, cwd);

    // 2. devenv init
    try initDevenv(allocator, cwd);

    // 3. .claude/ config
    try initClaude(allocator, cwd);

    stderr().writeAll("\nDone! Run 'explicit watch' to start the server.\n") catch {};
}

fn initGit(allocator: mem.Allocator, cwd: []const u8) !void {
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{cwd});
    defer allocator.free(git_dir);

    // Check if .git dir exists using access
    if (fs.accessAbsolute(git_dir, .{})) {
        stderr().writeAll("git: already initialized\n") catch {};
    } else |_| {
        stderr().writeAll("git: initializing...\n") catch {};
        var child = std.process.Child.init(&.{ "git", "init" }, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = try child.spawn();
        const term = try child.wait();
        if (term.Exited == 0) {
            stderr().writeAll("git: initialized\n") catch {};
        } else {
            stderr().writeAll("git: init failed\n") catch {};
        }
    }
}

fn initDevenv(allocator: mem.Allocator, cwd: []const u8) !void {
    const devenv_path = try std.fmt.allocPrint(allocator, "{s}/devenv.nix", .{cwd});
    defer allocator.free(devenv_path);

    if (fs.cwd().statFile(devenv_path)) |_| {
        stderr().writeAll("devenv: already initialized\n") catch {};
    } else |_| {
        stderr().writeAll("devenv: initializing...\n") catch {};
        var child = std.process.Child.init(&.{ "devenv", "init" }, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = try child.spawn();
        const term = try child.wait();
        if (term.Exited == 0) {
            stderr().writeAll("devenv: initialized\n") catch {};
        } else {
            stderr().writeAll("devenv: init failed (is devenv installed?)\n") catch {};
        }
    }
}

fn initClaude(allocator: mem.Allocator, cwd: []const u8) !void {
    // Find path to this binary for hook command
    var exe_buf: [fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch cwd;
    _ = exe_path;

    const claude_dir = try std.fmt.allocPrint(allocator, "{s}/.claude", .{cwd});
    defer allocator.free(claude_dir);

    // Create .claude/ dir
    fs.cwd().makeDir(claude_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const settings_path = try std.fmt.allocPrint(allocator, "{s}/.claude/settings.json", .{cwd});
    defer allocator.free(settings_path);

    // Check if settings.json already exists
    if (fs.cwd().statFile(settings_path)) |_| {
        // File exists — check if hook already configured
        const existing = fs.cwd().readFileAlloc(allocator, settings_path, 1024 * 1024) catch {
            stderr().writeAll("claude: settings.json exists but couldn't read it\n") catch {};
            return;
        };
        defer allocator.free(existing);

        if (mem.indexOf(u8, existing, "explicit hooks claude stop") != null) {
            stderr().writeAll("claude: hooks already configured\n") catch {};
            return;
        }

        stderr().writeAll("claude: settings.json exists but missing explicit hook\n") catch {};
        stderr().writeAll("claude: add this to .claude/settings.json manually:\n") catch {};
        printHookConfig();
        return;
    } else |_| {}

    // Create settings.json with hook config
    const settings_content =
        \\{
        \\  "hooks": {
        \\    "Stop": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "explicit hooks claude stop"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        \\
    ;

    const file = try fs.cwd().createFile(settings_path, .{});
    defer file.close();
    try file.writeAll(settings_content);

    stderr().writeAll("claude: created .claude/settings.json with stop hook\n") catch {};

    // Create CLAUDE.md if it doesn't exist
    const claude_md_path = try std.fmt.allocPrint(allocator, "{s}/CLAUDE.md", .{cwd});
    defer allocator.free(claude_md_path);

    if (fs.cwd().statFile(claude_md_path)) |_| {
        // Already exists
    } else |_| {
        const claude_md = try fs.cwd().createFile(claude_md_path, .{});
        defer claude_md.close();
        try claude_md.writeAll(
            \\# Project Instructions
            \\
            \\## Code Quality
            \\
            \\This project uses [explicit](https://github.com/explicit-sh/explicit) for real-time code analysis.
            \\The server watches for file changes and checks Elixir code against Iron Law rules.
            \\
            \\A Claude Code stop hook is configured — if violations are found after your response,
            \\you'll be asked to fix them before proceeding.
            \\
            \\```bash
            \\explicit violations --json  # Check current violations
            \\explicit check <file>       # Re-check a specific file
            \\```
            \\
        );
        stderr().writeAll("claude: created CLAUDE.md\n") catch {};
    }
}

fn printHookConfig() void {
    stderr().writeAll(
        \\
        \\  "hooks": {
        \\    "Stop": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "explicit hooks claude stop"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\
    ) catch {};
}

// ─── Hooks command ───────────────────────────────────────────────────────────

fn cmdHooks(allocator: mem.Allocator, provider: ?[]const u8, hook_name: ?[]const u8) !void {
    const p = provider orelse {
        stderr().writeAll("Usage: explicit hooks claude <stop>\n") catch {};
        process.exit(1);
    };

    if (!mem.eql(u8, p, "claude")) {
        stderr().print("Unknown hook provider: {s}\n", .{p}) catch {};
        process.exit(1);
    }

    const h = hook_name orelse {
        stderr().writeAll("Usage: explicit hooks claude <stop>\n") catch {};
        process.exit(1);
    };

    if (mem.eql(u8, h, "stop")) {
        try hookClaudeStop(allocator);
    } else {
        stderr().print("Unknown hook: {s}\n", .{h}) catch {};
        process.exit(1);
    }
}

/// Claude Code Stop hook: check violations, exit 2 to block if any found
fn hookClaudeStop(allocator: mem.Allocator) !void {
    const git_root = findGitRoot(allocator) catch {
        // Not in a git repo — nothing to check
        process.exit(0);
    };
    defer allocator.free(git_root);

    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    // Connect to server — if not running, silently pass
    var stream = net.connectUnixSocket(sock_path) catch {
        process.exit(0);
    };
    defer stream.close();

    // Request violations
    stream.writeAll("{\"method\":\"violations\"}\n") catch {
        process.exit(0);
    };

    var buf: [65536]u8 = undefined;
    const n = stream.read(&buf) catch {
        process.exit(0);
    };

    if (n == 0) process.exit(0);

    const response = buf[0..n];

    // Check if there are violations (total > 0)
    // Look for "total":0 — if found, no violations
    if (mem.indexOf(u8, response, "\"total\":0") != null) {
        process.exit(0);
    }

    // Has violations — output to stderr and exit 2 to block
    stderr().writeAll(response) catch {};
    process.exit(2);
}

// ─── Socket/server helpers ───────────────────────────────────────────────────

/// Find git root by traversing up from CWD.
fn findGitRoot(allocator: mem.Allocator) ![]const u8 {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&path_buf);

    var dir = try allocator.dupe(u8, cwd);

    while (true) {
        const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
        defer allocator.free(git_path);

        if (fs.cwd().statFile(git_path)) |_| {
            return dir;
        } else |_| {}

        const parent = std.fs.path.dirname(dir) orelse {
            allocator.free(dir);
            return try allocator.dupe(u8, cwd);
        };

        if (mem.eql(u8, parent, dir)) {
            allocator.free(dir);
            return try allocator.dupe(u8, cwd);
        }

        allocator.free(dir);
        dir = try allocator.dupe(u8, parent);
    }
}

/// Compute socket path from git root: /tmp/explicit-{md5_first_8hex}.sock
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

    const path = try socketPathForDir(allocator, git_root);
    defer allocator.free(path);

    return net.connectUnixSocket(path) catch {
        stderr().print("Error: No explicit server running for {s}\nStart one with: explicit watch\n", .{git_root}) catch {};
        process.exit(1);
    };
}

fn cmdSend(allocator: mem.Allocator, request: []const u8, json_output: bool) !void {
    var stream = try connectToSocket(allocator);
    defer stream.close();

    try stream.writeAll(request);

    var buf: [65536]u8 = undefined;
    const n = try stream.read(&buf);
    if (n == 0) {
        try stderr().writeAll("Error: Empty response from server\n");
        process.exit(1);
    }

    const response = buf[0..n];
    const out = stdout();

    if (json_output) {
        try out.writeAll(response);
    } else {
        try printHuman(out, response);
    }
}

fn printHuman(writer: anytype, response: []const u8) !void {
    if (mem.indexOf(u8, response, "\"ok\":true") != null) {
        if (mem.indexOf(u8, response, "\"violations\":[]") != null) {
            try writer.writeAll("No violations found.\n");
        } else if (mem.indexOf(u8, response, "\"stopped\":true") != null) {
            try writer.writeAll("Server stopped.\n");
        } else {
            try writer.writeAll(response);
        }
    } else {
        try writer.writeAll("Error: ");
        try writer.writeAll(response);
    }
}

/// Find the explicit-server binary. Search order:
/// 1. Same directory as this CLI binary
/// 2. ~/.explicit/explicit-server
/// 3. PATH
fn findServerBinary(allocator: mem.Allocator) !?[]const u8 {
    var exe_buf: [fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExePath(&exe_buf)) |exe_path| {
        if (std.fs.path.dirname(exe_path)) |exe_dir| {
            const sibling = try std.fmt.allocPrint(allocator, "{s}/explicit-server", .{exe_dir});
            if (fs.cwd().statFile(sibling)) |_| {
                return sibling;
            } else |_| {
                allocator.free(sibling);
            }
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const home_bin = try std.fmt.allocPrint(allocator, "{s}/.explicit/explicit-server", .{home});
        if (fs.cwd().statFile(home_bin)) |_| {
            return home_bin;
        } else |_| {
            allocator.free(home_bin);
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "PATH")) |path_env| {
        defer allocator.free(path_env);
        var it = mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            const candidate = try std.fmt.allocPrint(allocator, "{s}/explicit-server", .{dir});
            if (fs.cwd().statFile(candidate)) |_| {
                return candidate;
            } else |_| {
                allocator.free(candidate);
            }
        }
    } else |_| {}

    return null;
}

fn cmdWatch(allocator: mem.Allocator, json_output: bool) !void {
    const git_root = try findGitRoot(allocator);
    defer allocator.free(git_root);

    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    if (net.connectUnixSocket(sock_path)) |stream| {
        stream.close();
        stderr().print("Server already running for {s}\n", .{git_root}) catch {};

        if (json_output) {
            stdout().print("{{\"ok\":true,\"data\":{{\"already_running\":true,\"project\":\"{s}\"}}}}\n", .{git_root}) catch {};
        }
        return;
    } else |_| {}

    const server_bin = try findServerBinary(allocator) orelse {
        stderr().writeAll("Error: explicit-server binary not found.\n") catch {};
        stderr().writeAll("Install with: brew install explicit-sh/tap/explicit\n") catch {};
        process.exit(1);
    };
    defer allocator.free(server_bin);

    stderr().print("Starting explicit server for: {s}\n", .{git_root}) catch {};

    var child = std.process.Child.init(
        &.{ server_bin, "daemon" },
        allocator,
    );
    child.pgid = 0;

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("EXPLICIT_PROJECT_DIR", git_root);
    child.env_map = &env;

    _ = try child.spawn();

    var attempts: u32 = 0;
    while (attempts < 25) : (attempts += 1) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        if (net.connectUnixSocket(sock_path)) |stream| {
            stream.close();
            stderr().writeAll("Server started. Use 'explicit status' to check.\n") catch {};

            if (json_output) {
                stdout().print("{{\"ok\":true,\"data\":{{\"started\":true,\"project\":\"{s}\"}}}}\n", .{git_root}) catch {};
            }
            return;
        } else |_| {}
    }

    stderr().writeAll("Error: Server did not start within 5 seconds.\n") catch {};
    process.exit(1);
}
