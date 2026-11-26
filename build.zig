const std = @import("std");

/// Single source of the version: build.zig.zon
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Release date for the man pages; scripts/release.sh passes the tagged
    // commit's date, so a rebuild of the same tag is identical
    const date = b.option([]const u8, "date", "Date printed in the man pages (YYYY-MM-DD)") orelse "";

    const strip = b.option(bool, "strip", "Omit debug info from the executable");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // Required for chmod(), getpwnam(), getgrnam()
        .strip = strip,
    });
    root_module.addOptions("build_options", options);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "accord",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run accord");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Install the test binary instead of running it, so it can be built for
    // another -Dtarget and run there (see scripts/vm-test.sh)
    const install_tests = b.addInstallArtifact(unit_tests, .{
        .dest_sub_path = "accord-test",
    });
    const test_bin_step = b.step("test-bin", "Install the unit test binary as bin/accord-test");
    test_bin_step.dependOn(&install_tests.step);

    // Man pages: @VERSION@ and @DATE@ filled in, each in its man<section>/
    const stamp_man = b.addExecutable(.{
        .name = "stamp_man",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/stamp_man.zig"),
            .target = b.graph.host,
        }),
    });
    for ([_][]const u8{ "accord.1", "accord-manifest.5", "accord-resources.7" }) |page| {
        const stamp = b.addRunArtifact(stamp_man);
        stamp.addFileArg(b.path(b.fmt("doc/{s}", .{page})));
        const stamped = stamp.addOutputFileArg(page);
        stamp.addArgs(&.{ version, date });
        const section = page[page.len - 1 ..];
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            stamped,
            .{ .custom = b.fmt("share/man/man{s}", .{section}) },
            page,
        ).step);
    }
}
