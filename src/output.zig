const std = @import("std");

/// Log level for output verbosity
pub const LogLevel = enum {
    quiet, // Only errors and summary
    normal, // Changes only (not "already satisfied")
    verbose, // All checks and changes (DEFAULT)
    debug, // Internal details for debugging
};

/// Global log level (default: verbose)
var current_log_level: LogLevel = .verbose;

/// Color support (disabled if NO_COLOR env var is set)
/// DISABLED BY DEFAULT: workaround for Zig std.debug.print bug with ANSI codes
var color_enabled: bool = false;

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
    // Truncate heavily to avoid std.debug.print infinite loop bug
    // https://github.com/ziglang/zig/issues/XXXXX
    const max_len = 80; // Very conservative limit
    const truncated = if (err_msg.len > max_len)
        err_msg[0..max_len]
    else
        err_msg;

    // Filter out any non-printable characters except newlines
    var safe_buf: [80]u8 = undefined;
    var safe_len: usize = 0;
    for (truncated) |c| {
        if (safe_len >= safe_buf.len) break;
        if (std.ascii.isPrint(c) or c == '\n') {
            safe_buf[safe_len] = c;
            safe_len += 1;
        }
    }
    const safe_msg = safe_buf[0..safe_len];

    // Always log errors regardless of log level
    if (color_enabled) {
        std.debug.print("{s}[ERROR]{s} {s} {s}: {s}{s}{s}\n", .{
            Color.red,
            Color.reset,
            resource_type,
            name,
            Color.bold,
            safe_msg,
            Color.reset,
        });
    } else {
        std.debug.print("[ERROR] {s} {s}: {s}\n", .{ resource_type, name, safe_msg });
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

/// Strip ANSI escape codes from input string
/// Returns a new string with all ANSI codes removed
fn stripAnsiCodes(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) {
        // Return empty allocated string that can be freed
        return allocator.dupe(u8, "");
    }

    // Allocate max possible size (input length)
    var result = try allocator.alloc(u8, input.len);
    errdefer allocator.free(result);
    var result_idx: usize = 0;

    var i: usize = 0;
    while (i < input.len) {
        // Check for ANSI escape sequence: ESC[...letter
        if (i + 1 < input.len and input[i] == 0x1b and input[i + 1] == '[') {
            // Found ANSI escape sequence
            i += 2; // Skip ESC and [

            // Skip until we find an alphabetic character
            while (i < input.len and !std.ascii.isAlphabetic(input[i])) {
                i += 1;
            }

            // Skip the final letter
            if (i < input.len) {
                i += 1;
            }
        } else {
            // Regular character, append it
            result[result_idx] = input[i];
            result_idx += 1;
            i += 1;
        }
    }

    // Resize to actual size
    return allocator.realloc(result, result_idx);
}

/// Sanitize stderr output for safe logging
/// - Truncates to max_len bytes
/// - Strips ANSI escape codes
/// - Adds "... (truncated)" if truncated
pub fn sanitizeStderr(allocator: std.mem.Allocator, stderr: []const u8, max_len: usize) ![]const u8 {
    if (stderr.len == 0) {
        // Return empty allocated string that can be freed
        return allocator.dupe(u8, "");
    }

    // Step 1: Truncate if needed
    const truncated = if (stderr.len > max_len)
        stderr[0..max_len]
    else
        stderr;

    const was_truncated = stderr.len > max_len;

    // Step 2: Strip ANSI codes
    const stripped = try stripAnsiCodes(allocator, truncated);
    errdefer allocator.free(stripped);

    // Step 3: Add truncation indicator if needed
    if (!was_truncated) {
        return stripped;
    }

    const suffix = "... (truncated)";
    const result = try allocator.alloc(u8, stripped.len + suffix.len);
    @memcpy(result[0..stripped.len], stripped);
    @memcpy(result[stripped.len..], suffix);

    allocator.free(stripped);
    return result;
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

test "stripAnsiCodes - empty string" {
    const result = try stripAnsiCodes(std.testing.allocator, "");
    defer if (result.len > 0) std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "stripAnsiCodes - no ANSI codes" {
    const input = "Simple error message";
    const result = try stripAnsiCodes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "stripAnsiCodes - single ANSI code" {
    const input = "\x1b[31mError message\x1b[0m";
    const result = try stripAnsiCodes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Error message", result);
}

test "stripAnsiCodes - multiple ANSI codes" {
    const input = "\x1b[1;31mERROR\x1b[0m: \x1b[33mWarning\x1b[0m message";
    const result = try stripAnsiCodes(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ERROR: Warning message", result);
}

test "sanitizeStderr - empty string" {
    const result = try sanitizeStderr(std.testing.allocator, "", 512);
    defer if (result.len > 0) std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "sanitizeStderr - short message no truncation" {
    const input = "Error: Package not found";
    const result = try sanitizeStderr(std.testing.allocator, input, 512);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "sanitizeStderr - long message truncated" {
    // Create 600 byte string
    var input_buf: [600]u8 = undefined;
    @memset(&input_buf, 'A');
    const input = input_buf[0..];

    const result = try sanitizeStderr(std.testing.allocator, input, 512);
    defer std.testing.allocator.free(result);

    // Should be truncated with suffix
    try std.testing.expect(std.mem.endsWith(u8, result, "... (truncated)"));
    try std.testing.expect(result.len > 512); // 512 + suffix length
    try std.testing.expect(result.len < 600); // But less than original
}

test "sanitizeStderr - strip ANSI codes" {
    const input = "\x1b[31mError:\x1b[0m Package not found";
    const result = try sanitizeStderr(std.testing.allocator, input, 512);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Error: Package not found", result);
}

test "sanitizeStderr - truncate and strip ANSI" {
    // Create long string with ANSI codes
    var input_buf: [700]u8 = undefined;
    const prefix = "\x1b[31m";
    const suffix_ansi = "\x1b[0m";

    // Build: <ansi>AAAA...<ansi>
    @memcpy(input_buf[0..prefix.len], prefix);
    @memset(input_buf[prefix.len .. 700 - suffix_ansi.len], 'A');
    @memcpy(input_buf[700 - suffix_ansi.len ..], suffix_ansi);

    const input = input_buf[0..];
    const result = try sanitizeStderr(std.testing.allocator, input, 512);
    defer std.testing.allocator.free(result);

    // Should not contain ANSI codes
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b") == null);
    // Should be truncated
    try std.testing.expect(std.mem.endsWith(u8, result, "... (truncated)"));
}
