const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");

/// Directory resource - manage directory creation, permissions, and ownership
pub const DirectoryResource = struct {
    base: resource.ResourceBase = .{},

    path: []const u8,
    mode: ?u32 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
    state: DirState = .present, // DEFAULT: create/ensure present

    pub const DirState = enum { present, absent };

    /// Check if directory is in desired state
    pub fn check(self: *DirectoryResource, sys: *const system.SystemInfo) !resource.ResourceState {
        _ = sys; // May need for platform-specific checks in the future

        // Try to open directory
        var dir = std.fs.openDirAbsolute(self.path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => if (self.state == .absent)
                    .satisfied
                else
                    .needs_change,
                else => {
                    // Failed to check state
                    output.logError("Directory", self.path, "Failed to check state");
                    return error.CheckFailed;
                },
            };
        };
        defer dir.close();

        // Directory exists
        if (self.state == .absent) {
            return .needs_change;
        }

        // Check mode if specified
        if (self.mode) |desired_mode| {
            const stat = try dir.stat();
            const actual_mode = stat.mode & 0o777;
            if (actual_mode != desired_mode) {
                output.logDebug("Directory mode mismatch");
                return .needs_change;
            }
        }

        // Owner/group checking not yet implemented
        if (self.owner != null or self.group != null) {
            output.logDebug("Owner/group checking not yet implemented");
        }

        return .satisfied;
    }

    /// Apply changes to bring directory to desired state
    pub fn apply(self: *DirectoryResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        _ = sys; // May need for platform-specific operations

        output.logDebug(if (dry_run) "DRY RUN mode enabled" else "Normal mode");

        if (dry_run) {
            const action = if (self.state == .present) "create" else "remove";
            return .{
                .state = .needs_change,
                .message = action,
                .changed = true,
            };
        }

        switch (self.state) {
            .absent => {
                // Remove directory
                std.fs.deleteDirAbsolute(self.path) catch |err| {
                    const err_msg = std.fmt.allocPrint(
                        std.heap.page_allocator,
                        "Failed to remove directory: {s}",
                        .{@errorName(err)},
                    ) catch "Failed to remove directory";
                    output.logError("Directory", self.path, err_msg);
                    return err;
                };

                return .{
                    .state = .satisfied,
                    .message = "removed",
                    .changed = true,
                };
            },
            .present => {
                // Create directory (recursive)
                std.fs.makeDirAbsolute(self.path) catch |err| {
                    if (err != error.PathAlreadyExists) {
                        const err_msg = std.fmt.allocPrint(
                            std.heap.page_allocator,
                            "Failed to create directory: {s}",
                            .{@errorName(err)},
                        ) catch "Failed to create directory";
                        output.logError("Directory", self.path, err_msg);
                        return err;
                    }
                };

                // Set mode if specified
                if (self.mode) |mode| {
                    var dir = try std.fs.openDirAbsolute(self.path, .{});
                    defer dir.close();

                    try dir.chmod(@intCast(mode));
                }

                // Owner/group setting not yet implemented
                if (self.owner != null or self.group != null) {
                    output.logDebug("Owner/group setting not yet implemented");
                }

                return .{
                    .state = .satisfied,
                    .message = "created",
                    .changed = true,
                };
            },
        }
    }

    /// Human-readable description
    pub fn describe(self: *const DirectoryResource) []const u8 {
        return self.path;
    }
};

// Tests
test "DirectoryResource has correct defaults" {
    const dir = DirectoryResource{
        .path = "/tmp/test",
    };

    try std.testing.expect(dir.state == .present);
    try std.testing.expect(dir.mode == null);
    try std.testing.expect(dir.owner == null);
    try std.testing.expect(dir.group == null);
    try std.testing.expect(dir.base.allow_failure == false);
}

test "DirectoryResource check on missing directory" {
    const test_path = "/tmp/accord-test-missing-dir-check";

    // Ensure it doesn't exist
    std.fs.deleteDirAbsolute(test_path) catch {};

    var dir = DirectoryResource{
        .path = test_path,
        .state = .present,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const state = try dir.check(&sys);
    try std.testing.expect(state == .needs_change);
}

test "DirectoryResource apply creates directory" {
    const test_path = "/tmp/accord-test-apply-create";

    // Ensure it doesn't exist
    std.fs.deleteDirAbsolute(test_path) catch {};

    var dir = DirectoryResource{
        .path = test_path,
        .state = .present,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try dir.apply(&sys, false);
    try std.testing.expect(result.changed == true);
    try std.testing.expect(result.state == .satisfied);

    // Verify directory exists
    var opened_dir = try std.fs.openDirAbsolute(test_path, .{});
    opened_dir.close();

    // Cleanup
    try std.fs.deleteDirAbsolute(test_path);
}

test "DirectoryResource apply removes directory" {
    const test_path = "/tmp/accord-test-apply-remove";

    // Create directory first
    std.fs.makeDirAbsolute(test_path) catch {};

    var dir = DirectoryResource{
        .path = test_path,
        .state = .absent,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try dir.apply(&sys, false);
    try std.testing.expect(result.changed == true);
    try std.testing.expect(result.state == .satisfied);

    // Verify directory doesn't exist
    const open_result = std.fs.openDirAbsolute(test_path, .{});
    try std.testing.expectError(error.FileNotFound, open_result);
}

test "DirectoryResource idempotency" {
    const test_path = "/tmp/accord-test-idempotent";

    // Cleanup first
    std.fs.deleteDirAbsolute(test_path) catch {};

    var dir = DirectoryResource{
        .path = test_path,
        .state = .present,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    // First apply - should create
    const result1 = try dir.apply(&sys, false);
    try std.testing.expect(result1.changed == true);

    // Second check - should be satisfied
    const check_result = try dir.check(&sys);
    try std.testing.expect(check_result == .satisfied);

    // Cleanup
    try std.fs.deleteDirAbsolute(test_path);
}

test "DirectoryResource dry run doesn't create" {
    const test_path = "/tmp/accord-test-dryrun";

    // Ensure it doesn't exist
    std.fs.deleteDirAbsolute(test_path) catch {};

    var dir = DirectoryResource{
        .path = test_path,
        .state = .present,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    // Apply with dry_run = true
    const result = try dir.apply(&sys, true);
    try std.testing.expect(result.changed == true);

    // Verify directory was NOT created
    const open_result = std.fs.openDirAbsolute(test_path, .{});
    try std.testing.expectError(error.FileNotFound, open_result);
}
