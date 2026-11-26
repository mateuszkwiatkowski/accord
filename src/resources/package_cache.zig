const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");

/// Refresh the package manager's index, before any package is installed.
/// Manifest key `.package_cache`; `.apt_update` is accepted as an alias.
pub const PackageCacheResource = struct {
    base: resource.ResourceBase = .{},
    name: []const u8 = "update", // Default name for nameless pattern

    pub fn check(self: *PackageCacheResource, sys: *const system.SystemInfo) !resource.ResourceState {
        _ = self;

        // Fail early on a system without a supported package manager
        _ = try refreshArgv(sys.pkg_manager orelse return error.NoPkgManager);

        // Always refresh: there is no portable way to tell how stale a cache is
        return .needs_change;
    }

    pub fn apply(self: *PackageCacheResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        const argv = try refreshArgv(sys.pkg_manager orelse return error.NoPkgManager);

        if (dry_run) {
            output.logApply("PackageCache", self.name, "would update cache");
            return .{
                .state = .needs_change,
                .changed = true,
            };
        }

        var child = try std.process.spawn(sys.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit, // Let stderr pass through directly
        });
        const term = try child.wait(sys.io);

        if (!term.success()) {
            output.logError("PackageCache", self.name, "package cache update failed");
            return error.PackageCacheUpdateFailed;
        }

        output.logApply("PackageCache", self.name, "cache updated");
        return .{
            .state = .satisfied,
            .changed = true,
        };
    }

    pub fn describe(self: *const PackageCacheResource) []const u8 {
        return self.name;
    }
};

/// Command that refreshes the package index
pub fn refreshArgv(pm: system.PkgManager) ![]const []const u8 {
    return switch (pm) {
        .apt => &.{ "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update" },
        .dnf => &.{ "dnf", "makecache" },
        .yum => &.{ "yum", "makecache" },
        .apk => &.{ "apk", "update" },
        // ASSUME_ALWAYS_YES also answers the pkg(8) bootstrap prompt
        .pkg => &.{ "env", "ASSUME_ALWAYS_YES=yes", "pkg", "update" },
        else => error.UnsupportedPkgManager,
    };
}

// Tests
const testing = std.testing;

fn testSystem(pm: ?system.PkgManager) system.SystemInfo {
    return .{
        .os_family = .unknown,
        .pkg_manager = pm,
        .init_system = null,
        .io = std.testing.io,
    };
}

test "PackageCacheResource check - no package manager" {
    var cache = PackageCacheResource{};
    const sys = testSystem(null);
    try testing.expectError(error.NoPkgManager, cache.check(&sys));
}

test "PackageCacheResource check - unsupported package manager" {
    var cache = PackageCacheResource{};
    const sys = testSystem(.pacman);
    try testing.expectError(error.UnsupportedPkgManager, cache.check(&sys));
}

test "PackageCacheResource check - always needs change on supported systems" {
    var cache = PackageCacheResource{};
    for ([_]system.PkgManager{ .apt, .dnf, .yum, .apk, .pkg }) |pm| {
        const sys = testSystem(pm);
        try testing.expectEqual(resource.ResourceState.needs_change, try cache.check(&sys));
    }
}

test "PackageCacheResource default name" {
    const cache = PackageCacheResource{};
    try testing.expectEqualStrings("update", cache.describe());
}

test "PackageCacheResource apply - dry run" {
    var cache = PackageCacheResource{};
    const sys = testSystem(.apk);
    const result = try cache.apply(&sys, true);
    try testing.expect(result.changed);
    try testing.expectEqual(resource.ResourceState.needs_change, result.state);
}

test "refreshArgv per package manager" {
    const cases = [_]struct { system.PkgManager, []const u8 }{
        .{ .apt, "apt-get" },
        .{ .dnf, "dnf" },
        .{ .yum, "yum" },
        .{ .apk, "apk" },
        .{ .pkg, "pkg" },
    };
    for (cases) |case| {
        const argv = try refreshArgv(case[0]);
        var found = false;
        for (argv) |arg| found = found or std.mem.eql(u8, arg, case[1]);
        try testing.expect(found);
    }
    try testing.expectError(error.UnsupportedPkgManager, refreshArgv(.brew));
}

// Integration test - only runs as root where apt-get is available
test "PackageCacheResource apply - real update" {
    std.Io.Dir.accessAbsolute(testing.io, "/usr/bin/apt-get", .{}) catch return error.SkipZigTest;

    var cache = PackageCacheResource{};
    const sys = testSystem(.apt);

    // Fails without root, skip then
    const result = cache.apply(&sys, false) catch |err| {
        if (err == error.PackageCacheUpdateFailed) return error.SkipZigTest;
        return err;
    };
    try testing.expect(result.changed);
    try testing.expectEqual(resource.ResourceState.satisfied, result.state);
}
