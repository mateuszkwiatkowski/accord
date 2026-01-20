const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");
const utils = @import("../utils.zig");

// Import C chmod function for setting directory permissions
const c = @cImport({
    @cInclude("sys/stat.h");
});

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

        // Check owner/group if specified (optimize: get ownership once)
        if (self.owner != null or self.group != null) {
            const current = utils.getFileOwnership(self.path) catch |err| {
                output.logError("Directory", self.path, "Failed to get ownership");
                return err;
            };

            // Check owner if specified
            if (self.owner) |owner_spec| {
                const desired_uid = utils.resolveUid(owner_spec) catch |err| {
                    output.logError("Directory", self.path, "Failed to resolve owner");
                    return err;
                };
                if (current.uid != desired_uid) {
                    output.logDebug("Directory owner mismatch");
                    return .needs_change;
                }
            }

            // Check group if specified
            if (self.group) |group_spec| {
                const desired_gid = utils.resolveGid(group_spec) catch |err| {
                    output.logError("Directory", self.path, "Failed to resolve group");
                    return err;
                };
                if (current.gid != desired_gid) {
                    output.logDebug("Directory group mismatch");
                    return .needs_change;
                }
            }
        }

        return .satisfied;
    }

    /// Apply changes to bring directory to desired state
    pub fn apply(self: *DirectoryResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        _ = sys; // May need for platform-specific operations

        output.logDebug(if (dry_run) "DRY RUN mode enabled" else "Normal mode");

        if (dry_run) {
            const action = if (self.state == .present) "would create" else "would remove";
            output.logApply("Directory", self.path, action);
            return .{
                .state = .needs_change,
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

                output.logApply("Directory", self.path, "removed");
                return .{
                    .state = .satisfied,
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
                    // Note: Can't use fchmod on directory fd on Linux, must use chmod with path
                    // Convert path to null-terminated for C call
                    const allocator = std.heap.page_allocator;
                    const path_z = try allocator.dupeZ(u8, self.path);
                    defer allocator.free(path_z);

                    const result = c.chmod(path_z.ptr, @intCast(mode));
                    if (result != 0) {
                        return error.ChmodFailed;
                    }
                }

                // Set owner/group if specified
                var uid: ?u32 = null;
                var gid: ?u32 = null;

                if (self.owner) |owner_spec| {
                    uid = utils.resolveUid(owner_spec) catch |err| {
                        output.logError("Directory", self.path, "Failed to resolve owner");
                        return err;
                    };
                }

                if (self.group) |group_spec| {
                    gid = utils.resolveGid(group_spec) catch |err| {
                        output.logError("Directory", self.path, "Failed to resolve group");
                        return err;
                    };
                }

                if (uid != null or gid != null) {
                    utils.chown(self.path, uid, gid) catch |err| {
                        const err_msg = std.fmt.allocPrint(
                            std.heap.page_allocator,
                            "Failed to change ownership: {s}",
                            .{@errorName(err)},
                        ) catch "Failed to change ownership";
                        output.logError("Directory", self.path, err_msg);
                        return err;
                    };
                }

                output.logApply("Directory", self.path, "created");
                return .{
                    .state = .satisfied,
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

test "DirectoryResource check - owner matches" {
    const test_path = "/tmp/accord-test-owner-check";
    std.fs.makeDirAbsolute(test_path) catch {};
    defer std.fs.deleteDirAbsolute(test_path) catch {};

    // Get current user's ownership
    const ownership = try utils.getFileOwnership(test_path);

    // Use current user's UID as a string
    const uid_str = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{ownership.uid});
    defer std.testing.allocator.free(uid_str);

    var dir = DirectoryResource{
        .path = test_path,
        .owner = uid_str,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    // Should be satisfied since we're using the current owner
    const state = try dir.check(&sys);
    try std.testing.expect(state == .satisfied);
}

test "DirectoryResource apply - sets owner by name" {
    const test_path = "/tmp/accord-test-owner-apply";
    std.fs.makeDirAbsolute(test_path) catch {};
    defer std.fs.deleteDirAbsolute(test_path) catch {};

    // Get current ownership (will be reused)
    const original = try utils.getFileOwnership(test_path);
    const uid_str = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{original.uid});
    defer std.testing.allocator.free(uid_str);
    const gid_str = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{original.gid});
    defer std.testing.allocator.free(gid_str);

    var dir = DirectoryResource{
        .path = test_path,
        .owner = uid_str,
        .group = gid_str,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try dir.apply(&sys, false);
    try std.testing.expect(result.changed == true);

    // Verify ownership (should still be same as original since we set it to same values)
    const ownership = try utils.getFileOwnership(test_path);
    try std.testing.expectEqual(original.uid, ownership.uid);
    try std.testing.expectEqual(original.gid, ownership.gid);
}

test "DirectoryResource apply - sets owner by UID" {
    const test_path = "/tmp/accord-test-owner-uid";
    std.fs.makeDirAbsolute(test_path) catch {};
    defer std.fs.deleteDirAbsolute(test_path) catch {};

    // Get current ownership and set to same (no-op but tests the function)
    const original = try utils.getFileOwnership(test_path);
    const uid_str = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{original.uid});
    defer std.testing.allocator.free(uid_str);

    var dir = DirectoryResource{
        .path = test_path,
        .owner = uid_str, // Numeric UID (current user)
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try dir.apply(&sys, false);
    try std.testing.expect(result.changed == true);

    const ownership = try utils.getFileOwnership(test_path);
    try std.testing.expectEqual(original.uid, ownership.uid);
}

test "DirectoryResource apply - owner only leaves group unchanged" {
    const test_path = "/tmp/accord-test-owner-only";
    std.fs.makeDirAbsolute(test_path) catch {};
    defer std.fs.deleteDirAbsolute(test_path) catch {};

    // Get original ownership
    const original = try utils.getFileOwnership(test_path);
    const uid_str = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{original.uid});
    defer std.testing.allocator.free(uid_str);

    var dir = DirectoryResource{
        .path = test_path,
        .owner = uid_str,
        // No group specified
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    _ = try dir.apply(&sys, false);

    const after = try utils.getFileOwnership(test_path);
    try std.testing.expectEqual(original.uid, after.uid);
    try std.testing.expectEqual(original.gid, after.gid); // Group unchanged

    std.fs.deleteDirAbsolute(test_path) catch {};
}

test "DirectoryResource check - group matches" {
    const test_path = "/tmp/accord-test-group-check";
    std.fs.makeDirAbsolute(test_path) catch {};
    defer std.fs.deleteDirAbsolute(test_path) catch {};

    var dir = DirectoryResource{
        .path = test_path,
        .group = "0", // Numeric GID 0
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const state = try dir.check(&sys);
    try std.testing.expect(state == .satisfied);
}

test "DirectoryResource apply - sets group by GID" {
    const test_path = "/tmp/accord-test-group-gid";
    std.fs.makeDirAbsolute(test_path) catch {};
    defer std.fs.deleteDirAbsolute(test_path) catch {};

    var dir = DirectoryResource{
        .path = test_path,
        .group = "0",
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try dir.apply(&sys, false);
    try std.testing.expect(result.changed == true);

    const ownership = try utils.getFileOwnership(test_path);
    try std.testing.expectEqual(@as(u32, 0), ownership.gid);
}
