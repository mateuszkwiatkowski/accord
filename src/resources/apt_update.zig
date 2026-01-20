const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");

pub const AptUpdateResource = struct {
    base: resource.ResourceBase = .{},
    name: []const u8 = "update", // Default name for nameless pattern

    pub fn check(self: *AptUpdateResource, sys: *const system.SystemInfo) !resource.ResourceState {
        _ = self;

        // Verify we have apt package manager
        if (sys.pkg_manager != .apt) {
            return error.UnsupportedPkgManager;
        }

        // For MVP: always return needs_change (update every time)
        // This ensures package cache is always fresh before package operations
        // Future enhancement: check /var/lib/apt/periodic/update-success-stamp timestamp
        return .needs_change;
    }

    pub fn apply(self: *AptUpdateResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        _ = sys;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        if (dry_run) {
            output.logApply("AptUpdate", self.name, "would update cache");
            return .{
                .state = .needs_change,
                .changed = true,
            };
        }

        // Execute apt-get update
        const args = [_][]const u8{ "apt-get", "update" };
        var child = std.process.Child.init(&args, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit; // Let stderr pass through directly

        try child.spawn();
        const term = try child.wait();

        if (term != .Exited or term.Exited != 0) {
            // Log simple error message
            output.logError("AptUpdate", self.name, "apt-get update failed");
            return error.AptUpdateFailed;
        }

        output.logApply("AptUpdate", self.name, "cache updated");
        return .{
            .state = .satisfied,
            .changed = true,
        };
    }

    pub fn describe(self: *const AptUpdateResource) []const u8 {
        return self.name;
    }
};

// Tests
const testing = std.testing;

test "AptUpdateResource check - not apt system" {
    var apt_upd = AptUpdateResource{};

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .yum, // Wrong package manager
        .init_system = .systemd,
    };

    const result = apt_upd.check(&sys_info);
    try testing.expectError(error.UnsupportedPkgManager, result);
}

test "AptUpdateResource check - apt system always needs change" {
    var apt_upd = AptUpdateResource{};

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };

    const state = try apt_upd.check(&sys_info);
    // MVP: always returns needs_change to ensure fresh cache
    try testing.expectEqual(resource.ResourceState.needs_change, state);
}

test "AptUpdateResource default name" {
    const apt_upd = AptUpdateResource{};
    try testing.expectEqualStrings("update", apt_upd.name);
}

test "AptUpdateResource describe returns name" {
    const apt_upd = AptUpdateResource{
        .name = "cache-update",
    };
    try testing.expectEqualStrings("cache-update", apt_upd.describe());
}

test "AptUpdateResource apply - dry run" {
    var apt_upd = AptUpdateResource{};

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };

    const result = try apt_upd.apply(&sys_info, true);
    try testing.expect(result.changed);
    try testing.expectEqual(resource.ResourceState.needs_change, result.state);
}

// Integration test - only runs if apt-get is available
test "AptUpdateResource apply - real update" {
    // Check if apt-get is available
    const check_apt = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "which", "apt-get" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(check_apt.stdout);
    defer testing.allocator.free(check_apt.stderr);

    if (check_apt.term.Exited != 0) {
        return error.SkipZigTest;
    }

    var apt_upd = AptUpdateResource{};

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };

    // This will actually run apt-get update
    // Note: Requires root/sudo permissions or will fail
    const result = apt_upd.apply(&sys_info, false) catch |err| {
        // Expected to fail without root, skip test
        if (err == error.AptUpdateFailed) {
            return error.SkipZigTest;
        }
        return err;
    };

    try testing.expect(result.changed);
    try testing.expectEqual(resource.ResourceState.satisfied, result.state);
}
