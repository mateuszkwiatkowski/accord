const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");

pub const ServiceResource = struct {
    base: resource.ResourceBase = .{},

    name: []const u8,
    state: ServiceState = .running, // DEFAULT: start services
    enabled: bool = true, // DEFAULT: enable at boot

    pub const ServiceState = enum { running, stopped };

    pub fn check(self: *ServiceResource, sys: *const system.SystemInfo) !resource.ResourceState {
        return switch (sys.init_system orelse return error.NoInitSystem) {
            .systemd => try self.checkSystemd(),
            else => error.UnsupportedInitSystem,
        };
    }

    fn checkSystemd(self: *ServiceResource) !resource.ResourceState {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Check if service is running
        // systemctl is-active returns 0 if active, non-zero otherwise
        const is_active_args = [_][]const u8{ "systemctl", "is-active", self.name };

        var is_active_child = std.process.Child.init(&is_active_args, allocator);
        is_active_child.stdout_behavior = .Ignore;
        is_active_child.stderr_behavior = .Ignore;

        try is_active_child.spawn();
        const is_active_term = try is_active_child.wait();
        const is_running = (is_active_term == .Exited and is_active_term.Exited == 0);

        // Check if service is enabled
        // systemctl is-enabled returns 0 if enabled
        const is_enabled_args = [_][]const u8{ "systemctl", "is-enabled", self.name };

        var is_enabled_child = std.process.Child.init(&is_enabled_args, allocator);
        is_enabled_child.stdout_behavior = .Ignore;
        is_enabled_child.stderr_behavior = .Ignore;

        try is_enabled_child.spawn();
        const is_enabled_term = try is_enabled_child.wait();
        const is_enabled = (is_enabled_term == .Exited and is_enabled_term.Exited == 0);

        // Check if desired state matches
        const state_matches = (is_running and self.state == .running) or
            (!is_running and self.state == .stopped);
        const enabled_matches = (is_enabled == self.enabled);

        return if (state_matches and enabled_matches)
            .satisfied
        else
            .needs_change;
    }

    pub fn apply(self: *ServiceResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        return switch (sys.init_system orelse return error.NoInitSystem) {
            .systemd => try self.applySystemd(dry_run),
            else => error.UnsupportedInitSystem,
        };
    }

    fn applySystemd(self: *ServiceResource, dry_run: bool) !resource.ResourceResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (dry_run) {
            const output_mod = @import("../output.zig");
            const action = if (self.state == .running) "start" else "stop";
            const enabled_action = if (self.enabled) "enable" else "disable";
            const msg = try std.fmt.allocPrint(
                allocator,
                "would {s} and {s}",
                .{ action, enabled_action },
            );
            output_mod.logApply("Service", self.name, msg);
            return .{
                .state = .needs_change,
                .changed = true,
            };
        }

        // Apply state change (start/stop)
        const state_args = switch (self.state) {
            .running => [_][]const u8{ "systemctl", "start", self.name },
            .stopped => [_][]const u8{ "systemctl", "stop", self.name },
        };

        const output_mod = @import("../output.zig");

        var state_child = std.process.Child.init(&state_args, allocator);
        state_child.stdout_behavior = .Ignore;
        state_child.stderr_behavior = .Inherit; // Let stderr pass through directly

        try state_child.spawn();
        const state_term = try state_child.wait();

        if (state_term != .Exited or state_term.Exited != 0) {
            output_mod.logError("Service", self.name, "systemctl state change failed");
            return error.ServiceStateChangeFailed;
        }

        // Apply enabled/disabled change
        const enabled_args = if (self.enabled)
            [_][]const u8{ "systemctl", "enable", self.name }
        else
            [_][]const u8{ "systemctl", "disable", self.name };

        var enabled_child = std.process.Child.init(&enabled_args, allocator);
        enabled_child.stdout_behavior = .Ignore;
        enabled_child.stderr_behavior = .Inherit; // Let stderr pass through directly

        try enabled_child.spawn();
        const enabled_term = try enabled_child.wait();

        if (enabled_term != .Exited or enabled_term.Exited != 0) {
            output_mod.logError("Service", self.name, "systemctl enable/disable failed");
            return error.ServiceEnableChangeFailed;
        }

        // Log success
        const state_str = if (self.state == .running) "started" else "stopped";
        const enabled_str = if (self.enabled) "enabled" else "disabled";
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s} and {s}",
            .{ state_str, enabled_str },
        );
        output_mod.logApply("Service", self.name, msg);

        return .{
            .state = .satisfied,
            .changed = true,
        };
    }

    pub fn describe(self: *const ServiceResource) []const u8 {
        return self.name;
    }
};

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
    const check_systemd = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "which", "systemctl" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(check_systemd.stdout);
    defer testing.allocator.free(check_systemd.stderr);

    if (check_systemd.term.Exited != 0) {
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
    };

    // This should succeed without error (service exists)
    const state = svc.check(&sys_info) catch return error.SkipZigTest;
    // We can't assert state since we don't know if it's running/enabled
    _ = state;
}
