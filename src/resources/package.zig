const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");

pub const PackageResource = struct {
    base: resource.ResourceBase = .{},

    name: []const u8,
    state: PackageState = .installed, // DEFAULT: install packages
    version: ?[]const u8 = null,

    pub const PackageState = enum { installed, absent };

    pub fn check(self: *PackageResource, sys: *const system.SystemInfo) !resource.ResourceState {
        return switch (sys.pkg_manager orelse return error.NoPkgManager) {
            .apt => try self.checkApt(),
            else => error.UnsupportedPkgManager,
        };
    }

    fn checkApt(self: *PackageResource) !resource.ResourceState {
        // Use dpkg-query to check if package is installed
        // dpkg-query -W -f='${Status}' <package> returns "install ok installed" if installed
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const args = [_][]const u8{ "dpkg-query", "-W", "-f=${Status}", self.name };

        var child = std.process.Child.init(&args, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
        const term = try child.wait();

        // Package is installed if exit code is 0 and status contains "install ok installed"
        const is_installed = (term == .Exited and term.Exited == 0) and
            std.mem.indexOf(u8, stdout, "install ok installed") != null;

        return if (is_installed == (self.state == .installed))
            .satisfied
        else
            .needs_change;
    }

    pub fn apply(self: *PackageResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        return switch (sys.pkg_manager orelse return error.NoPkgManager) {
            .apt => try self.applyApt(dry_run),
            else => error.UnsupportedPkgManager,
        };
    }

    fn applyApt(self: *PackageResource, dry_run: bool) !resource.ResourceResult {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Build apt-get command based on desired state
        const args = switch (self.state) {
            .installed => blk: {
                if (self.version) |ver| {
                    // Package with version: package=version
                    const pkg_with_ver = try std.fmt.allocPrint(allocator, "{s}={s}", .{ self.name, ver });
                    break :blk [_][]const u8{ "apt-get", "install", "-y", pkg_with_ver };
                } else {
                    break :blk [_][]const u8{ "apt-get", "install", "-y", self.name };
                }
            },
            .absent => [_][]const u8{ "apt-get", "remove", "-y", self.name },
        };

        if (dry_run) {
            const output_mod = @import("../output.zig");
            const action = if (self.state == .installed) "would install" else "would remove";
            output_mod.logApply("Package", self.name, action);
            return .{
                .state = .needs_change,
                .changed = true,
            };
        }

        // Execute apt-get command
        var child = std.process.Child.init(&args, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit; // Let stderr pass through directly

        try child.spawn();
        const term = try child.wait();

        const output_mod = @import("../output.zig");

        if (term != .Exited or term.Exited != 0) {
            // Log simple error message
            output_mod.logError("Package", self.name, "apt-get command failed");
            return error.PackageOperationFailed;
        }

        // Log success
        const action = if (self.state == .installed) "installed" else "removed";
        output_mod.logApply("Package", self.name, action);

        return .{
            .state = .satisfied,
            .changed = true,
        };
    }

    pub fn describe(self: *const PackageResource) []const u8 {
        return self.name;
    }
};

// Tests
const testing = std.testing;

test "PackageResource check - apt not available" {
    var pkg = PackageResource{
        .name = "nginx",
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = null, // No package manager
        .init_system = .systemd,
    };

    const result = pkg.check(&sys_info);
    try testing.expectError(error.NoPkgManager, result);
}

test "PackageResource check - unsupported package manager" {
    var pkg = PackageResource{
        .name = "nginx",
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .yum, // Unsupported on Debian
        .init_system = .systemd,
    };

    const result = pkg.check(&sys_info);
    try testing.expectError(error.UnsupportedPkgManager, result);
}

test "PackageResource default state is installed" {
    const pkg = PackageResource{
        .name = "nginx",
    };

    try testing.expectEqual(PackageResource.PackageState.installed, pkg.state);
}

test "PackageResource describe returns name" {
    const pkg = PackageResource{
        .name = "nginx",
    };

    try testing.expectEqualStrings("nginx", pkg.describe());
}

test "PackageResource apply - dry run install" {
    var pkg = PackageResource{
        .name = "test-package",
        .state = .installed,
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };

    const result = try pkg.apply(&sys_info, true);
    try testing.expect(result.changed);
    try testing.expectEqual(resource.ResourceState.needs_change, result.state);
}

test "PackageResource apply - dry run remove" {
    var pkg = PackageResource{
        .name = "test-package",
        .state = .absent,
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };

    const result = try pkg.apply(&sys_info, true);
    try testing.expect(result.changed);
    try testing.expectEqual(resource.ResourceState.needs_change, result.state);
}

test "PackageResource with version" {
    const pkg = PackageResource{
        .name = "nginx",
        .version = "1.18.0-1",
    };

    try testing.expectEqualStrings("nginx", pkg.name);
    try testing.expectEqualStrings("1.18.0-1", pkg.version.?);
}

// Integration test - only runs if dpkg-query is available
test "PackageResource check - real package" {
    // Check if we're on a Debian-based system
    const check_debian = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "which", "dpkg-query" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(check_debian.stdout);
    defer testing.allocator.free(check_debian.stderr);

    if (check_debian.term.Exited != 0) {
        return error.SkipZigTest;
    }

    // Test checking for a package that's almost certainly installed: dpkg itself
    var pkg = PackageResource{
        .name = "dpkg",
        .state = .installed,
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };

    const state = try pkg.check(&sys_info);
    // dpkg should be installed on any Debian-based system
    try testing.expectEqual(resource.ResourceState.satisfied, state);
}

test "PackageResource check - nonexistent package" {
    // Check if we're on a Debian-based system
    const check_debian = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "which", "dpkg-query" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(check_debian.stdout);
    defer testing.allocator.free(check_debian.stderr);

    if (check_debian.term.Exited != 0) {
        return error.SkipZigTest;
    }

    // Test checking for a package that doesn't exist
    var pkg = PackageResource{
        .name = "this-package-definitely-does-not-exist-12345",
        .state = .installed,
    };

    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };

    const state = try pkg.check(&sys_info);
    // Nonexistent package should need installation
    try testing.expectEqual(resource.ResourceState.needs_change, state);
}
