const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // Required for chmod(), getpwnam(), getgrnam()
    });

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

    // Man pages installation
    const install_man = b.addInstallDirectory(.{
        .source_dir = b.path("doc"),
        .install_dir = .prefix,
        .install_subdir = "share/man",
    });
    b.getInstallStep().dependOn(&install_man.step);
}
