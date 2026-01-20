const std = @import("std");

// C interop for POSIX user/group functions
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h"); // stat, fstat
    @cInclude("pwd.h"); // getpwnam, getpwuid
    @cInclude("grp.h"); // getgrnam, getgrgid
    @cInclude("unistd.h"); // chown
});

/// Resolve owner specification to UID
/// Accepts: "username" or "1000" (numeric UID)
pub fn resolveUid(owner_spec: []const u8) !u32 {
    // 1. Try parsing as numeric UID
    if (std.fmt.parseInt(u32, owner_spec, 10)) |uid| {
        return uid;
    } else |_| {
        // 2. Not numeric - lookup by username
        const allocator = std.heap.page_allocator;
        const username_z = try allocator.dupeZ(u8, owner_spec);
        defer allocator.free(username_z);

        const pwd = c.getpwnam(username_z.ptr);
        if (pwd == null) {
            return error.UserNotFound;
        }

        return @intCast(pwd.*.pw_uid);
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
        const groupname_z = try allocator.dupeZ(u8, group_spec);
        defer allocator.free(groupname_z);

        const grp = c.getgrnam(groupname_z.ptr);
        if (grp == null) {
            return error.GroupNotFound;
        }

        return @intCast(grp.*.gr_gid);
    }
}

/// Change file/directory ownership
/// Pass null for uid or gid to leave unchanged (-1 in chown)
pub fn chown(path: []const u8, uid: ?u32, gid: ?u32) !void {
    const allocator = std.heap.page_allocator;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const uid_val: c_uint = if (uid) |u| @intCast(u) else @bitCast(@as(c_int, -1));
    const gid_val: c_uint = if (gid) |g| @intCast(g) else @bitCast(@as(c_int, -1));

    const result = c.chown(path_z.ptr, uid_val, gid_val);
    if (result != 0) {
        return error.ChownFailed;
    }
}

/// Get current file/directory ownership using libc stat
pub fn getFileOwnership(path: []const u8) !struct { uid: u32, gid: u32 } {
    const allocator = std.heap.page_allocator;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var stat_buf: c.struct_stat = undefined;
    const result = c.stat(path_z.ptr, &stat_buf);
    if (result != 0) {
        return error.StatFailed;
    }

    return .{
        .uid = @intCast(stat_buf.st_uid),
        .gid = @intCast(stat_buf.st_gid),
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
    const test_path = "/tmp/accord-test-chown";

    // Create test file
    const f = try std.fs.createFileAbsolute(test_path, .{});
    f.close();
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    // Get current ownership
    const ownership = try getFileOwnership(test_path);

    // Set to same ownership (no-op, but tests the function)
    try chown(test_path, ownership.uid, ownership.gid);

    // Verify it worked
    const after = try getFileOwnership(test_path);
    try std.testing.expectEqual(ownership.uid, after.uid);
    try std.testing.expectEqual(ownership.gid, after.gid);
}
