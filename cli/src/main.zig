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

    var json_output = false;
    var file_arg: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else {
            if (file_arg == null) file_arg = arg;
        }
    }

    if (mem.eql(u8, command, "watch")) {
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
        \\  explicit watch             Start server for current project (finds git root)
        \\  explicit status            Show server status
        \\  explicit violations [file] List violations (optionally for one file)
        \\  explicit check <file>      Force re-check a file
        \\  explicit stop              Stop the server
        \\
        \\Flags:
        \\  --json                     Output raw JSON (machine-readable)
        \\
    ) catch {};
}

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

    // Manual hex encode of first 4 bytes
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
    // 1. Same dir as CLI
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

    // 2. ~/.explicit/explicit-server
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const home_bin = try std.fmt.allocPrint(allocator, "{s}/.explicit/explicit-server", .{home});
        if (fs.cwd().statFile(home_bin)) |_| {
            return home_bin;
        } else |_| {
            allocator.free(home_bin);
        }
    } else |_| {}

    // 3. Check PATH
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

    // Check if server already running
    if (net.connectUnixSocket(sock_path)) |stream| {
        stream.close();
        stderr().print("Server already running for {s}\n", .{git_root}) catch {};

        if (json_output) {
            stdout().print("{{\"ok\":true,\"data\":{{\"already_running\":true,\"project\":\"{s}\"}}}}\n", .{git_root}) catch {};
        }
        return;
    } else |_| {}

    // Find server binary
    const server_bin = try findServerBinary(allocator) orelse {
        stderr().writeAll("Error: explicit-server binary not found.\n") catch {};
        stderr().writeAll("Install with: brew install explicit-sh/tap/explicit\n") catch {};
        process.exit(1);
    };
    defer allocator.free(server_bin);

    stderr().print("Starting explicit server for: {s}\n", .{git_root}) catch {};

    // Spawn server as daemon with EXPLICIT_PROJECT_DIR env var
    var child = std.process.Child.init(
        &.{ server_bin, "daemon" },
        allocator,
    );
    child.pgid = 0; // New process group so it survives CLI exit

    // Set project dir via env var (mix release boot scripts don't pass argv cleanly)
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("EXPLICIT_PROJECT_DIR", git_root);
    child.env_map = &env;

    _ = try child.spawn();

    // Wait for socket to appear (up to 5s)
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
