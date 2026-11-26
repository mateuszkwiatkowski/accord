const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");
const output = @import("../output.zig");

pub const PackageResource = struct {
    base: resource.ResourceBase = .{},

    name: []const u8,
    state: PackageState = .installed, // DEFAULT: install packages
    version: ?[]const u8 = null,

    pub const PackageState = enum { installed, absent };

    pub fn check(self: *PackageResource, sys: *const system.SystemInfo) !resource.ResourceState {
        const pm = sys.pkg_manager orelse return error.NoPkgManager;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const installed = try isInstalled(allocator, sys.io, pm, self.name);
        return if (installed == (self.state == .installed))
            .satisfied
        else
            .needs_change;
    }

    pub fn apply(self: *PackageResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        const pm = sys.pkg_manager orelse return error.NoPkgManager;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const args = try changeArgv(allocator, pm, self.state, self.name, self.version);

        if (dry_run) {
            const action = if (self.state == .installed) "would install" else "would remove";
            output.logApply("Package", self.name, action);
            return .{
                .state = .needs_change,
                .changed = true,
            };
        }

        var child = try std.process.spawn(sys.io, .{
            .argv = args,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit, // Let stderr pass through directly
        });
        const term = try child.wait(sys.io);

        if (!term.success()) {
            const msg = std.fmt.allocPrint(allocator, "{s} failed", .{tool(pm)}) catch "package command failed";
            output.logError("Package", self.name, msg);
            return error.PackageOperationFailed;
        }

        const action = if (self.state == .installed) "installed" else "removed";
        output.logApply("Package", self.name, action);

        return .{
            .state = .satisfied,
            .changed = true,
        };
    }

    pub fn describe(self: *const PackageResource) []const u8 {
        return self.name;
    }
};

/// Ask the package manager whether `name` is installed
fn isInstalled(allocator: std.mem.Allocator, io: std.Io, pm: system.PkgManager, name: []const u8) !bool {
    // FreeBSD ships only a bootstrap stub of pkg(8), which prompts to install
    // the real one on first use. Until then no package can be installed.
    if (pm == .pkg) {
        std.Io.Dir.accessAbsolute(io, "/usr/local/sbin/pkg", .{}) catch return false;
    }

    const result = try std.process.run(allocator, io, .{
        .argv = try checkArgv(allocator, pm, name),
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });

    return switch (pm) {
        // dpkg-query also knows removed-but-not-purged packages; only
        // "install ok installed" means installed
        .apt => result.term.success() and
            std.mem.indexOf(u8, result.stdout, "install ok installed") != null,
        else => result.term.success(),
    };
}

/// Command that exits 0 when `name` is installed (for apt, see isInstalled)
pub fn checkArgv(allocator: std.mem.Allocator, pm: system.PkgManager, name: []const u8) ![]const []const u8 {
    const argv: []const []const u8 = switch (pm) {
        .apt => &.{ "dpkg-query", "-W", "-f=${Status}", name },
        .dnf, .yum => &.{ "rpm", "-q", name },
        .apk => &.{ "apk", "info", "-e", name },
        .pkg => &.{ "pkg", "info", "-e", name },
        else => return error.UnsupportedPkgManager,
    };
    return allocator.dupe([]const u8, argv);
}

/// Command that installs or removes `name`, non-interactively
pub fn changeArgv(
    allocator: std.mem.Allocator,
    pm: system.PkgManager,
    state: PackageResource.PackageState,
    name: []const u8,
    version: ?[]const u8,
) ![]const []const u8 {
    const spec = if (version) |ver| switch (pm) {
        .apt, .apk => try std.fmt.allocPrint(allocator, "{s}={s}", .{ name, ver }),
        else => try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, ver }),
    } else name;

    const argv: []const []const u8 = switch (state) {
        .installed => switch (pm) {
            .apt => &.{ "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", spec },
            .dnf => &.{ "dnf", "install", "-y", spec },
            .yum => &.{ "yum", "install", "-y", spec },
            // Fresh images may have no package index yet
            .apk => &.{ "apk", "add", "--update-cache", spec },
            // ASSUME_ALWAYS_YES also answers the pkg(8) bootstrap prompt
            .pkg => &.{ "env", "ASSUME_ALWAYS_YES=yes", "pkg", "install", "-y", spec },
            else => return error.UnsupportedPkgManager,
        },
        .absent => switch (pm) {
            .apt => &.{ "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "remove", "-y", name },
            .dnf => &.{ "dnf", "remove", "-y", name },
            .yum => &.{ "yum", "remove", "-y", name },
            .apk => &.{ "apk", "del", name },
            .pkg => &.{ "env", "ASSUME_ALWAYS_YES=yes", "pkg", "delete", "-y", name },
            else => return error.UnsupportedPkgManager,
        },
    };
    return allocator.dupe([]const u8, argv);
}

/// Program name for error messages
fn tool(pm: system.PkgManager) []const u8 {
    return switch (pm) {
        .apt => "apt-get",
        .pkg_add => "pkg_add",
        else => @tagName(pm),
    };
}

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
        .io = std.testing.io,
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
        .pkg_manager = .pacman, // No backend yet
        .init_system = .systemd,
        .io = std.testing.io,
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
        .io = std.testing.io,
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
        .io = std.testing.io,
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
    const check_debian = std.process.run(testing.allocator, testing.io, .{
        .argv = &[_][]const u8{ "which", "dpkg-query" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(check_debian.stdout);
    defer testing.allocator.free(check_debian.stderr);

    if (!check_debian.term.success()) {
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
        .io = std.testing.io,
    };

    const state = try pkg.check(&sys_info);
    // dpkg should be installed on any Debian-based system
    try testing.expectEqual(resource.ResourceState.satisfied, state);
}

test "PackageResource check - nonexistent package" {
    // Check if we're on a Debian-based system
    const check_debian = std.process.run(testing.allocator, testing.io, .{
        .argv = &[_][]const u8{ "which", "dpkg-query" },
    }) catch return error.SkipZigTest;
    defer testing.allocator.free(check_debian.stdout);
    defer testing.allocator.free(check_debian.stderr);

    if (!check_debian.term.success()) {
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
        .io = std.testing.io,
    };

    const state = try pkg.check(&sys_info);
    // Nonexistent package should need installation
    try testing.expectEqual(resource.ResourceState.needs_change, state);
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "checkArgv per package manager" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectArgv(&.{ "dpkg-query", "-W", "-f=${Status}", "tree" }, try checkArgv(a, .apt, "tree"));
    try expectArgv(&.{ "rpm", "-q", "tree" }, try checkArgv(a, .dnf, "tree"));
    try expectArgv(&.{ "rpm", "-q", "tree" }, try checkArgv(a, .yum, "tree"));
    try expectArgv(&.{ "apk", "info", "-e", "tree" }, try checkArgv(a, .apk, "tree"));
    try expectArgv(&.{ "pkg", "info", "-e", "tree" }, try checkArgv(a, .pkg, "tree"));
    try testing.expectError(error.UnsupportedPkgManager, checkArgv(a, .brew, "tree"));
}

test "changeArgv install and remove per package manager" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectArgv(&.{ "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "tree" }, try changeArgv(a, .apt, .installed, "tree", null));
    try expectArgv(&.{ "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "remove", "-y", "tree" }, try changeArgv(a, .apt, .absent, "tree", null));
    try expectArgv(&.{ "dnf", "install", "-y", "tree" }, try changeArgv(a, .dnf, .installed, "tree", null));
    try expectArgv(&.{ "dnf", "remove", "-y", "tree" }, try changeArgv(a, .dnf, .absent, "tree", null));
    try expectArgv(&.{ "apk", "add", "--update-cache", "tree" }, try changeArgv(a, .apk, .installed, "tree", null));
    try expectArgv(&.{ "apk", "del", "tree" }, try changeArgv(a, .apk, .absent, "tree", null));
    try expectArgv(&.{ "env", "ASSUME_ALWAYS_YES=yes", "pkg", "install", "-y", "tree" }, try changeArgv(a, .pkg, .installed, "tree", null));
    try expectArgv(&.{ "env", "ASSUME_ALWAYS_YES=yes", "pkg", "delete", "-y", "tree" }, try changeArgv(a, .pkg, .absent, "tree", null));
    try testing.expectError(error.UnsupportedPkgManager, changeArgv(a, .pacman, .installed, "tree", null));
}

test "changeArgv version pinning syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const apt = try changeArgv(a, .apt, .installed, "nginx", "1.18.0-1");
    try testing.expectEqualStrings("nginx=1.18.0-1", apt[apt.len - 1]);
    const apk = try changeArgv(a, .apk, .installed, "nginx", "1.26.2-r0");
    try testing.expectEqualStrings("nginx=1.26.2-r0", apk[apk.len - 1]);
    const dnf = try changeArgv(a, .dnf, .installed, "nginx", "1.26.3");
    try testing.expectEqualStrings("nginx-1.26.3", dnf[dnf.len - 1]);
    const pkg = try changeArgv(a, .pkg, .installed, "nginx", "1.28.0");
    try testing.expectEqualStrings("nginx-1.28.0", pkg[pkg.len - 1]);
    // Removal ignores the version
    const rm = try changeArgv(a, .apt, .absent, "nginx", "1.18.0-1");
    try testing.expectEqualStrings("nginx", rm[rm.len - 1]);
}
