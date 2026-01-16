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

/// Apply all resources in a manifest
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

    // Apply directories
    if (manifest.directories) |*dirs| {
        var iter = dirs.iterator();
        while (iter.next()) |entry| {
            result.total += 1;
            const dir = entry.value_ptr;

            // Check current state
            const state = dir.check(sys) catch |err| {
                if (dir.base.allow_failure) {
                    output.logError("Directory", dir.path, @errorName(err));
                    result.failed += 1;
                    continue;
                } else {
                    return err;
                }
            };

            // Log check result
            const status_msg = switch (state) {
                .satisfied => "already satisfied",
                .needs_change => "needs changes",
                .failed => "check failed",
            };
            output.logCheck("Directory", dir.path, status_msg);

            // If already satisfied, skip
            if (state == .satisfied) {
                result.satisfied += 1;
                continue;
            }

            // Apply changes
            output.logDebug(if (dry_run) "Calling dir.apply with dry_run=true" else "Calling dir.apply with dry_run=false");
            const apply_result = dir.apply(sys, dry_run) catch |err| {
                if (dir.base.allow_failure) {
                    output.logError("Directory", dir.path, @errorName(err));
                    result.failed += 1;
                    continue;
                } else {
                    return err;
                }
            };

            // Log application
            output.logApply("Directory", dir.path, apply_result.message);

            if (apply_result.changed) {
                result.applied += 1;
            } else {
                result.satisfied += 1;
            }
        }
    }

    // Future: apply files, packages, services, users, groups

    return result;
}

// Tests
test "apply empty manifest" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manifest = parser.Manifest.init(allocator);
    defer manifest.deinit();

    const sys = system.SystemInfo{
        .os_family = .unknown,
        .pkg_manager = null,
        .init_system = null,
    };

    const result = try applyManifest(&manifest, &sys, false);

    try std.testing.expect(result.total == 0);
    try std.testing.expect(result.applied == 0);
    try std.testing.expect(result.failed == 0);
}

test "apply manifest with one directory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_path = "/tmp/accord-apply-test";

    // Cleanup first
    std.fs.deleteDirAbsolute(test_path) catch {};

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
    };

    const result = try applyManifest(&manifest, &sys, false);

    try std.testing.expect(result.total == 1);
    try std.testing.expect(result.applied == 1);
    try std.testing.expect(result.failed == 0);

    // Verify directory was created
    var dir = try std.fs.openDirAbsolute(test_path, .{});
    dir.close();

    // Cleanup
    try std.fs.deleteDirAbsolute(test_path);
}

test "apply manifest idempotency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_path = "/tmp/accord-apply-idempotent";

    // Cleanup first
    std.fs.deleteDirAbsolute(test_path) catch {};

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
    };

    // First apply - should create
    const result1 = try applyManifest(&manifest, &sys, false);
    try std.testing.expect(result1.applied == 1);

    // Second apply - should be satisfied
    const result2 = try applyManifest(&manifest, &sys, false);
    try std.testing.expect(result2.satisfied == 1);
    try std.testing.expect(result2.applied == 0);

    // Cleanup
    try std.fs.deleteDirAbsolute(test_path);
}

test "apply manifest with dry run" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_path = "/tmp/accord-apply-dryrun";

    // Ensure doesn't exist
    std.fs.deleteDirAbsolute(test_path) catch {};

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
    };

    // Apply with dry_run = true
    const result = try applyManifest(&manifest, &sys, true);
    try std.testing.expect(result.applied == 1);

    // Verify directory was NOT created
    const open_result = std.fs.openDirAbsolute(test_path, .{});
    try std.testing.expectError(error.FileNotFound, open_result);
}

test "apply manifest with allow_failure" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
    };

    // Should not error even though first directory fails
    const result = try applyManifest(&manifest, &sys, false);
    try std.testing.expect(result.total == 2);
    
    // Cleanup success directory
    std.fs.deleteDirAbsolute("/tmp/accord-test-success") catch {};
}
