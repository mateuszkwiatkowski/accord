const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");
const utils = @import("../utils.zig");

/// User resource - create, update and remove user accounts. Accounts get no
/// usable password; shell and home default to the system's own defaults.
pub const UserResource = struct {
    base: resource.ResourceBase = .{},

    name: []const u8,
    uid: ?u32 = null,
    /// Primary group; never affected by `membership`
    group: ?[]const u8 = null,
    /// Supplementary groups
    groups: []const []const u8 = &.{},
    membership: Membership = .append,
    shell: ?[]const u8 = null,
    home: ?[]const u8 = null,
    state: UserState = .present,
    /// With state = .absent, also delete the home directory
    remove_home: bool = false,

    pub const UserState = enum { present, absent };

    pub const Membership = enum {
        /// Add the user to `groups`, leave other memberships alone
        append,
        /// Also remove the user from every supplementary group not listed
        exact,
    };

    pub fn check(self: *UserResource, sys: *const system.SystemInfo) !resource.ResourceState {
        const tool = sys.user_tool orelse return error.NoUserTool;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const commands = try self.planned(arena.allocator(), tool);
        return if (commands.len == 0) .satisfied else .needs_change;
    }

    pub fn apply(self: *UserResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        const tool = sys.user_tool orelse return error.NoUserTool;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const exists = try lookup(allocator, self.name) != null;
        const commands = try self.planned(allocator, tool);
        if (commands.len == 0) return .{ .state = .satisfied, .changed = false };

        const action = if (self.state == .absent) "removed" else if (exists) "updated" else "created";

        if (dry_run) {
            output.logApply("User", self.name, try std.fmt.allocPrint(allocator, "would be {s}", .{action}));
            return .{ .state = .needs_change, .changed = true };
        }

        for (commands) |argv| {
            if (!try utils.run(sys.io, argv)) {
                const msg = try std.fmt.allocPrint(allocator, "{s} failed", .{argv[0]});
                output.logError("User", self.name, msg);
                return error.UserOperationFailed;
            }
        }
        output.logApply("User", self.name, action);
        return .{ .state = .satisfied, .changed = true };
    }

    pub fn describe(self: *const UserResource) []const u8 {
        return self.name;
    }

    fn planned(self: *const UserResource, allocator: std.mem.Allocator, tool: system.UserTool) ![]const []const []const u8 {
        const current = try lookup(allocator, self.name);
        const desired_gid = if (self.group) |g| utils.resolveGid(g) catch null else null;
        var reason: []const u8 = "";
        return plan(allocator, tool, self.*, current, desired_gid, &reason) catch |err| {
            if (err == error.UnsupportedChange) output.logError("User", self.name, reason);
            return err;
        };
    }
};

/// An existing account, as read from the user and group databases
pub const Current = struct {
    uid: u32,
    gid: u32,
    shell: []const u8,
    home: []const u8,
    /// Name of the primary group, if it has one
    primary_group: ?[]const u8,
    /// Supplementary groups: those listing the user as a member
    member_of: []const []const u8,
};

/// Read `name`'s account through libc, or null if there is no such user
pub fn lookup(allocator: std.mem.Allocator, name: []const u8) !?Current {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    // libc returns static buffers: copy everything before the next call
    const pwd = std.c.getpwnam(name_z.ptr) orelse return null;
    const uid: u32 = @intCast(pwd.uid);
    const gid: u32 = @intCast(pwd.gid);
    const shell = try allocator.dupe(u8, if (pwd.shell) |p| std.mem.span(p) else "");
    const home = try allocator.dupe(u8, if (pwd.dir) |p| std.mem.span(p) else "");

    var member_of: std.ArrayList([]const u8) = .empty;
    std.c.setgrent();
    while (std.c.getgrent()) |grp| {
        var i: usize = 0;
        while (grp.mem[i]) |member| : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(member), name)) {
                try member_of.append(allocator, try allocator.dupe(u8, std.mem.span(grp.name.?)));
                break;
            }
        }
    }
    std.c.endgrent();

    const primary_group = if (std.c.getgrgid(@intCast(gid))) |grp|
        try allocator.dupe(u8, std.mem.span(grp.name.?))
    else
        null;

    return .{
        .uid = uid,
        .gid = gid,
        .shell = shell,
        .home = home,
        .primary_group = primary_group,
        .member_of = member_of.items,
    };
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

/// Commands that bring the account to its desired state, in order; empty when
/// it is already there. `current` is null when the user does not exist;
/// `desired_gid` is the gid of `user.group`, null if unset or not created yet.
/// On error.UnsupportedChange, `reason` says what cannot be changed.
pub fn plan(
    allocator: std.mem.Allocator,
    tool: system.UserTool,
    user: UserResource,
    current: ?Current,
    desired_gid: ?u32,
    reason: *[]const u8,
) ![]const []const []const u8 {
    var commands: std.ArrayList([]const []const u8) = .empty;
    const name = user.name;

    if (user.state == .absent) {
        if (current == null) return &.{};
        const argv: []const []const u8 = switch (tool) {
            .shadow => if (user.remove_home) &.{ "userdel", "-r", name } else &.{ "userdel", name },
            .busybox => if (user.remove_home) &.{ "deluser", "--remove-home", name } else &.{ "deluser", name },
            .pw => if (user.remove_home) &.{ "pw", "userdel", "-n", name, "-r" } else &.{ "pw", "userdel", "-n", name },
        };
        // argv points at a temporary: copy it before returning
        try commands.append(allocator, try allocator.dupe([]const u8, argv));
        return commands.items;
    }

    // Groups the user already belongs to, primary included
    var have: []const []const u8 = &.{};

    if (current) |cur| {
        if (user.uid) |uid| if (uid != cur.uid) {
            reason.* = "changing the uid of an existing user is not supported";
            return error.UnsupportedChange;
        };
        if (user.group) |group| if (desired_gid != cur.gid) {
            if (tool == .busybox) {
                reason.* = "busybox cannot change an existing user's primary group";
                return error.UnsupportedChange;
            }
            try commands.append(allocator, try modify(allocator, tool, name, "-g", group));
        };
        if (user.shell) |shell| if (!std.mem.eql(u8, shell, cur.shell)) {
            if (tool == .busybox) {
                reason.* = "busybox cannot change an existing user's shell";
                return error.UnsupportedChange;
            }
            try commands.append(allocator, try modify(allocator, tool, name, "-s", shell));
        };
        if (user.home) |home| if (!std.mem.eql(u8, home, cur.home)) {
            if (tool == .busybox) {
                reason.* = "busybox cannot change an existing user's home";
                return error.UnsupportedChange;
            }
            try commands.append(allocator, try modify(allocator, tool, name, "-d", home));
        };

        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(allocator, cur.member_of);
        if (cur.primary_group) |pg| try list.append(allocator, pg);
        have = list.items;

        if (user.membership == .exact) {
            for (cur.member_of) |group| {
                if (contains(user.groups, group) or eqlOpt(user.group, group) or eqlOpt(cur.primary_group, group)) continue;
                try commands.append(allocator, try memberArgv(allocator, tool, .remove, name, group));
            }
        }
    } else {
        try commands.append(allocator, try createArgv(allocator, tool, user));
    }

    for (user.groups) |group| {
        if (contains(have, group) or eqlOpt(user.group, group)) continue;
        try commands.append(allocator, try memberArgv(allocator, tool, .add, name, group));
    }
    return commands.items;
}

fn createArgv(allocator: std.mem.Allocator, tool: system.UserTool, user: UserResource) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    switch (tool) {
        .shadow => try argv.appendSlice(allocator, &.{ "useradd", "-m" }),
        // -D: no password; the home directory is created by default
        .busybox => try argv.appendSlice(allocator, &.{ "adduser", "-D" }),
        .pw => try argv.appendSlice(allocator, &.{ "pw", "useradd", "-n", user.name, "-m" }),
    }
    if (user.uid) |uid| try argv.appendSlice(allocator, &.{ "-u", try std.fmt.allocPrint(allocator, "{d}", .{uid}) });
    if (user.group) |group| try argv.appendSlice(allocator, &.{ if (tool == .busybox) "-G" else "-g", group });
    if (user.shell) |shell| try argv.appendSlice(allocator, &.{ "-s", shell });
    if (user.home) |home| try argv.appendSlice(allocator, &.{ if (tool == .busybox) "-h" else "-d", home });
    if (tool != .pw) try argv.append(allocator, user.name);
    return argv.items;
}

/// usermod-style change of one attribute (not available with busybox)
fn modify(allocator: std.mem.Allocator, tool: system.UserTool, name: []const u8, flag: []const u8, value: []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, switch (tool) {
        .shadow => &.{ "usermod", flag, value, name },
        .pw => &.{ "pw", "usermod", "-n", name, flag, value },
        .busybox => unreachable,
    });
}

fn memberArgv(allocator: std.mem.Allocator, tool: system.UserTool, op: enum { add, remove }, name: []const u8, group: []const u8) ![]const []const u8 {
    const add = op == .add;
    return allocator.dupe([]const u8, switch (tool) {
        .shadow => &.{ "gpasswd", if (add) "-a" else "-d", name, group },
        .busybox => &.{ if (add) "addgroup" else "delgroup", name, group },
        .pw => &.{ "pw", "groupmod", "-n", group, if (add) "-m" else "-d", name },
    });
}

// Tests
const testing = std.testing;

fn expectPlan(expected: []const []const []const u8, tool: system.UserTool, user: UserResource, current: ?Current, desired_gid: ?u32) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reason: []const u8 = "";
    const actual = try plan(arena.allocator(), tool, user, current, desired_gid, &reason);
    errdefer for (actual) |argv| {
        std.debug.print("got:", .{});
        for (argv) |w| std.debug.print(" {s}", .{w});
        std.debug.print("\n", .{});
    };
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.len, a.len);
        for (e, a) |ew, aw| try testing.expectEqualStrings(ew, aw);
    }
}

fn expectUnsupported(tool: system.UserTool, user: UserResource, current: Current, desired_gid: ?u32, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reason: []const u8 = "";
    try testing.expectError(error.UnsupportedChange, plan(arena.allocator(), tool, user, current, desired_gid, &reason));
    try testing.expect(std.mem.indexOf(u8, reason, needle) != null);
}

const full = UserResource{
    .name = "deploy",
    .uid = 4300,
    .group = "app",
    .groups = &.{ "app", "web" },
    .shell = "/bin/sh",
    .home = "/srv/deploy",
};

const existing = Current{
    .uid = 4300,
    .gid = 4200,
    .shell = "/bin/sh",
    .home = "/srv/deploy",
    .primary_group = "app",
    .member_of = &.{ "web", "old" },
};

test "user plan - create" {
    try expectPlan(&.{
        &.{ "useradd", "-m", "-u", "4300", "-g", "app", "-s", "/bin/sh", "-d", "/srv/deploy", "deploy" },
        &.{ "gpasswd", "-a", "deploy", "web" },
    }, .shadow, full, null, null);
    try expectPlan(&.{
        &.{ "adduser", "-D", "-u", "4300", "-G", "app", "-s", "/bin/sh", "-h", "/srv/deploy", "deploy" },
        &.{ "addgroup", "deploy", "web" },
    }, .busybox, full, null, null);
    try expectPlan(&.{
        &.{ "pw", "useradd", "-n", "deploy", "-m", "-u", "4300", "-g", "app", "-s", "/bin/sh", "-d", "/srv/deploy" },
        &.{ "pw", "groupmod", "-n", "web", "-m", "deploy" },
    }, .pw, full, null, null);
    try expectPlan(&.{&.{ "useradd", "-m", "bare" }}, .shadow, .{ .name = "bare" }, null, null);
}

test "user plan - satisfied" {
    for ([_]system.UserTool{ .shadow, .busybox, .pw }) |tool| {
        try expectPlan(&.{}, tool, full, existing, 4200);
        try expectPlan(&.{}, tool, .{ .name = "deploy" }, existing, null);
    }
}

test "user plan - membership append adds, exact also removes" {
    var user = full;
    user.groups = &.{ "web", "docker" };
    try expectPlan(&.{&.{ "gpasswd", "-a", "deploy", "docker" }}, .shadow, user, existing, 4200);

    user.membership = .exact;
    try expectPlan(&.{
        &.{ "gpasswd", "-d", "deploy", "old" },
        &.{ "gpasswd", "-a", "deploy", "docker" },
    }, .shadow, user, existing, 4200);
    try expectPlan(&.{
        &.{ "delgroup", "deploy", "old" },
        &.{ "addgroup", "deploy", "docker" },
    }, .busybox, user, existing, 4200);
    try expectPlan(&.{
        &.{ "pw", "groupmod", "-n", "old", "-d", "deploy" },
        &.{ "pw", "groupmod", "-n", "docker", "-m", "deploy" },
    }, .pw, user, existing, 4200);
}

test "user plan - exact never removes the primary group" {
    var cur = existing;
    cur.member_of = &.{"app"};
    try expectPlan(&.{}, .shadow, .{ .name = "deploy", .membership = .exact }, cur, null);
}

test "user plan - change shell, home and primary group" {
    var user = full;
    user.shell = "/bin/bash";
    user.home = "/home/deploy";
    try expectPlan(&.{
        &.{ "usermod", "-g", "app", "deploy" },
        &.{ "usermod", "-s", "/bin/bash", "deploy" },
        &.{ "usermod", "-d", "/home/deploy", "deploy" },
    }, .shadow, user, existing, 4201);
    try expectPlan(&.{
        &.{ "pw", "usermod", "-n", "deploy", "-s", "/bin/bash" },
    }, .pw, .{ .name = "deploy", .shell = "/bin/bash" }, existing, null);
}

test "user plan - unsupported changes" {
    for ([_]system.UserTool{ .shadow, .busybox, .pw }) |tool| {
        try expectUnsupported(tool, .{ .name = "deploy", .uid = 1 }, existing, null, "uid");
    }
    try expectUnsupported(.busybox, .{ .name = "deploy", .shell = "/bin/ash" }, existing, null, "shell");
    try expectUnsupported(.busybox, .{ .name = "deploy", .home = "/home/deploy" }, existing, null, "home");
    try expectUnsupported(.busybox, .{ .name = "deploy", .group = "web" }, existing, 4201, "primary group");
}

test "user plan - remove" {
    const gone = UserResource{ .name = "deploy", .state = .absent };
    var purge = gone;
    purge.remove_home = true;
    try expectPlan(&.{&.{ "userdel", "deploy" }}, .shadow, gone, existing, null);
    try expectPlan(&.{&.{ "userdel", "-r", "deploy" }}, .shadow, purge, existing, null);
    try expectPlan(&.{&.{ "deluser", "--remove-home", "deploy" }}, .busybox, purge, existing, null);
    try expectPlan(&.{&.{ "pw", "userdel", "-n", "deploy", "-r" }}, .pw, purge, existing, null);
    try expectPlan(&.{}, .shadow, gone, null, null);
}

test "lookup - root exists, nonsense does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = (try lookup(arena.allocator(), "root")) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(u32, 0), root.uid);
    try testing.expect(root.primary_group != null);
    try testing.expect(try lookup(arena.allocator(), "accord-no-such-user-xyz") == null);
}
