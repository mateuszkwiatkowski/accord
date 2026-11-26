const std = @import("std");

// libc bindings for POSIX user/group lookup and stat (requires link_libc)
const c = std.c;

/// Resolve owner specification to UID
/// Accepts: "username" or "1000" (numeric UID)
pub fn resolveUid(owner_spec: []const u8) !u32 {
    // 1. Try parsing as numeric UID
    if (std.fmt.parseInt(u32, owner_spec, 10)) |uid| {
        return uid;
    } else |_| {
        // 2. Not numeric - lookup by username
        const allocator = std.heap.page_allocator;
        const username_z = try allocator.dupeSentinel(u8, owner_spec, 0);
        defer allocator.free(username_z);

        const pwd = c.getpwnam(username_z.ptr) orelse return error.UserNotFound;
        return @intCast(pwd.uid);
    }
}

/// Resolve group specification to GID
/// Accepts: "groupname" or "1000" (numeric GID)
pub fn resolveGid(group_spec: []const u8) !u32 {
    // 1. Try parsing as numeric GID
    if (std.fmt.parseInt(u32, group_spec, 10)) |gid| {
        return gid;
    } else |_| {
        // 2. Not numeric - lookup by groupname
        const allocator = std.heap.page_allocator;
        const groupname_z = try allocator.dupeSentinel(u8, group_spec, 0);
        defer allocator.free(groupname_z);

        const grp = c.getgrnam(groupname_z.ptr) orelse return error.GroupNotFound;
        return @intCast(grp.gid);
    }
}

/// Change file/directory ownership
/// Pass null for uid or gid to leave unchanged (-1 in chown)
/// Uses libc directly: std.Io.Dir.setFileOwner is not implemented in Zig 0.17.1
pub fn chown(path: []const u8, uid: ?u32, gid: ?u32) !void {
    const allocator = std.heap.page_allocator;
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    const unchanged = std.math.maxInt(u32); // (uid_t)-1
    const result = c.fchownat(c.AT.FDCWD, path_z.ptr, uid orelse unchanged, gid orelse unchanged, 0);
    if (result != 0) {
        return error.ChownFailed;
    }
}

/// Change file/directory permission bits
pub fn chmod(io: std.Io, path: []const u8, mode: u32) !void {
    std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(@intCast(mode)), .{}) catch {
        return error.ChmodFailed;
    };
}

/// Get current file/directory ownership using libc stat
/// (std.Io.File.Stat does not expose uid/gid)
pub fn getFileOwnership(path: []const u8) !struct { uid: u32, gid: u32 } {
    const allocator = std.heap.page_allocator;
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    var stat_buf: c.Stat = undefined;
    const result = c.stat(path_z.ptr, &stat_buf);
    if (result != 0) {
        return error.StatFailed;
    }

    return .{
        .uid = @intCast(stat_buf.uid),
        .gid = @intCast(stat_buf.gid),
    };
}

// Tests
test "resolveUid - numeric UID" {
    const uid = try resolveUid("0");
    try std.testing.expectEqual(@as(u32, 0), uid);
}

test "resolveGid - numeric GID" {
    const gid = try resolveGid("0");
    try std.testing.expectEqual(@as(u32, 0), gid);
}

test "resolveUid - root username" {
    const uid = try resolveUid("root");
    try std.testing.expectEqual(@as(u32, 0), uid);
}

test "resolveUid - invalid username" {
    const result = resolveUid("thisuserdoesnotexist123456");
    try std.testing.expectError(error.UserNotFound, result);
}

test "getFileOwnership - /tmp" {
    const ownership = try getFileOwnership("/tmp");
    // Just verify it doesn't crash and returns something
    _ = ownership;
}

test "chown - no-op test on owned file" {
    const io = std.testing.io;
    const test_path = "/tmp/accord-test-chown";

    // Create test file
    const f = try std.Io.Dir.createFileAbsolute(io, test_path, .{});
    f.close(io);
    defer std.Io.Dir.deleteFileAbsolute(io, test_path) catch {};

    // Get current ownership
    const ownership = try getFileOwnership(test_path);

    // Set to same ownership (no-op, but tests the function)
    try chown(test_path, ownership.uid, ownership.gid);

    // Verify it worked
    const after = try getFileOwnership(test_path);
    try std.testing.expectEqual(ownership.uid, after.uid);
    try std.testing.expectEqual(ownership.gid, after.gid);
}
