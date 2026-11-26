const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");
const utils = @import("../utils.zig");

/// Group resource - create and remove groups
pub const GroupResource = struct {
    base: resource.ResourceBase = .{},

    name: []const u8,
    gid: ?u32 = null, // DEFAULT: the system picks one
    state: GroupState = .present,

    pub const GroupState = enum { present, absent };

    pub fn check(self: *GroupResource, sys: *const system.SystemInfo) !resource.ResourceState {
        const tool = sys.user_tool orelse return error.NoUserTool;
        var gid_buf: [16]u8 = undefined;
        return if (try self.planned(tool, &gid_buf) == null) .satisfied else .needs_change;
    }

    pub fn apply(self: *GroupResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        const tool = sys.user_tool orelse return error.NoUserTool;
        var gid_buf: [16]u8 = undefined;
        const argv = try self.planned(tool, &gid_buf) orelse return .{ .state = .satisfied, .changed = false };

        if (dry_run) {
            output.logApply("Group", self.name, if (self.state == .present) "would create" else "would remove");
            return .{ .state = .needs_change, .changed = true };
        }

        if (!try utils.run(sys.io, argv.slice())) {
            output.logError("Group", self.name, "group command failed");
            return error.GroupOperationFailed;
        }
        output.logApply("Group", self.name, if (self.state == .present) "created" else "removed");
        return .{ .state = .satisfied, .changed = true };
    }

    pub fn describe(self: *const GroupResource) []const u8 {
        return self.name;
    }

    fn planned(self: *const GroupResource, tool: system.UserTool, gid_buf: []u8) !?Argv {
        return plan(tool, self.*, currentGid(self.name), gid_buf) catch |err| {
            if (err == error.UnsupportedChange) {
                output.logError("Group", self.name, "changing the gid of an existing group is not supported");
            }
            return err;
        };
    }
};

/// A command line of at most 6 words
pub const Argv = struct {
    buf: [6][]const u8 = undefined,
    len: usize = 0,

    pub fn init(words: []const []const u8) Argv {
        var a = Argv{};
        for (words) |w| a.append(w);
        return a;
    }

    pub fn append(a: *Argv, word: []const u8) void {
        a.buf[a.len] = word;
        a.len += 1;
    }

    pub fn slice(a: *const Argv) []const []const u8 {
        return a.buf[0..a.len];
    }
};

/// gid of group `name`, or null if there is no such group
pub fn currentGid(name: []const u8) ?u32 {
    var buf: [256]u8 = undefined;
    const name_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return null;
    const grp = std.c.getgrnam(name_z.ptr) orelse return null;
    return @intCast(grp.gid);
}

/// The command that brings the group to its desired state, or null when it
/// is already there. `current` is the group's gid, null if it does not exist.
/// `gid_buf` holds the formatted gid for the returned command.
pub fn plan(tool: system.UserTool, group: GroupResource, current: ?u32, gid_buf: []u8) !?Argv {
    switch (group.state) {
        .absent => {
            if (current == null) return null;
            return switch (tool) {
                .shadow => Argv.init(&.{ "groupdel", group.name }),
                .busybox => Argv.init(&.{ "delgroup", group.name }),
                .pw => Argv.init(&.{ "pw", "groupdel", "-n", group.name }),
            };
        },
        .present => {
            if (current) |gid| {
                if (group.gid) |want| if (want != gid) return error.UnsupportedChange;
                return null;
            }
            var argv = switch (tool) {
                .shadow => Argv.init(&.{"groupadd"}),
                .busybox => Argv.init(&.{"addgroup"}),
                .pw => Argv.init(&.{ "pw", "groupadd", "-n", group.name }),
            };
            if (group.gid) |gid| {
                argv.append("-g");
                argv.append(try std.fmt.bufPrint(gid_buf, "{d}", .{gid}));
            }
            if (tool != .pw) argv.append(group.name);
            return argv;
        },
    }
}

// Tests
const testing = std.testing;

fn expectArgv(expected: []const []const u8, actual: ?Argv) !void {
    const a = actual orelse return error.TestExpectedCommand;
    try testing.expectEqual(expected.len, a.len);
    for (expected, a.slice()) |e, w| try testing.expectEqualStrings(e, w);
}

test "group plan - create" {
    var buf: [16]u8 = undefined;
    const g = GroupResource{ .name = "app" };
    const g_gid = GroupResource{ .name = "app", .gid = 4200 };
    try expectArgv(&.{ "groupadd", "app" }, try plan(.shadow, g, null, &buf));
    try expectArgv(&.{ "groupadd", "-g", "4200", "app" }, try plan(.shadow, g_gid, null, &buf));
    try expectArgv(&.{ "addgroup", "-g", "4200", "app" }, try plan(.busybox, g_gid, null, &buf));
    try expectArgv(&.{ "pw", "groupadd", "-n", "app", "-g", "4200" }, try plan(.pw, g_gid, null, &buf));
}

test "group plan - already present" {
    var buf: [16]u8 = undefined;
    try testing.expect(try plan(.shadow, .{ .name = "app" }, 1234, &buf) == null);
    try testing.expect(try plan(.pw, .{ .name = "app", .gid = 1234 }, 1234, &buf) == null);
}

test "group plan - changing the gid is refused" {
    var buf: [16]u8 = undefined;
    for ([_]system.UserTool{ .shadow, .busybox, .pw }) |tool| {
        try testing.expectError(error.UnsupportedChange, plan(tool, .{ .name = "app", .gid = 4200 }, 1234, &buf));
    }
}

test "group plan - remove" {
    var buf: [16]u8 = undefined;
    const g = GroupResource{ .name = "app", .state = .absent };
    try expectArgv(&.{ "groupdel", "app" }, try plan(.shadow, g, 1234, &buf));
    try expectArgv(&.{ "delgroup", "app" }, try plan(.busybox, g, 1234, &buf));
    try expectArgv(&.{ "pw", "groupdel", "-n", "app" }, try plan(.pw, g, 1234, &buf));
    try testing.expect(try plan(.shadow, g, null, &buf) == null);
}

test "currentGid - gid 0 exists, nonsense does not" {
    const grp = std.c.getgrgid(0) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(?u32, 0), currentGid(std.mem.span(grp.name.?)));
    try testing.expect(currentGid("accord-no-such-group-xyz") == null);
}

test "GroupResource check - no user tool" {
    var g = GroupResource{ .name = "app" };
    const sys = system.SystemInfo{ .os_family = .unknown, .pkg_manager = null, .init_system = null, .io = testing.io };
    try testing.expectError(error.NoUserTool, g.check(&sys));
}
