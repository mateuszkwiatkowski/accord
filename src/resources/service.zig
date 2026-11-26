const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");

pub const ServiceResource = struct {
    base: resource.ResourceBase = .{},

    name: []const u8,
    state: ServiceState = .running, // DEFAULT: start services
    enabled: bool = true, // DEFAULT: enable at boot

    pub const ServiceState = enum { running, stopped };

    pub fn check(self: *ServiceResource, sys: *const system.SystemInfo) !resource.ResourceState {
        const init = sys.init_system orelse return error.NoInitSystem;
        const current = try queryState(sys.io, init, self.name);
        return if (current.running == (self.state == .running) and current.enabled == self.enabled)
            .satisfied
        else
            .needs_change;
    }

    pub fn apply(self: *ServiceResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        const init = sys.init_system orelse return error.NoInitSystem;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const state_str = if (self.state == .running) "start" else "stop";
        const enabled_str = if (self.enabled) "enable" else "disable";

        if (dry_run) {
            // Fail on an unsupported init system in dry runs too
            _ = try stateArgv(init, self.state, self.name);
            const msg = try std.fmt.allocPrint(allocator, "would {s} and {s}", .{ state_str, enabled_str });
            output.logApply("Service", self.name, msg);
            return .{
                .state = .needs_change,
                .changed = true,
            };
        }

        // Only change what differs: rc.d and OpenRC treat starting a running
        // service or re-adding an enabled one as an error
        const current = try queryState(sys.io, init, self.name);

        if (current.running != (self.state == .running)) {
            if (!try run(sys.io, try stateArgv(init, self.state, self.name))) {
                output.logError("Service", self.name, "state change failed");
                return error.ServiceStateChangeFailed;
            }
        }

        if (current.enabled != self.enabled) {
            if (!try run(sys.io, try enableArgv(init, self.enabled, self.name))) {
                output.logError("Service", self.name, "enable/disable failed");
                return error.ServiceEnableChangeFailed;
            }
        }

        const msg = try std.fmt.allocPrint(allocator, "{s}ed and {s}d", .{
            if (self.state == .running) "start" else "stopp",
            enabled_str,
        });
        output.logApply("Service", self.name, msg);

        return .{
            .state = .satisfied,
            .changed = true,
        };
    }

    pub fn describe(self: *const ServiceResource) []const u8 {
        return self.name;
    }
};

const ServiceStatus = struct { running: bool, enabled: bool };

/// Ask the init system whether `name` is running and enabled at boot
fn queryState(io: std.Io, init: system.InitSystem, name: []const u8) !ServiceStatus {
    const running = try succeeds(io, try runningArgv(init, name));
    const enabled = switch (init) {
        // OpenRC enables a service by linking it into the runlevel directory
        .openrc => blk: {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "/etc/runlevels/default/{s}", .{name});
            std.Io.Dir.accessAbsolute(io, path, .{}) catch break :blk false;
            break :blk true;
        },
        else => try succeeds(io, try enabledArgv(init, name)),
    };
    return .{ .running = running, .enabled = enabled };
}

/// Command that exits 0 when `name` is running
pub fn runningArgv(init: system.InitSystem, name: []const u8) ![3][]const u8 {
    return switch (init) {
        .systemd => .{ "systemctl", "is-active", name },
        .openrc => .{ "rc-service", name, "status" },
        // one*: act regardless of the rc.conf enable knob
        .rc => .{ "service", name, "onestatus" },
        else => error.UnsupportedInitSystem,
    };
}

/// Command that exits 0 when `name` is enabled at boot (not used for OpenRC)
pub fn enabledArgv(init: system.InitSystem, name: []const u8) ![3][]const u8 {
    return switch (init) {
        .systemd => .{ "systemctl", "is-enabled", name },
        .rc => .{ "service", name, "enabled" },
        else => error.UnsupportedInitSystem,
    };
}

/// Command that starts or stops `name`
pub fn stateArgv(init: system.InitSystem, state: ServiceResource.ServiceState, name: []const u8) ![3][]const u8 {
    const start = state == .running;
    return switch (init) {
        .systemd => .{ "systemctl", if (start) "start" else "stop", name },
        .openrc => .{ "rc-service", name, if (start) "start" else "stop" },
        .rc => .{ "service", name, if (start) "onestart" else "onestop" },
        else => error.UnsupportedInitSystem,
    };
}

/// Command that enables or disables `name` at boot
pub fn enableArgv(init: system.InitSystem, enabled: bool, name: []const u8) ![4][]const u8 {
    return switch (init) {
        .systemd => .{ "systemctl", if (enabled) "enable" else "disable", name, "--quiet" },
        .openrc => .{ "rc-update", if (enabled) "add" else "del", name, "default" },
        .rc => .{ "service", name, if (enabled) "enable" else "disable", "-q" },
        else => error.UnsupportedInitSystem,
    };
}

/// Run a query command silently; true if it exits 0
fn succeeds(io: std.Io, argv: [3][]const u8) !bool {
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return (try child.wait(io)).success();
}

/// Run a changing command, letting its stderr through; true if it exits 0
fn run(io: std.Io, argv: anytype) !bool {
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    return (try child.wait(io)).success();
}

// Tests
const testing = std.testing;

test "ServiceResource check - init system not available" {
    var svc = ServiceResource{
        .name = "nginx",
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = null, // No init system
        .io = std.testing.io,
    };

    const result = svc.check(&sys_info);
    try testing.expectError(error.NoInitSystem, result);
}

test "ServiceResource check - unsupported init system" {
    var svc = ServiceResource{
        .name = "nginx",
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .sysvinit, // Unsupported
        .io = std.testing.io,
    };

    const result = svc.check(&sys_info);
    try testing.expectError(error.UnsupportedInitSystem, result);
}

test "ServiceResource default state is running" {
    const svc = ServiceResource{
        .name = "nginx",
    };

    try testing.expectEqual(ServiceResource.ServiceState.running, svc.state);
}

test "ServiceResource default enabled is true" {
    const svc = ServiceResource{
        .name = "nginx",
    };

    try testing.expectEqual(true, svc.enabled);
}

test "ServiceResource describe returns name" {
    const svc = ServiceResource{
        .name = "nginx",
    };

    try testing.expectEqualStrings("nginx", svc.describe());
}

test "ServiceResource apply - dry run start" {
    var svc = ServiceResource{
        .name = "test-service",
        .state = .running,
        .enabled = true,
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
        .io = std.testing.io,
    };

    const result = try svc.apply(&sys_info, true);
    try testing.expect(result.changed);
    try testing.expectEqual(resource.ResourceState.needs_change, result.state);
}

test "ServiceResource apply - dry run stop" {
    var svc = ServiceResource{
        .name = "test-service",
        .state = .stopped,
        .enabled = false,
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
        .io = std.testing.io,
    };

    const result = try svc.apply(&sys_info, true);
    try testing.expect(result.changed);
    try testing.expectEqual(resource.ResourceState.needs_change, result.state);
}

test "ServiceResource with custom state" {
    const svc = ServiceResource{
        .name = "nginx",
        .state = .stopped,
        .enabled = false,
    };

    try testing.expectEqual(ServiceResource.ServiceState.stopped, svc.state);
    try testing.expectEqual(false, svc.enabled);
}

// Integration test - only runs if systemctl is available
test "ServiceResource check - systemd available" {
    // Check if systemctl is available
    const check_systemd = std.process.run(testing.allocator, testing.io, .{
        .argv = &[_][]const u8{ "which", "systemctl" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(check_systemd.stdout);
    defer testing.allocator.free(check_systemd.stderr);

    if (!check_systemd.term.success()) {
        return error.SkipZigTest;
    }

    // Test checking a service that should exist on systemd systems
    // We'll check for systemd-journald which is fundamental to systemd
    var svc = ServiceResource{
        .name = "systemd-journald",
        .state = .running,
        .enabled = true,
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
        .io = std.testing.io,
    };

    // This should succeed without error (service exists)
    const state = svc.check(&sys_info) catch return error.SkipZigTest;
    // We can't assert state since we don't know if it's running/enabled
    _ = state;
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "service commands - systemd" {
    try expectArgv(&.{ "systemctl", "is-active", "cron" }, &try runningArgv(.systemd, "cron"));
    try expectArgv(&.{ "systemctl", "is-enabled", "cron" }, &try enabledArgv(.systemd, "cron"));
    try expectArgv(&.{ "systemctl", "start", "cron" }, &try stateArgv(.systemd, .running, "cron"));
    try expectArgv(&.{ "systemctl", "stop", "cron" }, &try stateArgv(.systemd, .stopped, "cron"));
    try expectArgv(&.{ "systemctl", "enable", "cron", "--quiet" }, &try enableArgv(.systemd, true, "cron"));
    try expectArgv(&.{ "systemctl", "disable", "cron", "--quiet" }, &try enableArgv(.systemd, false, "cron"));
}

test "service commands - OpenRC" {
    try expectArgv(&.{ "rc-service", "crond", "status" }, &try runningArgv(.openrc, "crond"));
    try expectArgv(&.{ "rc-service", "crond", "start" }, &try stateArgv(.openrc, .running, "crond"));
    try expectArgv(&.{ "rc-service", "crond", "stop" }, &try stateArgv(.openrc, .stopped, "crond"));
    try expectArgv(&.{ "rc-update", "add", "crond", "default" }, &try enableArgv(.openrc, true, "crond"));
    try expectArgv(&.{ "rc-update", "del", "crond", "default" }, &try enableArgv(.openrc, false, "crond"));
}

test "service commands - BSD rc.d" {
    try expectArgv(&.{ "service", "cron", "onestatus" }, &try runningArgv(.rc, "cron"));
    try expectArgv(&.{ "service", "cron", "enabled" }, &try enabledArgv(.rc, "cron"));
    try expectArgv(&.{ "service", "cron", "onestart" }, &try stateArgv(.rc, .running, "cron"));
    try expectArgv(&.{ "service", "cron", "onestop" }, &try stateArgv(.rc, .stopped, "cron"));
    try expectArgv(&.{ "service", "cron", "enable", "-q" }, &try enableArgv(.rc, true, "cron"));
    try expectArgv(&.{ "service", "cron", "disable", "-q" }, &try enableArgv(.rc, false, "cron"));
}

test "service commands - unsupported init systems" {
    try testing.expectError(error.UnsupportedInitSystem, runningArgv(.launchd, "x"));
    try testing.expectError(error.UnsupportedInitSystem, stateArgv(.sysvinit, .running, "x"));
    try testing.expectError(error.UnsupportedInitSystem, enableArgv(.launchd, true, "x"));
}
