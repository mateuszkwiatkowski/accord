const std = @import("std");
const parser = @import("parser.zig");
const system = @import("system.zig");
const output = @import("output.zig");
const resource = @import("resources/resource.zig");

/// Result of applying resources
pub const ApplyResult = struct {
    total: usize,
    satisfied: usize,
    applied: usize,
    failed: usize,
};

/// Apply all resources in a manifest. Sections run in a fixed order, each
/// earlier one providing what later ones need: the package index, then
/// packages (which may create groups and users), groups, users (which may be
/// named as owners), directories, files (which may live in those
/// directories), and services last. Within a section, manifest order.
pub fn applyManifest(
    manifest: *parser.Manifest,
    sys: *const system.SystemInfo,
    dry_run: bool,
) !ApplyResult {
    var result = ApplyResult{
        .total = 0,
        .satisfied = 0,
        .applied = 0,
        .failed = 0,
    };

    if (manifest.package_cache) |*cache| try applyOne("PackageCache", cache, sys, dry_run, &result);
    for (manifest.packages) |*pkg| try applyOne("Package", pkg, sys, dry_run, &result);
    for (manifest.groups) |*group| try applyOne("Group", group, sys, dry_run, &result);
    for (manifest.users) |*user| try applyOne("User", user, sys, dry_run, &result);
    for (manifest.directories) |*dir| try applyOne("Directory", dir, sys, dry_run, &result);
    for (manifest.files) |*file| try applyOne("File", file, sys, dry_run, &result);
    for (manifest.services) |*svc| try applyOne("Service", svc, sys, dry_run, &result);

    return result;
}

/// Check one resource and apply it if needed. An error stops the run unless
/// the resource has allow_failure set, in which case it is counted and logged.
fn applyOne(
    comptime kind: []const u8,
    res: anytype,
    sys: *const system.SystemInfo,
    dry_run: bool,
    result: *ApplyResult,
) !void {
    result.total += 1;
    const name = res.describe();

    const state = res.check(sys) catch |err| {
        if (!res.base.allow_failure) return err;
        output.logError(kind, name, @errorName(err));
        result.failed += 1;
        return;
    };

    output.logCheck(kind, name, switch (state) {
        .satisfied => "already satisfied",
        .needs_change => "needs changes",
        .failed => "check failed",
    });

    if (state == .satisfied) {
        result.satisfied += 1;
        return;
    }

    // The resource logs its own output
    const apply_result = res.apply(sys, dry_run) catch |err| {
        if (!res.base.allow_failure) return err;
        output.logError(kind, name, @errorName(err));
        result.failed += 1;
        return;
    };

    if (apply_result.changed) {
        result.applied += 1;
    } else {
        result.satisfied += 1;
    }
}

// Tests
test "apply empty manifest" {
    const allocator = std.testing.allocator;

    var manifest = try parser.parse(allocator, ".{}");
    defer manifest.deinit();

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
        .io = std.testing.io,
    };

    const result = try applyManifest(&manifest, &sys, false);

    try std.testing.expect(result.total == 0);
    try std.testing.expect(result.applied == 0);
    try std.testing.expect(result.failed == 0);
}

test "apply manifest with one directory" {
    const allocator = std.testing.allocator;

    const test_path = "/tmp/accord-apply-test";

    // Cleanup first
    std.Io.Dir.deleteDirAbsolute(std.testing.io, test_path) catch {};

    const content =
        \\.{
        \\    .directories = .{
        \\        .@"/tmp/accord-apply-test" = .{
        \\            .mode = 0o755,
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parser.parse(allocator, content);
    defer manifest.deinit();

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
        .io = std.testing.io,
    };

    const result = try applyManifest(&manifest, &sys, false);

    try std.testing.expect(result.total == 1);
    try std.testing.expect(result.applied == 1);
    try std.testing.expect(result.failed == 0);

    // Verify directory was created
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, test_path, .{});
    dir.close(std.testing.io);

    // Cleanup
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, test_path);
}

test "apply manifest idempotency" {
    const allocator = std.testing.allocator;

    const test_path = "/tmp/accord-apply-idempotent";

    // Cleanup first
    std.Io.Dir.deleteDirAbsolute(std.testing.io, test_path) catch {};

    const content =
        \\.{
        \\    .directories = .{
        \\        .@"/tmp/accord-apply-idempotent" = .{},
        \\    },
        \\}
    ;

    var manifest = try parser.parse(allocator, content);
    defer manifest.deinit();

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
        .io = std.testing.io,
    };

    // First apply - should create
    const result1 = try applyManifest(&manifest, &sys, false);
    try std.testing.expect(result1.applied == 1);

    // Second apply - should be satisfied
    const result2 = try applyManifest(&manifest, &sys, false);
    try std.testing.expect(result2.satisfied == 1);
    try std.testing.expect(result2.applied == 0);

    // Cleanup
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, test_path);
}

test "apply manifest with dry run" {
    const allocator = std.testing.allocator;

    const test_path = "/tmp/accord-apply-dryrun";

    // Ensure doesn't exist
    std.Io.Dir.deleteDirAbsolute(std.testing.io, test_path) catch {};

    const content =
        \\.{
        \\    .directories = .{
        \\        .@"/tmp/accord-apply-dryrun" = .{},
        \\    },
        \\}
    ;

    var manifest = try parser.parse(allocator, content);
    defer manifest.deinit();

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
        .io = std.testing.io,
    };

    // Apply with dry_run = true
    const result = try applyManifest(&manifest, &sys, true);
    try std.testing.expect(result.applied == 1);

    // Verify directory was NOT created
    const open_result = std.Io.Dir.openDirAbsolute(std.testing.io, test_path, .{});
    try std.testing.expectError(error.FileNotFound, open_result);
}

test "apply manifest with allow_failure" {
    const allocator = std.testing.allocator;

    // Use a path that will fail (permission denied or doesn't exist)
    const content =
        \\.{
        \\    .directories = .{
        \\        .@"/root/accord-test-fail" = .{
        \\            .allow_failure = true,
        \\        },
        \\        .@"/tmp/accord-test-success" = .{},
        \\    },
        \\}
    ;

    var manifest = try parser.parse(allocator, content);
    defer manifest.deinit();

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
        .io = std.testing.io,
    };

    // Should not error even though first directory fails
    const result = try applyManifest(&manifest, &sys, false);
    try std.testing.expect(result.total == 2);

    // Cleanup success directory
    std.Io.Dir.deleteDirAbsolute(std.testing.io, "/tmp/accord-test-success") catch {};
}
