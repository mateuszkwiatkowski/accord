const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");
const utils = @import("../utils.zig");

// Import C chmod for file permissions
const c = @cImport({
    @cInclude("sys/stat.h");
});

/// File resource - manage file creation, content, permissions, and ownership
pub const FileResource = struct {
    base: resource.ResourceBase = .{},

    path: []const u8,
    content: ?[]const u8 = null,
    source: ?[]const u8 = null,
    mode: ?u32 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
    state: FileState = .present, // DEFAULT

    pub const FileState = enum { present, absent };

    /// Check if file is in desired state
    pub fn check(self: *FileResource, sys: *const system.SystemInfo) !resource.ResourceState {
        _ = sys;

        // Validate: content and source are mutually exclusive
        if (self.content != null and self.source != null) {
            output.logError("File", self.path, "content and source are mutually exclusive");
            return error.ContentAndSourceMutuallyExclusive;
        }

        // Try to open file
        var file = std.fs.openFileAbsolute(self.path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => if (self.state == .absent)
                    .satisfied
                else
                    .needs_change,
                else => {
                    output.logError("File", self.path, "Failed to check state");
                    return error.CheckFailed;
                },
            };
        };
        defer file.close();

        // File exists
        if (self.state == .absent) {
            return .needs_change;
        }

        // Check content if specified (using hash for efficiency)
        if (self.content) |desired_content| {
            const actual_hash = try hashFileContents(file);
            const desired_hash = hashBytes(desired_content);

            if (!std.mem.eql(u8, &actual_hash, &desired_hash)) {
                output.logDebug("File content hash mismatch");
                return .needs_change;
            }
        }

        // Check mode if specified
        if (self.mode) |desired_mode| {
            const stat = try file.stat();
            const actual_mode = stat.mode & 0o777;
            if (actual_mode != desired_mode) {
                output.logDebug("File mode mismatch");
                return .needs_change;
            }
        }

        // Check owner/group if specified (optimize: get ownership once)
        if (self.owner != null or self.group != null) {
            const current = utils.getFileOwnership(self.path) catch |err| {
                output.logError("File", self.path, "Failed to get ownership");
                return err;
            };

            // Check owner if specified
            if (self.owner) |owner_spec| {
                const desired_uid = utils.resolveUid(owner_spec) catch |err| {
                    output.logError("File", self.path, "Failed to resolve owner");
                    return err;
                };
                if (current.uid != desired_uid) {
                    output.logDebug("File owner mismatch");
                    return .needs_change;
                }
            }

            // Check group if specified
            if (self.group) |group_spec| {
                const desired_gid = utils.resolveGid(group_spec) catch |err| {
                    output.logError("File", self.path, "Failed to resolve group");
                    return err;
                };
                if (current.gid != desired_gid) {
                    output.logDebug("File group mismatch");
                    return .needs_change;
                }
            }
        }

        return .satisfied;
    }

    /// Apply changes to bring file to desired state
    pub fn apply(self: *FileResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        _ = sys;

        // Validate: content and source are mutually exclusive
        if (self.content != null and self.source != null) {
            output.logError("File", self.path, "content and source are mutually exclusive");
            return error.ContentAndSourceMutuallyExclusive;
        }

        if (dry_run) {
            const action = if (self.state == .present) "would create/update" else "would remove";
            output.logApply("File", self.path, action);
            return .{
                .state = .needs_change,
                .changed = true,
            };
        }

        switch (self.state) {
            .absent => {
                std.fs.deleteFileAbsolute(self.path) catch |err| {
                    const err_msg = std.fmt.allocPrint(
                        std.heap.page_allocator,
                        "Failed to remove file: {s}",
                        .{@errorName(err)},
                    ) catch "Failed to remove file";
                    output.logError("File", self.path, err_msg);
                    return err;
                };

                output.logApply("File", self.path, "removed");
                return .{
                    .state = .satisfied,
                    .changed = true,
                };
            },
            .present => {
                // Write content atomically (temp file + rename)
                if (self.content) |content| {
                    try writeFileAtomic(self.path, content);
                } else if (self.source) |src| {
                    try copyFileAtomic(src, self.path);
                }
                // If neither content nor source, file must already exist (just set perms/ownership)

                // Set mode if specified
                if (self.mode) |mode| {
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
                        output.logError("File", self.path, "Failed to resolve owner");
                        return err;
                    };
                }

                if (self.group) |group_spec| {
                    gid = utils.resolveGid(group_spec) catch |err| {
                        output.logError("File", self.path, "Failed to resolve group");
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
                        output.logError("File", self.path, err_msg);
                        return err;
                    };
                }

                output.logApply("File", self.path, "created/updated");
                return .{
                    .state = .satisfied,
                    .changed = true,
                };
            },
        }
    }

    /// Human-readable description
    pub fn describe(self: *const FileResource) []const u8 {
        return self.path;
    }
};

/// Hash file contents using SHA256
fn hashFileContents(file: std.fs.File) ![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    var buf: [4096]u8 = undefined;
    try file.seekTo(0);

    while (true) {
        const bytes_read = try file.read(&buf);
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
    }

    return hasher.finalResult();
}

/// Hash bytes using SHA256
fn hashBytes(data: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    return hasher.finalResult();
}

/// Write file atomically: write to temp, then rename
fn writeFileAtomic(path: []const u8, content: []const u8) !void {
    const allocator = std.heap.page_allocator;

    // Create temp file path
    const temp_path = try std.fmt.allocPrint(
        allocator,
        "{s}.accord-tmp-{d}",
        .{ path, std.time.milliTimestamp() },
    );
    defer allocator.free(temp_path);

    // Write to temp file
    const temp_file = try std.fs.createFileAbsolute(temp_path, .{});
    defer temp_file.close();
    try temp_file.writeAll(content);

    // Rename to final path (atomic on POSIX)
    try std.fs.renameAbsolute(temp_path, path);
}

/// Copy file atomically: copy to temp, then rename
fn copyFileAtomic(source: []const u8, dest: []const u8) !void {
    const allocator = std.heap.page_allocator;

    // Create temp file path
    const temp_path = try std.fmt.allocPrint(
        allocator,
        "{s}.accord-tmp-{d}",
        .{ dest, std.time.milliTimestamp() },
    );
    defer allocator.free(temp_path);

    // Copy to temp
    try std.fs.copyFileAbsolute(source, temp_path, .{});

    // Rename to final path (atomic on POSIX)
    try std.fs.renameAbsolute(temp_path, dest);
}

// Tests
test "FileResource has correct defaults" {
    const file = FileResource{
        .path = "/tmp/test.txt",
    };

    try std.testing.expect(file.state == .present);
    try std.testing.expect(file.content == null);
    try std.testing.expect(file.source == null);
    try std.testing.expect(file.mode == null);
    try std.testing.expect(file.owner == null);
    try std.testing.expect(file.group == null);
    try std.testing.expect(file.base.allow_failure == false);
}

test "FileResource check - file missing" {
    const test_path = "/tmp/accord-test-file-missing";

    // Ensure it doesn't exist
    std.fs.deleteFileAbsolute(test_path) catch {};

    var file = FileResource{
        .path = test_path,
        .state = .present,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const state = try file.check(&sys);
    try std.testing.expect(state == .needs_change);
}

test "FileResource check - file exists and matches" {
    const test_path = "/tmp/accord-test-file-matches";
    const test_content = "test content\n";

    // Create file
    const f = try std.fs.createFileAbsolute(test_path, .{});
    try f.writeAll(test_content);
    f.close();
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    var file = FileResource{
        .path = test_path,
        .content = test_content,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const state = try file.check(&sys);
    try std.testing.expect(state == .satisfied);
}

test "FileResource check - content differs" {
    const test_path = "/tmp/accord-test-file-differs";

    // Create file with different content
    const f = try std.fs.createFileAbsolute(test_path, .{});
    try f.writeAll("old content");
    f.close();
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    var file = FileResource{
        .path = test_path,
        .content = "new content",
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const state = try file.check(&sys);
    try std.testing.expect(state == .needs_change);
}

test "FileResource apply - creates file with content" {
    const test_path = "/tmp/accord-test-file-create";
    const test_content = "hello accord!";

    // Ensure it doesn't exist
    std.fs.deleteFileAbsolute(test_path) catch {};

    var file = FileResource{
        .path = test_path,
        .content = test_content,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try file.apply(&sys, false);
    try std.testing.expect(result.changed == true);

    // Verify file exists and has correct content
    const f = try std.fs.openFileAbsolute(test_path, .{});
    defer f.close();
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    var buf: [100]u8 = undefined;
    const bytes_read = try f.readAll(&buf);
    try std.testing.expect(std.mem.eql(u8, buf[0..bytes_read], test_content));
}

test "FileResource apply - removes file" {
    const test_path = "/tmp/accord-test-file-remove";

    // Create file first
    const f = try std.fs.createFileAbsolute(test_path, .{});
    f.close();

    var file = FileResource{
        .path = test_path,
        .state = .absent,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try file.apply(&sys, false);
    try std.testing.expect(result.changed == true);

    // Verify file doesn't exist
    const open_result = std.fs.openFileAbsolute(test_path, .{});
    try std.testing.expectError(error.FileNotFound, open_result);
}

test "FileResource idempotency" {
    const test_path = "/tmp/accord-test-file-idempotent";
    const test_content = "idempotent test";

    // Cleanup first
    std.fs.deleteFileAbsolute(test_path) catch {};

    var file = FileResource{
        .path = test_path,
        .content = test_content,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    // First apply - should create
    const result1 = try file.apply(&sys, false);
    try std.testing.expect(result1.changed == true);

    // Second check - should be satisfied
    const check_result = try file.check(&sys);
    try std.testing.expect(check_result == .satisfied);

    // Cleanup
    try std.fs.deleteFileAbsolute(test_path);
}

test "FileResource dry run doesn't modify" {
    const test_path = "/tmp/accord-test-file-dryrun";

    var file = FileResource{
        .path = test_path,
        .content = "test",
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    // Apply with dry_run = true
    const result = try file.apply(&sys, true);
    try std.testing.expect(result.changed == true);

    // File should not exist
    const open_result = std.fs.openFileAbsolute(test_path, .{});
    try std.testing.expectError(error.FileNotFound, open_result);
}

test "FileResource content and source mutually exclusive" {
    const test_path = "/tmp/accord-test-file-exclusive";

    var file = FileResource{
        .path = test_path,
        .content = "content",
        .source = "/some/source",
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    // Should error on check
    const check_result = file.check(&sys);
    try std.testing.expectError(error.ContentAndSourceMutuallyExclusive, check_result);

    // Should error on apply
    const apply_result = file.apply(&sys, false);
    try std.testing.expectError(error.ContentAndSourceMutuallyExclusive, apply_result);
}

test "FileResource apply - sets mode" {
    const test_path = "/tmp/accord-test-file-mode";
    const test_content = "mode test";

    std.fs.deleteFileAbsolute(test_path) catch {};

    var file = FileResource{
        .path = test_path,
        .content = test_content,
        .mode = 0o600,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    _ = try file.apply(&sys, false);
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    // Verify mode
    const f = try std.fs.openFileAbsolute(test_path, .{});
    defer f.close();
    const stat = try f.stat();
    const actual_mode = stat.mode & 0o777;
    try std.testing.expectEqual(@as(u32, 0o600), actual_mode);
}

test "FileResource apply - sets owner and group" {
    const test_path = "/tmp/accord-test-file-owner";
    const test_content = "ownership test";

    std.fs.deleteFileAbsolute(test_path) catch {};

    // Create file first to get current ownership
    const f = try std.fs.createFileAbsolute(test_path, .{});
    f.close();

    const original = try utils.getFileOwnership(test_path);
    const uid_str = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{original.uid});
    defer std.testing.allocator.free(uid_str);
    const gid_str = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{original.gid});
    defer std.testing.allocator.free(gid_str);

    // Delete and recreate with accord
    std.fs.deleteFileAbsolute(test_path) catch {};

    var file = FileResource{
        .path = test_path,
        .content = test_content,
        .owner = uid_str,
        .group = gid_str,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    _ = try file.apply(&sys, false);
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    // Verify ownership (same as original)
    const ownership = try utils.getFileOwnership(test_path);
    try std.testing.expectEqual(original.uid, ownership.uid);
    try std.testing.expectEqual(original.gid, ownership.gid);
}

test "FileResource check - mode differs" {
    const test_path = "/tmp/accord-test-file-mode-diff";

    // Create file with mode 0o644
    const f = try std.fs.createFileAbsolute(test_path, .{ .mode = 0o644 });
    f.close();
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    var file = FileResource{
        .path = test_path,
        .mode = 0o600, // Different mode
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const state = try file.check(&sys);
    try std.testing.expect(state == .needs_change);
}

test "FileResource apply - copy from source" {
    const source_path = "/tmp/accord-test-source-file";
    const dest_path = "/tmp/accord-test-dest-file";
    const test_content = "source file content";

    // Create source file
    const src_file = try std.fs.createFileAbsolute(source_path, .{});
    try src_file.writeAll(test_content);
    src_file.close();
    defer std.fs.deleteFileAbsolute(source_path) catch {};

    // Delete dest if exists
    std.fs.deleteFileAbsolute(dest_path) catch {};

    var file = FileResource{
        .path = dest_path,
        .source = source_path,
    };

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try file.apply(&sys, false);
    try std.testing.expect(result.changed == true);
    defer std.fs.deleteFileAbsolute(dest_path) catch {};

    // Verify content was copied
    const dest_file = try std.fs.openFileAbsolute(dest_path, .{});
    defer dest_file.close();

    var buf: [100]u8 = undefined;
    const bytes_read = try dest_file.readAll(&buf);
    try std.testing.expect(std.mem.eql(u8, buf[0..bytes_read], test_content));
}
