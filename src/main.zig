const std = @import("std");
const output = @import("output.zig");
const system = @import("system.zig");
const parser = @import("parser.zig");
const apply = @import("apply.zig");

const VERSION = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Initialize output
    output.init(init.environ_map);

    // Parse command-line arguments
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var manifest_path: ?[]const u8 = null;
    var dry_run = false;
    var log_level: ?output.LogLevel = null;
    var seen_apply = false;

    // Simple argument parsing
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--log-level=")) {
            const level_str = arg["--log-level=".len..];
            log_level = parseLogLevel(level_str);
        } else if (std.mem.eql(u8, arg, "apply") and !seen_apply and manifest_path == null) {
            // The only command; options may come before or after it
            seen_apply = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Never take an option for a manifest path: a misspelled
            // --dry-run would otherwise apply for real
            std.debug.print("Error: Unknown option '{s}'\n\n", .{arg});
            printUsage();
            std.process.exit(1);
        } else if (manifest_path == null) {
            manifest_path = arg;
        } else {
            std.debug.print("Error: Unexpected argument '{s}'\n\n", .{arg});
            printUsage();
            std.process.exit(1);
        }
    }

    // Set log level if specified
    if (log_level) |level| {
        output.setLogLevel(level);
    }

    // Require manifest path
    if (manifest_path == null) {
        std.debug.print("Error: No manifest specified\n\n", .{});
        printUsage();
        std.process.exit(1);
    }

    // Detect system
    output.logDebug("Detecting system...");
    const sys = try system.SystemInfo.detect(allocator, io);
    output.logDebug("System detection complete");

    // Read manifest file
    const manifest_content = std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path.?,
        allocator,
        .limited(1024 * 1024), // 1MB max
    ) catch |err| {
        std.debug.print("Error: Failed to read manifest file: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer allocator.free(manifest_content);

    // Parse manifest
    output.logDebug("Parsing manifest...");
    var parse_message: ?[]u8 = null;
    defer if (parse_message) |m| allocator.free(m);
    var manifest = parser.parseReporting(allocator, manifest_content, manifest_path.?, &parse_message) catch |err| {
        if (parse_message) |m| {
            std.debug.print("{s}\n", .{m});
        } else {
            std.debug.print("Error: Failed to parse manifest: {s}\n", .{@errorName(err)});
        }
        std.process.exit(2);
    };
    defer manifest.deinit();

    // Apply manifest
    if (dry_run) {
        std.debug.print("DRY RUN - no changes will be made\n\n", .{});
    }

    const result = apply.applyManifest(&manifest, &sys, dry_run) catch |err| {
        std.debug.print("\nError: Failed to apply manifest: {s}\n", .{@errorName(err)});
        std.process.exit(4);
    };

    // Print summary
    output.logSummary(result.total, result.satisfied, result.applied, result.failed);

    // Exit with appropriate code
    if (result.failed > 0) {
        std.process.exit(4);
    }
}

fn printVersion() void {
    std.debug.print("accord version {s}\n", .{VERSION});
}

fn printUsage() void {
    std.debug.print("Usage: accord apply [OPTIONS] MANIFEST\n", .{});
    std.debug.print("Try 'accord --help' for more information.\n", .{});
}

fn printHelp() void {
    std.debug.print(
        \\accord - Lightweight configuration management
        \\
        \\USAGE:
        \\    accord apply [OPTIONS] MANIFEST
        \\
        \\OPTIONS:
        \\    -n, --dry-run              Show what would change without modifying anything
        \\    --log-level=LEVEL          Set logging verbosity: quiet, normal, verbose (default), debug
        \\    -V, --version              Show version information
        \\    -h, --help                 Show this help message
        \\
        \\EXAMPLES:
        \\    accord apply manifest.zon
        \\    accord apply --dry-run manifest.zon
        \\    accord apply --log-level=debug manifest.zon
        \\
        \\EXIT CODES:
        \\    0    Success
        \\    1    General error
        \\    2    Invalid manifest
        \\    3    Permission denied
        \\    4    Resource operation failed
        \\
    , .{});
}

fn parseLogLevel(level_str: []const u8) output.LogLevel {
    if (std.mem.eql(u8, level_str, "quiet")) {
        return .quiet;
    } else if (std.mem.eql(u8, level_str, "normal")) {
        return .normal;
    } else if (std.mem.eql(u8, level_str, "verbose")) {
        return .verbose;
    } else if (std.mem.eql(u8, level_str, "debug")) {
        return .debug;
    }
    return .verbose; // default
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("output.zig");
    _ = @import("system.zig");
    _ = @import("resources/resource.zig");
    _ = @import("resources/directory.zig");
    _ = @import("resources/file.zig");
    _ = @import("resources/package.zig");
    _ = @import("resources/package_cache.zig");
    _ = @import("resources/service.zig");
    _ = @import("resources/group.zig");
    _ = @import("resources/user.zig");
    _ = @import("utils.zig");
    _ = @import("parser.zig");
    _ = @import("apply.zig");
}
