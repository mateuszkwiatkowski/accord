const std = @import("std");

/// Log level for output verbosity
pub const LogLevel = enum {
    quiet,   // Only errors and summary
    normal,  // Changes only (not "already satisfied")
    verbose, // All checks and changes (DEFAULT)
    debug,   // Internal details for debugging
};

/// Global log level (default: verbose)
var current_log_level: LogLevel = .verbose;

/// Color support (disabled if NO_COLOR env var is set)
var color_enabled: bool = true;

/// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const red = "\x1b[31m";
};

/// Initialize output module (check for NO_COLOR)
pub fn init() void {
    if (std.process.hasEnvVarConstant("NO_COLOR")) {
        color_enabled = false;
    }
}

/// Set the current log level
pub fn setLogLevel(level: LogLevel) void {
    current_log_level = level;
}

/// Get the current log level
pub fn getLogLevel() LogLevel {
    return current_log_level;
}

/// Enable or disable color output
pub fn setColorEnabled(enabled: bool) void {
    color_enabled = enabled;
}

/// Log a resource check
/// Format: [CHECK] Resource name... status
pub fn logCheck(resource_type: []const u8, name: []const u8, status: []const u8) void {
    if (@intFromEnum(current_log_level) < @intFromEnum(LogLevel.verbose)) {
        return;
    }

    if (color_enabled) {
        std.debug.print("{s}[CHECK]{s} {s} {s}... {s}{s}{s}\n", .{
            Color.blue,
            Color.reset,
            resource_type,
            name,
            Color.dim,
            status,
            Color.reset,
        });
    } else {
        std.debug.print("[CHECK] {s} {s}... {s}\n", .{ resource_type, name, status });
    }
}

/// Log a resource application
/// Format: [APPLY] Resource name... action
pub fn logApply(resource_type: []const u8, name: []const u8, action: []const u8) void {
    if (@intFromEnum(current_log_level) < @intFromEnum(LogLevel.normal)) {
        return;
    }

    if (color_enabled) {
        std.debug.print("{s}[APPLY]{s} {s} {s}... {s}{s}{s}\n", .{
            Color.green,
            Color.reset,
            resource_type,
            name,
            Color.bold,
            action,
            Color.reset,
        });
    } else {
        std.debug.print("[APPLY] {s} {s}... {s}\n", .{ resource_type, name, action });
    }
}

/// Log an error
/// Format: [ERROR] Resource name: error message
pub fn logError(resource_type: []const u8, name: []const u8, err_msg: []const u8) void {
    // Always log errors regardless of log level
    if (color_enabled) {
        std.debug.print("{s}[ERROR]{s} {s} {s}: {s}{s}{s}\n", .{
            Color.red,
            Color.reset,
            resource_type,
            name,
            Color.bold,
            err_msg,
            Color.reset,
        });
    } else {
        std.debug.print("[ERROR] {s} {s}: {s}\n", .{ resource_type, name, err_msg });
    }
}

/// Log a debug message
/// Format: [DEBUG] message
pub fn logDebug(message: []const u8) void {
    if (current_log_level != .debug) {
        return;
    }

    if (color_enabled) {
        std.debug.print("{s}[DEBUG]{s} {s}\n", .{ Color.dim, Color.reset, message });
    } else {
        std.debug.print("[DEBUG] {s}\n", .{message});
    }
}

/// Log a summary of results
/// Format: Summary: X resources checked, Y applied, Z failed
pub fn logSummary(total: usize, satisfied: usize, applied: usize, failed: usize) void {
    // Always log summary (even in quiet mode)
    if (color_enabled) {
        if (failed > 0) {
            std.debug.print("\n{s}Summary:{s} {d} resources checked, {s}{d} applied{s}, {s}{d} failed{s}\n", .{
                Color.bold,
                Color.reset,
                total,
                Color.green,
                applied,
                Color.reset,
                Color.red,
                failed,
                Color.reset,
            });
        } else if (applied > 0) {
            std.debug.print("\n{s}Summary:{s} {d} resources checked, {s}{d} applied{s}, 0 failed\n", .{
                Color.bold,
                Color.reset,
                total,
                Color.green,
                applied,
                Color.reset,
            });
        } else {
            std.debug.print("\n{s}Summary:{s} {d} resources checked, {s}{d} already satisfied{s}, 0 failed\n", .{
                Color.bold,
                Color.reset,
                total,
                Color.green,
                satisfied,
                Color.reset,
            });
        }
    } else {
        std.debug.print("\nSummary: {d} resources checked, {d} applied, {d} failed\n", .{ total, applied, failed });
    }
}

// Tests
test "log level get/set" {
    const initial = getLogLevel();
    try std.testing.expect(initial == .verbose);

    setLogLevel(.quiet);
    try std.testing.expect(getLogLevel() == .quiet);

    setLogLevel(.debug);
    try std.testing.expect(getLogLevel() == .debug);

    // Reset for other tests
    setLogLevel(.verbose);
}

test "color enable/disable" {
    setColorEnabled(false);
    // Just verify it doesn't crash - manual testing needed for actual output
    logCheck("Package", "nginx", "not installed");
    logApply("File", "/etc/test", "created");
    logError("Service", "nginx", "failed to start");
    logSummary(3, 1, 2, 0);

    setColorEnabled(true);
}

test "log functions don't crash" {
    // Test all log levels
    const levels = [_]LogLevel{ .quiet, .normal, .verbose, .debug };
    for (levels) |level| {
        setLogLevel(level);
        logCheck("Package", "nginx", "installed");
        logApply("File", "/etc/test", "created");
        logError("Service", "nginx", "failed");
        logDebug("Debug message");
        logSummary(10, 5, 3, 2);
    }

    // Reset
    setLogLevel(.verbose);
}
