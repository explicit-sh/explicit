const std = @import("std");
const fs = std.fs;
const net = std.net;
const mem = std.mem;
const process = std.process;
const templates = @import("templates.zig");

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
            if (sub1 == null) sub1 = arg;
            if (sub2 == null and sub1 != null and !mem.eql(u8, arg, sub1.?)) sub2 = arg;
            if (file_arg == null) file_arg = arg;
        }
    }

    if (mem.eql(u8, command, "init")) {
        try cmdInit(allocator, sub1);
    } else if (mem.eql(u8, command, "docs")) {
        try cmdDocs(allocator, sub1, sub2, json_output);
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
        \\explicit — Elixir code analysis + documentation tool
        \\
        \\Usage:
        \\  explicit init <name>       Scaffold a full-stack Elixir monorepo
        \\  explicit watch             Start server for current project
        \\  explicit status            Show server status
        \\  explicit violations [file] List code violations
        \\  explicit check <file>      Force re-check a file
        \\  explicit docs <subcmd>     Document management (see below)
        \\  explicit stop              Stop the server
        \\  explicit hooks claude stop Claude Code stop hook (internal)
        \\
        \\Document commands:
        \\  explicit docs validate     Validate all docs against schema
        \\  explicit docs new <type> <title>  Create new document
        \\  explicit docs list [--type T]     List documents
        \\  explicit docs get <id>     Show document details
        \\  explicit docs describe [type]     Describe schema types
        \\
        \\Flags:
        \\  --json                     Output raw JSON
        \\
    ) catch {};
}

// ─── Init command ────────────────────────────────────────────────────────────

fn cmdInit(allocator: mem.Allocator, name_arg: ?[]const u8) !void {
    const name = name_arg orelse {
        try stderr().writeAll("Usage: explicit init <project_name>\n");
        try stderr().writeAll("Example: explicit init my_app\n");
        process.exit(1);
    };

    // Validate name (must be valid Elixir module name)
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            stderr().print("Error: '{s}' is not a valid project name (use snake_case)\n", .{name}) catch {};
            process.exit(1);
        }
    }

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&path_buf);

    stderr().print("Initializing {s} monorepo...\n\n", .{name}) catch {};

    // 1. Create directory structure
    try createDirs(allocator, cwd);

    // 2. git init
    try runCmd(allocator, &.{ "git", "init" }, "git");

    // 3. Write template files
    try writeTemplate(allocator, cwd, ".gitignore", templates.gitignore, name);
    try writeTemplate(allocator, cwd, "devenv.nix", templates.devenv_nix, name);
    try writeTemplate(allocator, cwd, "Makefile", templates.makefile, name);
    try writeTemplate(allocator, cwd, "CLAUDE.md", templates.claude_md_template, name);
    try writeTemplate(allocator, cwd, "infrastructure/environments/dev/main.tf", templates.tf_main, name);
    try writeTemplate(allocator, cwd, "clients/ios/README.md", templates.ios_readme, name);
    try writeTemplate(allocator, cwd, "clients/android/README.md", templates.android_readme, name);

    // 4. .explicit/ config + docs structure
    try writeTemplate(allocator, cwd, ".explicit/org.kdl", templates.org_kdl, name);
    try copySchemaKdl(allocator, cwd);
    try writeTemplate(allocator, cwd, "docs/README.md", templates.docs_readme, name);

    // 5. .claude/ config
    try mkdirSafe(allocator, cwd, ".claude");
    try writeTemplate(allocator, cwd, ".claude/settings.json", templates.claude_settings, name);

    // 5. Phoenix app (runs mix phx.new, but NOT deps.get yet)
    try initPhoenix(allocator, name);

    // 6. .credo.exs inside services/elixir
    try writeTemplate(allocator, cwd, "services/elixir/.credo.exs", templates.credo_exs, name);

    // 7. Add boundary dep to mix.exs (before deps.get)
    try addBoundaryDep(allocator, cwd, name);

    // 8. Install deps (after all mix.exs modifications)
    try installDeps(allocator);

    stderr().writeAll(
        \\
        \\Done! Next steps:
        \\
        \\  1. cd into the project directory
        \\  2. devenv shell           # Enter dev environment
        \\  3. make setup             # Install deps + create DB
        \\  4. make dev               # Start Phoenix server
        \\  5. explicit watch         # Start code analysis server
        \\
    ) catch {};
}

fn createDirs(allocator: mem.Allocator, cwd: []const u8) !void {
    const dirs = [_][]const u8{
        "services",
        "services/elixir",
        "clients",
        "clients/ios",
        "clients/android",
        "infrastructure",
        "infrastructure/environments",
        "infrastructure/environments/dev",
        "infrastructure/environments/staging",
        "infrastructure/environments/prod",
        "infrastructure/modules",
        "docs",
        "docs/architecture",
        "docs/opportunities",
        "docs/policies",
        "docs/incidents",
        "docs/specs",
        "docs/processes",
        "docs/assets",
        ".explicit",
        ".claude",
    };

    for (dirs) |dir| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, dir });
        defer allocator.free(full);
        fs.makeDirAbsolute(full) catch {};
    }
    stderr().writeAll("dirs: created project structure\n") catch {};
}

fn mkdirSafe(allocator: mem.Allocator, cwd: []const u8, rel: []const u8) !void {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, rel });
    defer allocator.free(full);
    fs.makeDirAbsolute(full) catch {};
}

fn writeTemplate(allocator: mem.Allocator, cwd: []const u8, rel_path: []const u8, template: []const u8, name: []const u8) !void {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, rel_path });
    defer allocator.free(full);

    // Don't overwrite existing files
    if (fs.cwd().statFile(full)) |_| {
        stderr().print("{s}: already exists, skipping\n", .{rel_path}) catch {};
        return;
    } else |_| {}

    // Replace {NAME} placeholder with actual name
    const content = try std.mem.replaceOwned(u8, allocator, template, "{NAME}", name);
    defer allocator.free(content);

    // Ensure parent dir exists
    if (std.fs.path.dirname(full)) |parent| {
        fs.makeDirAbsolute(parent) catch {};
    }

    const file = try fs.createFileAbsolute(full, .{});
    defer file.close();
    try file.writeAll(content);

    stderr().print("{s}: created\n", .{rel_path}) catch {};
}

fn initPhoenix(allocator: mem.Allocator, name: []const u8) !void {
    // Check if Phoenix already scaffolded
    if (fs.cwd().statFile("services/elixir/mix.exs")) |_| {
        stderr().writeAll("phoenix: services/elixir/mix.exs exists, skipping\n") catch {};
        return;
    } else |_| {}

    // Try running mix phx.new
    stderr().writeAll("phoenix: scaffolding with mix phx.new...\n") catch {};

    var child = std.process.Child.init(
        &.{ "mix", "phx.new", "services/elixir", "--app", name, "--no-install" },
        allocator,
    );
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    _ = child.spawn() catch {
        printMixMissing(name);
        return;
    };
    const term = child.wait() catch {
        printMixMissing(name);
        return;
    };

    if (term.Exited == 0) {
        stderr().writeAll("phoenix: scaffolded\n") catch {};
    } else {
        stderr().writeAll("phoenix: mix phx.new failed\n") catch {};
        stderr().writeAll("  Install Phoenix: mix archive.install hex phx_new\n") catch {};
        stderr().writeAll("  Then run: mix phx.new services/elixir --app ") catch {};
        stderr().writeAll(name) catch {};
        stderr().writeAll(" --no-install\n") catch {};
    }
}

fn printMixMissing(name: []const u8) void {
    stderr().writeAll("phoenix: 'mix' not found in PATH\n") catch {};
    stderr().writeAll("  Install Elixir first: brew install elixir\n") catch {};
    stderr().writeAll("  Then run: mix archive.install hex phx_new\n") catch {};
    stderr().print("  Then run: mix phx.new services/elixir --app {s} --no-install\n", .{name}) catch {};
}

fn addBoundaryDep(allocator: mem.Allocator, cwd: []const u8, name: []const u8) !void {
    _ = name;
    const mix_path = try std.fmt.allocPrint(allocator, "{s}/services/elixir/mix.exs", .{cwd});
    defer allocator.free(mix_path);

    const content = fs.cwd().readFileAlloc(allocator, mix_path, 1024 * 1024) catch {
        stderr().writeAll("boundary: no mix.exs found, skipping\n") catch {};
        return;
    };
    defer allocator.free(content);

    // Check if boundary already added
    if (mem.indexOf(u8, content, "boundary") != null) {
        stderr().writeAll("boundary: already in mix.exs\n") catch {};
        return;
    }

    // Find the deps list and inject boundary
    if (mem.indexOf(u8, content, "{:phoenix,")) |pos| {
        const new_content = try std.fmt.allocPrint(allocator, "{s}{{:boundary, \"~> 0.10\"}},\n      {s}", .{ content[0..pos], content[pos..] });
        defer allocator.free(new_content);

        const file = try fs.createFileAbsolute(mix_path, .{});
        defer file.close();
        try file.writeAll(new_content);
        stderr().writeAll("boundary: added to mix.exs\n") catch {};
    } else {
        stderr().writeAll("boundary: couldn't find deps list, add {:boundary, \"~> 0.10\"} manually\n") catch {};
    }
}

fn installDeps(allocator: mem.Allocator) !void {
    stderr().writeAll("deps: installing...\n") catch {};
    var child = std.process.Child.init(
        &.{ "mix", "deps.get" },
        allocator,
    );
    child.cwd = "services/elixir";
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    _ = child.spawn() catch {
        stderr().writeAll("deps: mix not found, skipping\n") catch {};
        return;
    };
    const term = child.wait() catch {
        stderr().writeAll("deps: mix not found, skipping\n") catch {};
        return;
    };
    if (term.Exited == 0) {
        stderr().writeAll("deps: installed\n") catch {};
    } else {
        stderr().writeAll("deps: mix deps.get failed (run manually in services/elixir/)\n") catch {};
    }
}

fn copySchemaKdl(allocator: mem.Allocator, cwd: []const u8) !void {
    const dest = try std.fmt.allocPrint(allocator, "{s}/.explicit/schema.kdl", .{cwd});
    defer allocator.free(dest);

    // Don't overwrite
    if (fs.cwd().statFile(dest)) |_| {
        stderr().writeAll(".explicit/schema.kdl: already exists, skipping\n") catch {};
        return;
    } else |_| {}

    // Try to find schema.kdl from server install
    var exe_buf: [fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExePath(&exe_buf)) |exe_path| {
        if (std.fs.path.dirname(exe_path)) |exe_dir| {
            // Look for ../lib/explicit_server/lib/explicit-*/priv/schema.kdl
            // TODO: search sibling lib dir for installed schema.kdl
            _ = exe_dir;
        }
    } else |_| {}

    // Fallback: write a minimal schema
    const file = fs.createFileAbsolute(dest, .{}) catch {
        stderr().writeAll(".explicit/schema.kdl: failed to create\n") catch {};
        return;
    };
    defer file.close();
    file.writeAll(
        \\// Explicit schema — see https://github.com/explicit-sh/explicit
        \\// Full schema available after: brew install explicit-sh/tap/explicit
        \\
        \\relation "supersedes" inverse="superseded_by" cardinality="one"
        \\relation "implements" inverse="implemented_by" cardinality="many"
        \\relation "depends_on" inverse="dependency_of" cardinality="many"
        \\relation "related" cardinality="many"
        \\
        \\type "adr" description="Architecture Decision Record" folder="docs/architecture" {
        \\    alias "architecture"
        \\    field "status" type="enum" required=true default="proposed" {
        \\        values "proposed" "accepted" "rejected" "deprecated" "superseded"
        \\    }
        \\    field "author" type="user" required=true
        \\    field "date" type="string" required=true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        \\    field "tags" type="string[]"
        \\    field "code_paths" type="string[]"
        \\    section "Context" required=true
        \\    section "Decision" required=true
        \\    section "Consequences" required=true {
        \\        section "Positive" required=true
        \\        section "Negative"
        \\    }
        \\}
        \\
        \\type "opp" description="Opportunity" folder="docs/opportunities" {
        \\    alias "opportunity"
        \\    field "status" type="enum" required=true default="identified" {
        \\        values "identified" "validating" "pursuing" "completed" "deprecated"
        \\    }
        \\    field "author" type="user" required=true
        \\    field "date" type="string" required=true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        \\    field "tags" type="string[]"
        \\    section "Description" required=true
        \\}
        \\
        \\type "pol" description="Policy" folder="docs/policies" {
        \\    alias "policy"
        \\    field "status" type="enum" required=true default="proposed" {
        \\        values "proposed" "active" "deprecated" "superseded"
        \\    }
        \\    field "author" type="user" required=true
        \\    field "date" type="string" required=true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        \\    section "Purpose" required=true
        \\    section "Policy" required=true
        \\    section "Scope" required=true
        \\}
        \\
        \\type "inc" description="Incident Report" folder="docs/incidents" {
        \\    alias "incident"
        \\    field "status" type="enum" required=true default="open" {
        \\        values "open" "mitigated" "resolved"
        \\    }
        \\    field "severity" type="enum" required=true {
        \\        values "sev1" "sev2" "sev3" "sev4"
        \\    }
        \\    field "author" type="user" required=true
        \\    field "date" type="string" required=true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        \\    section "Summary" required=true
        \\    section "Root Cause" required=true
        \\}
        \\
        \\type "spec" description="Behavioral Specification" folder="docs/specs" {
        \\    alias "feature"
        \\    field "status" type="enum" required=true default="draft" {
        \\        values "draft" "proposed" "approved" "implemented" "deprecated"
        \\    }
        \\    field "author" type="user" required=true
        \\    field "date" type="string" required=true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        \\    section "Story" required=true
        \\    section "Scenarios" required=true
        \\}
        \\
    ) catch {};
    stderr().writeAll(".explicit/schema.kdl: created (minimal)\n") catch {};
}

fn runCmd(allocator: mem.Allocator, argv: []const []const u8, label: []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawn();
    const term = try child.wait();
    if (term.Exited == 0) {
        stderr().print("{s}: done\n", .{label}) catch {};
    } else {
        stderr().print("{s}: failed (exit {d})\n", .{ label, term.Exited }) catch {};
    }
}

// ─── Docs command ────────────────────────────────────────────────────────────

fn cmdDocs(allocator: mem.Allocator, sub1: ?[]const u8, sub2: ?[]const u8, json_output: bool) !void {
    const subcmd = sub1 orelse {
        stderr().writeAll("Usage: explicit docs <validate|new|list|get|describe>\n") catch {};
        process.exit(1);
    };

    if (mem.eql(u8, subcmd, "validate")) {
        try cmdSend(allocator, "{\"method\":\"doc.validate\"}\n", json_output);
    } else if (mem.eql(u8, subcmd, "list")) {
        if (sub2) |type_filter| {
            const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.list\",\"params\":{{\"type\":\"{s}\"}}}}\n", .{type_filter});
            defer allocator.free(req);
            try cmdSend(allocator, req, json_output);
        } else {
            try cmdSend(allocator, "{\"method\":\"doc.list\"}\n", json_output);
        }
    } else if (mem.eql(u8, subcmd, "new")) {
        const type_name = sub2 orelse {
            stderr().writeAll("Usage: explicit docs new <type> <title>\n") catch {};
            stderr().writeAll("Types: adr, opp, pol, inc, spec, proc\n") catch {};
            process.exit(1);
        };
        // For now, title comes from remaining args — but we only captured sub2.
        // Use type as both type and a placeholder title prompt.
        // TODO: parse title from remaining args properly
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.new\",\"params\":{{\"type\":\"{s}\",\"title\":\"Untitled\"}}}}\n", .{type_name});
        defer allocator.free(req);
        try cmdSend(allocator, req, json_output);
    } else if (mem.eql(u8, subcmd, "get")) {
        const id = sub2 orelse {
            stderr().writeAll("Usage: explicit docs get <id>\n") catch {};
            process.exit(1);
        };
        const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.get\",\"params\":{{\"id\":\"{s}\"}}}}\n", .{id});
        defer allocator.free(req);
        try cmdSend(allocator, req, json_output);
    } else if (mem.eql(u8, subcmd, "describe")) {
        if (sub2) |type_name| {
            const req = try std.fmt.allocPrint(allocator, "{{\"method\":\"doc.describe\",\"params\":{{\"type\":\"{s}\"}}}}\n", .{type_name});
            defer allocator.free(req);
            try cmdSend(allocator, req, json_output);
        } else {
            try cmdSend(allocator, "{\"method\":\"doc.describe\"}\n", json_output);
        }
    } else if (mem.eql(u8, subcmd, "diagnostics")) {
        try cmdSend(allocator, "{\"method\":\"doc.diagnostics\"}\n", json_output);
    } else {
        stderr().print("Unknown docs command: {s}\n", .{subcmd}) catch {};
        process.exit(1);
    }
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

fn hookClaudeStop(allocator: mem.Allocator) !void {
    const git_root = findGitRoot(allocator) catch {
        process.exit(0);
    };
    defer allocator.free(git_root);

    const sock_path = try socketPathForDir(allocator, git_root);
    defer allocator.free(sock_path);

    var has_issues = false;

    // Check code violations
    {
        var stream = net.connectUnixSocket(sock_path) catch { process.exit(0); };
        defer stream.close();
        stream.writeAll("{\"method\":\"violations\"}\n") catch { process.exit(0); };
        var buf: [65536]u8 = undefined;
        const n = stream.read(&buf) catch { process.exit(0); };
        if (n > 0) {
            const response = buf[0..n];
            if (mem.indexOf(u8, response, "\"total\":0") == null) {
                stderr().writeAll(response) catch {};
                has_issues = true;
            }
        }
    }

    // Check doc diagnostics
    {
        var stream = net.connectUnixSocket(sock_path) catch { process.exit(0); };
        defer stream.close();
        stream.writeAll("{\"method\":\"doc.diagnostics\"}\n") catch { process.exit(0); };
        var buf: [65536]u8 = undefined;
        const n = stream.read(&buf) catch { process.exit(0); };
        if (n > 0) {
            const response = buf[0..n];
            if (mem.indexOf(u8, response, "\"errors\":0") == null) {
                stderr().writeAll(response) catch {};
                has_issues = true;
            }
        }
    }

    if (has_issues) process.exit(2);
    process.exit(0);
}

// ─── Socket/server helpers ───────────────────────────────────────────────────

fn findGitRoot(allocator: mem.Allocator) ![]const u8 {
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&path_buf);

    var dir = try allocator.dupe(u8, cwd);

    while (true) {
        const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
        defer allocator.free(git_path);

        if (fs.accessAbsolute(git_path, .{})) {
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
