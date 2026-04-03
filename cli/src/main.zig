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

    // Collect remaining positional args + flags
    var json_output = false;
    var positional: [8]?[]const u8 = .{null} ** 8;
    var pos_count: usize = 0;

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (pos_count < 8) {
            positional[pos_count] = arg;
            pos_count += 1;
        }
    }

    const p0 = positional[0];
    const p1 = positional[1];

    // ─── Commands that don't need a running server ─────────────────────
    if (mem.eql(u8, command, "watch")) {
        try cmdWatch(allocator, json_output);
        return;
    } else if (mem.eql(u8, command, "hooks")) {
        try cmdHooks(allocator, p0, p1);
        return;
    } else if (mem.eql(u8, command, "help") or mem.eql(u8, command, "--help") or mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    // ─── Commands that send to the server ──────────────────────────────
    const request = try buildRequest(allocator, command, p0, p1);
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
fn buildRequest(allocator: mem.Allocator, command: []const u8, p0: ?[]const u8, p1: ?[]const u8) !?[]const u8 {
    // Simple commands (no params)
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
        return try buildDocsRequest(allocator, p0, p1);
    }

    return null;
}

fn buildDocsRequest(allocator: mem.Allocator, p0: ?[]const u8, p1: ?[]const u8) ![]const u8 {
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
        const type_name = p1 orelse {
            stderr().writeAll("Usage: explicit docs new <type> <title>\n") catch {};
            process.exit(1);
        };
        // TODO: pass title from additional args
        return try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.new\",\"params\":{{\"type\":\"{s}\",\"title\":\"Untitled\"}}}}\n", .{type_name});
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
        \\  explicit status            Show server status
        \\  explicit quality           Quality gate report (tests, docs, lint)
        \\  explicit test              Run mix test
        \\  explicit violations [file] List code violations
        \\  explicit check <file>      Force re-check a file
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
        \\
    ) catch {};
}

// ─── Hooks ───────────────────────────────────────────────────────────────────

fn cmdHooks(allocator: mem.Allocator, provider: ?[]const u8, hook_name: ?[]const u8) !void {
    const p = provider orelse {
        stderr().writeAll("Usage: explicit hooks claude <stop|check-fixme|check-code>\n") catch {};
        process.exit(1);
    };
    if (!mem.eql(u8, p, "claude")) {
        stderr().print("Unknown hook provider: {s}\n", .{p}) catch {};
        process.exit(1);
    }
    const h = hook_name orelse {
        stderr().writeAll("Usage: explicit hooks claude <stop|check-fixme|check-code>\n") catch {};
        process.exit(1);
    };

    if (mem.eql(u8, h, "stop")) {
        try hookClaudeStop(allocator);
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

/// Stop hook: unified quality gate — checks violations, docs, tests, specs
fn hookClaudeStop(allocator: mem.Allocator) !void {
    const git_root = findGitRoot(allocator) catch { process.exit(0); };
    defer allocator.free(git_root);
    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    const has_issues = try checkMethod(sock_path, "{\"method\":\"quality\"}\n", "\"clean\":true");
    if (has_issues) process.exit(2);
    process.exit(0);
}

/// Send method, check if response contains the "clean" marker. Returns true if issues found.
fn checkMethod(sock_path: []const u8, request: []const u8, clean_marker: []const u8) !bool {
    var stream = net.connectUnixSocket(sock_path) catch { return false; };
    defer stream.close();
    stream.writeAll(request) catch { return false; };
    var buf: [65536]u8 = undefined;
    const n = stream.read(&buf) catch { return false; };
    if (n == 0) return false;
    const response = buf[0..n];
    if (mem.indexOf(u8, response, clean_marker) != null) return false;
    stderr().writeAll(response) catch {};
    return true;
}

/// Send a method to server, output to stderr if non-empty result, exit 0 (advisory)
fn hookSendQuiet(allocator: mem.Allocator, request: []const u8) !void {
    const git_root = findGitRoot(allocator) catch { process.exit(0); };
    defer allocator.free(git_root);
    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    var stream = net.connectUnixSocket(sock_path) catch { process.exit(0); };
    defer stream.close();
    stream.writeAll(request) catch { process.exit(0); };

    var buf: [65536]u8 = undefined;
    const n = stream.read(&buf) catch { process.exit(0); };
    if (n > 0) {
        const response = buf[0..n];
        if (mem.indexOf(u8, response, "\"total\":0") == null) {
            stderr().writeAll(response) catch {};
        }
    }
    process.exit(0);
}

// ─── Socket helpers ──────────────────────────────────────────────────────────

fn findGitRoot(allocator: mem.Allocator) ![]const u8 {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&path_buf);
    var dir = try allocator.dupe(u8, cwd);

    while (true) {
        const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
        const found = if (fs.accessAbsolute(git_path, .{})) true else |_| false;
        allocator.free(git_path);
        if (found) return dir;

        // dirname returns a slice INTO dir, so dupe parent BEFORE freeing dir
        const parent = std.fs.path.dirname(dir) orelse return dir;
        if (mem.eql(u8, parent, dir)) return dir;
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
    var env = try std.process.getEnvMap(allocator);
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
    process.exit(1);
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
    if (json_output) {
        try stdout().writeAll(response);
    } else {
        try printHuman(response);
    }
}

fn printHuman(response: []const u8) !void {
    const out = stdout();
    if (mem.indexOf(u8, response, "\"ok\":true") != null) {
        if (mem.indexOf(u8, response, "\"violations\":[]") != null) {
            try out.writeAll("No violations found.\n");
        } else if (mem.indexOf(u8, response, "\"stopped\":true") != null) {
            try out.writeAll("Server stopped.\n");
        } else {
            try out.writeAll(response);
        }
    } else {
        try stderr().writeAll("Error: ");
        try stderr().writeAll(response);
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
    try stream.writeAll("{\"method\":\"status\"}\n");
    var buf: [65536]u8 = undefined;
    const n = try stream.read(&buf);
    if (n > 0) {
        if (json_output) {
            try stdout().writeAll(buf[0..n]);
        } else {
            try stderr().writeAll("Server is running.\n");
        }
    }
}
