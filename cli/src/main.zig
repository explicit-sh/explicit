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
    } else if (mem.eql(u8, command, "claude")) {
        try cmdLaunchAI(allocator, "claude", &.{ "--dangerously-skip-permissions", "--append-system-prompt-file" }, positional[0..pos_count]);
        return;
    } else if (mem.eql(u8, command, "gemini")) {
        try cmdLaunchAI(allocator, "gemini", &.{"-i"}, positional[0..pos_count]);
        return;
    } else if (mem.eql(u8, command, "init") and p0 != null) {
        // init <name>: create project dir + git init, then start server there
        try cmdInitNew(allocator, p0.?);
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
        \\  explicit validate          Validate docs + code (blocks code_paths)
        \\  explicit status            Show server status
        \\  explicit quality           Quality gate report (tests, docs, lint)
        \\  explicit test              Run mix test
        \\  explicit violations [file] List code violations
        \\  explicit check <file>      Force re-check a file
        \\  explicit claude            Launch Claude Code with explicit context
        \\  explicit gemini            Launch Gemini CLI with explicit context
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

/// Stop hook: unified quality gate — checks violations, docs, tests, specs, runs tests
fn hookClaudeStop(allocator: mem.Allocator) !void {
    const git_root = findGitRoot(allocator) catch { process.exit(0); };
    defer allocator.free(git_root);
    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    var has_issues = false;

    // Check quality (violations + doc errors + missing tests/docs/specs)
    has_issues = has_issues or try checkMethod(sock_path, "{\"method\":\"quality\"}\n", "\"clean\":true");

    // Run mix test
    has_issues = has_issues or try checkMethod(sock_path, "{\"method\":\"test.run\"}\n", "\"passed\":true");

    // Check mix format
    {
        var fmt = std.process.Child.init(&.{ "mix", "format", "--check-formatted" }, allocator);
        fmt.cwd = git_root;
        fmt.stdout_behavior = .Ignore;
        fmt.stderr_behavior = .Pipe;
        if (fmt.spawn()) |_| {} else |_| {
            // mix not found, skip
        }
        if (fmt.wait()) |term| {
            if (term.Exited != 0) {
                stderr().writeAll("Code is not formatted. Run: mix format\n") catch {};
                has_issues = true;
            }
        } else |_| {}
    }

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

// ─── Init new project ────────────────────────────────────────────────────────

fn cmdInitNew(allocator: mem.Allocator, name: []const u8) !void {
    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&cwd_buf) catch {
        stderr().writeAll("Error: Cannot get current directory\n") catch {};
        process.exit(1);
    };

    const project_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, name });
    defer allocator.free(project_dir);

    // Create project directory
    fs.makeDirAbsolute(project_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            stderr().print("Error: Directory {s} already exists.\n", .{name}) catch {};
            process.exit(1);
        },
        else => {
            stderr().print("Error: Cannot create directory {s}\n", .{name}) catch {};
            process.exit(1);
        },
    };

    stderr().print("Creating {s}...\n", .{name}) catch {};

    // git init
    runIn(allocator, project_dir, &.{ "git", "init" });

    // devenv init
    runIn(allocator, project_dir, &.{ "devenv", "init" });

    // Write devenv.nix with Elixir + PostgreSQL + Tailwind + esbuild
    {
        const devenv_path = try std.fmt.allocPrint(allocator, "{s}/devenv.nix", .{project_dir});
        defer allocator.free(devenv_path);
        const f = fs.createFileAbsolute(devenv_path, .{}) catch {
            stderr().writeAll("Warning: could not write devenv.nix\n") catch {};
            return;
        };
        defer f.close();
        const devenv_content = try std.fmt.allocPrint(allocator,
            \\{{ pkgs, lib, config, inputs, ... }}:
            \\
            \\let
            \\  elixir_1_20_rc4 = pkgs.beam28Packages.elixir_1_20.overrideAttrs (old: rec {{
            \\    version = "1.20.0-rc.4";
            \\    src = pkgs.fetchFromGitHub {{
            \\      owner = "elixir-lang";
            \\      repo = "elixir";
            \\      rev = "v${{version}}";
            \\      hash = "sha256-sboB+GW3T+t9gEcOGtd6NllmIlyWio1+cgWyyxE+484=";
            \\    }};
            \\    doCheck = false;
            \\  }});
            \\in
            \\{{
            \\  languages.elixir = {{
            \\    enable = true;
            \\    package = elixir_1_20_rc4;
            \\  }};
            \\
            \\  languages.erlang = {{
            \\    enable = true;
            \\    package = pkgs.beam.interpreters.erlang_28;
            \\  }};
            \\
            \\  services.postgres = {{
            \\    enable = true;
            \\    listen_addresses = "127.0.0.1";
            \\  }};
            \\
            \\  packages = [
            \\    pkgs.git
            \\    pkgs.tailwindcss
            \\    pkgs.esbuild
            \\    pkgs.opentofu
            \\  ];
            \\
            \\  enterShell = ''
            \\    echo "{s} dev environment"
            \\    echo "Elixir $(elixir --version | tail -1)"
            \\  '';
            \\}}
            \\
        , .{name});
        defer allocator.free(devenv_content);
        f.writeAll(devenv_content) catch {};
    }

    // Create minimal directory structure
    const dirs = [_][]const u8{
        "docs", "docs/architecture", "docs/opportunities", "docs/policies",
        "docs/incidents", "docs/specs", ".explicit", ".claude",
    };
    for (dirs) |dir| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir });
        defer allocator.free(full);
        fs.makeDirAbsolute(full) catch {};
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
            stderr().print("Created {s}/ (server not available — run 'explicit init' inside to finish setup)\n", .{name}) catch {};
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
                stream.writeAll("{\"method\":\"init\"}\n") catch {};
                var buf: [65536]u8 = undefined;
                const n = stream.read(&buf) catch 0;
                if (n > 0) {
                    try printHuman(buf[0..n]);
                }
                stream.close();

                // Stop server
                if (net.connectUnixSocket(new_sock)) |s2| {
                    s2.writeAll("{\"method\":\"stop\"}\n") catch {};
                    s2.close();
                } else |_| {}

                stderr().print("\nReady! Next:\n  cd {s}\n  explicit claude\n", .{name}) catch {};
                return;
            } else |_| {}
        }

        stderr().print("Created {s}/ (server timed out — run 'explicit init' inside to finish)\n", .{name}) catch {};
    } else {
        stderr().print("Created {s}/\nNext:\n  cd {s}\n  explicit init\n  explicit claude\n", .{ name, name }) catch {};
    }
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

fn cmdLaunchAI(allocator: mem.Allocator, tool_name: []const u8, prompt_flag: []const []const u8, extra_args: []const ?[]const u8) !void {
    // 1. Connect to server (auto-starts if needed)
    var stream = try connectToSocket(allocator);

    // 2. Fetch system prompt
    const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"system_prompt\",\"params\":{{\"tool\":\"{s}\"}}}}\n", .{tool_name});
    defer allocator.free(req);
    try stream.writeAll(req);

    var buf: [65536]u8 = undefined;
    const n = try stream.read(&buf);
    stream.close();

    if (n == 0) {
        stderr().writeAll("Error: Empty response from server\n") catch {};
        process.exit(1);
    }

    // 3. Extract prompt text from JSON response
    const response = buf[0..n];
    const prompt = extractJsonString(response, "\"prompt\":\"") orelse {
        stderr().writeAll("Error: Could not extract system prompt\n") catch {};
        process.exit(1);
    };

    // Unescape \\n to real newlines and write to temp file
    const unescaped = try std.mem.replaceOwned(u8, allocator, prompt, "\\n", "\n");
    defer allocator.free(unescaped);

    const prompt_path = "/tmp/explicit-system-prompt.txt";
    {
        const f = try fs.createFileAbsolute(prompt_path, .{});
        defer f.close();
        try f.writeAll(unescaped);
    }
    const prompt_arg: []const u8 = prompt_path;

    // If devenv.nix exists but we're not inside devenv shell, re-exec through devenv
    const devenv_dir = findDevenvDir(allocator);
    defer if (devenv_dir) |d| allocator.free(d);
    const in_devenv = std.process.getEnvVarOwned(allocator, "DEVENV_ROOT") catch null;
    defer if (in_devenv) |v| allocator.free(v);

    if (devenv_dir) |d| {
        if (in_devenv == null) {
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
            reexec_buf[rc] = "devenv"; rc += 1;
            reexec_buf[rc] = "shell"; rc += 1;
            reexec_buf[rc] = "--"; rc += 1;
            reexec_buf[rc] = self_path; rc += 1;
            reexec_buf[rc] = tool_name; rc += 1;
            // Pass through extra args
            for (extra_args) |ea| {
                if (ea) |a| {
                    if (rc < reexec_buf.len) { reexec_buf[rc] = a; rc += 1; }
                }
            }

            var reexec = std.process.Child.init(reexec_buf[0..rc], allocator);
            reexec.stdin_behavior = .Inherit;
            reexec.stdout_behavior = .Inherit;
            reexec.stderr_behavior = .Inherit;
            reexec.cwd = d;
            _ = try reexec.spawn();
            const rt = try reexec.wait();
            process.exit(rt.Exited);
        }
    }

    // Check if nono is available
    const has_nono = blk: {
        var check = std.process.Child.init(&.{ "nono", "--version" }, allocator);
        check.stdout_behavior = .Ignore;
        check.stderr_behavior = .Ignore;
        _ = check.spawn() catch break :blk false;
        const t = check.wait() catch break :blk false;
        break :blk t.Exited == 0;
    };

    if (has_nono) {
        stderr().print("Starting {s} with nono sandbox...\n", .{tool_name}) catch {};
    } else {
        stderr().print("Starting {s}...\n", .{tool_name}) catch {};
        stderr().writeAll("Warning: nono not found, running without sandbox. Install: brew install nono\n") catch {};
    }

    // Build argv: [nono wrap --profile claude-code --allow . --] tool [flags] prompt [extra]
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;

    if (has_nono) {
        argv_buf[argc] = "nono"; argc += 1;
        argv_buf[argc] = "wrap"; argc += 1;
        argv_buf[argc] = "--profile"; argc += 1;
        argv_buf[argc] = "claude-code"; argc += 1;
        argv_buf[argc] = "--allow"; argc += 1;
        argv_buf[argc] = "."; argc += 1;
        argv_buf[argc] = "--"; argc += 1;
    }

    // The actual AI tool command
    argv_buf[argc] = tool_name; argc += 1;
    for (prompt_flag) |flag| {
        argv_buf[argc] = flag; argc += 1;
    }
    argv_buf[argc] = prompt_arg; argc += 1;

    // Pass through extra args (e.g. -c, -p "prompt", --model, etc)
    for (extra_args) |arg| {
        if (arg) |a| {
            if (argc < argv_buf.len) {
                argv_buf[argc] = a;
                argc += 1;
            }
        }
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

    // Add our bin dir to PATH so hooks can find `explicit`
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    var exe_buf: [fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExePath(&exe_buf)) |exe_path| {
        if (std.fs.path.dirname(exe_path)) |exe_dir| {
            if (env.get("PATH")) |existing_path| {
                const new_path = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ exe_dir, existing_path });
                try env.put("PATH", new_path);
            }
        }
    } else |_| {}
    child.env_map = &env;

    _ = try child.spawn();
    const term = try child.wait();
    process.exit(term.Exited);
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

        const parent = std.fs.path.dirname(dir) orelse { allocator.free(dir); return null; };
        if (mem.eql(u8, parent, dir)) { allocator.free(dir); return null; }
        const parent_owned = allocator.dupe(u8, parent) catch { allocator.free(dir); return null; };
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
        try out.writeAll("Quality: clean\n");
        return;
    }
    if (mem.indexOf(u8, response, "\"clean\":false") != null) {
        try out.writeAll("Quality: issues found\n");
        printIfNonZero(out, response, "\"iron_law_violations\":", "  Iron law violations") catch {};
        printIfNonZero(out, response, "\"missing_tests\":", "  Missing test files") catch {};
        printIfNonZero(out, response, "\"missing_docs\":", "  Missing @doc") catch {};
        printIfNonZero(out, response, "\"missing_specs\":", "  Missing @spec") catch {};
        printIfNonZero(out, response, "\"doc_errors\":", "  Doc validation errors") catch {};
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
        // Print each violation message
        var it = mem.splitSequence(u8, response, "\"message\":\"");
        _ = it.next(); // skip prefix
        while (it.next()) |chunk| {
            if (mem.indexOf(u8, chunk, "\"")) |end| {
                try out.writeAll("  ");
                try out.writeAll(chunk[0..end]);
                try out.writeAll("\n");
            }
        }
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
        // List created files
        var it = mem.splitSequence(u8, response, "\"created\":[\"");
        _ = it.next();
        if (it.next()) |chunk| {
            if (mem.indexOf(u8, chunk, "]")) |end| {
                const files_str = chunk[0..end];
                var fit = mem.splitSequence(u8, files_str, "\",\"");
                try out.writeAll("Created:\n");
                while (fit.next()) |f| {
                    const clean = mem.trimRight(u8, f, "\"");
                    if (clean.len > 0) {
                        try out.writeAll("  ");
                        try out.writeAll(clean);
                        try out.writeAll("\n");
                    }
                }
            }
        }
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
