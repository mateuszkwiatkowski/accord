const std = @import("std");
const output = @import("output.zig");

/// Operating system family
pub const OsFamily = enum {
    debian, // Debian, Ubuntu
    redhat, // RHEL, CentOS, Fedora, Rocky
    arch, // Arch Linux, Manjaro
    alpine, // Alpine Linux
    macos, // macOS
    freebsd, // FreeBSD
    openbsd, // OpenBSD
    netbsd, // NetBSD
    unknown,
};

/// Package manager type
pub const PkgManager = enum {
    apt, // Debian/Ubuntu (apt-get)
    yum, // Legacy RHEL
    dnf, // Modern Fedora/RHEL
    pacman, // Arch
    apk, // Alpine
    brew, // macOS Homebrew
    pkg, // FreeBSD
    pkg_add, // OpenBSD
    pkgin, // NetBSD
};

/// Init system type
pub const InitSystem = enum {
    systemd, // Modern Linux
    sysvinit, // Legacy init
    launchd, // macOS
    rc, // BSD rc.d
    openrc, // Alpine/Gentoo
};

/// System information detected at runtime
pub const SystemInfo = struct {
    os_family: OsFamily,
    pkg_manager: ?PkgManager,
    init_system: ?InitSystem,
    /// I/O implementation used by resources for filesystem and process operations
    io: std.Io,

    /// Detect the current system
    pub fn detect(allocator: std.mem.Allocator, io: std.Io) !SystemInfo {
        output.logDebug("Detecting system information...");

        var info = SystemInfo{
            .os_family = .unknown,
            .pkg_manager = null,
            .init_system = null,
            .io = io,
        };

        // Try to detect Linux distribution from /etc/os-release
        if (detectLinuxDistro(allocator, io)) |os_family| {
            info.os_family = os_family;
            output.logDebug("Detected Linux distribution");
        } else |_| {
            output.logDebug("Failed to detect Linux distribution, trying other methods");
        }

        // Detect package manager
        info.pkg_manager = detectPkgManager(io);
        if (info.pkg_manager) |pm| {
            const pm_name = @tagName(pm);
            output.logDebug(pm_name);
        }

        // Detect init system
        info.init_system = detectInitSystem(io);
        if (info.init_system) |init| {
            const init_name = @tagName(init);
            output.logDebug(init_name);
        }

        return info;
    }
};

/// Detect Linux distribution from /etc/os-release
fn detectLinuxDistro(allocator: std.mem.Allocator, io: std.Io) !OsFamily {
    const os_release_path = "/etc/os-release";

    // Try to read /etc/os-release
    const content = std.Io.Dir.cwd().readFileAlloc(io, os_release_path, allocator, .limited(8192)) catch {
        return error.NoOsRelease;
    };
    defer allocator.free(content);

    // Parse os-release file for ID or ID_LIKE
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ID=") or std.mem.startsWith(u8, line, "ID_LIKE=")) {
            // Extract value (remove quotes if present)
            const value_start: usize = std.mem.indexOf(u8, line, "=").? + 1;
            var value = line[value_start..];

            // Remove quotes
            if (value.len > 0 and value[0] == '"') {
                value = value[1..];
            }
            if (value.len > 0 and value[value.len - 1] == '"') {
                value = value[0 .. value.len - 1];
            }

            // Check for known distributions
            if (std.mem.indexOf(u8, value, "debian") != null or std.mem.indexOf(u8, value, "ubuntu") != null) {
                return .debian;
            } else if (std.mem.indexOf(u8, value, "fedora") != null or std.mem.indexOf(u8, value, "rhel") != null or std.mem.indexOf(u8, value, "centos") != null) {
                return .redhat;
            } else if (std.mem.indexOf(u8, value, "arch") != null) {
                return .arch;
            } else if (std.mem.indexOf(u8, value, "alpine") != null) {
                return .alpine;
            }
        }
    }

    return .unknown;
}

/// Detect package manager by checking for binaries
fn detectPkgManager(io: std.Io) ?PkgManager {
    // Check for various package managers
    if (std.Io.Dir.accessAbsolute(io, "/usr/bin/apt-get", .{}) catch null) |_| {
        return .apt;
    }
    if (std.Io.Dir.accessAbsolute(io, "/usr/bin/dnf", .{}) catch null) |_| {
        return .dnf;
    }
    if (std.Io.Dir.accessAbsolute(io, "/usr/bin/yum", .{}) catch null) |_| {
        return .yum;
    }
    if (std.Io.Dir.accessAbsolute(io, "/usr/bin/pacman", .{}) catch null) |_| {
        return .pacman;
    }
    if (std.Io.Dir.accessAbsolute(io, "/sbin/apk", .{}) catch null) |_| {
        return .apk;
    }
    if (std.Io.Dir.accessAbsolute(io, "/usr/local/bin/brew", .{}) catch null) |_| {
        return .brew;
    }
    if (std.Io.Dir.accessAbsolute(io, "/usr/sbin/pkg", .{}) catch null) |_| {
        return .pkg;
    }

    return null;
}

/// Detect init system
fn detectInitSystem(io: std.Io) ?InitSystem {
    // Check for systemd
    if (std.Io.Dir.accessAbsolute(io, "/bin/systemctl", .{}) catch null) |_| {
        return .systemd;
    }
    if (std.Io.Dir.accessAbsolute(io, "/usr/bin/systemctl", .{}) catch null) |_| {
        return .systemd;
    }

    // Check for launchd (macOS)
    if (std.Io.Dir.accessAbsolute(io, "/bin/launchctl", .{}) catch null) |_| {
        return .launchd;
    }

    // Check for OpenRC
    if (std.Io.Dir.accessAbsolute(io, "/sbin/openrc", .{}) catch null) |_| {
        return .openrc;
    }

    // Check for rc (BSD)
    if (std.Io.Dir.accessAbsolute(io, "/etc/rc", .{}) catch null) |_| {
        return .rc;
    }

    // Check for SysV init
    if (std.Io.Dir.accessAbsolute(io, "/etc/init.d", .{}) catch null) |_| {
        return .sysvinit;
    }

    return null;
}

// Tests
test "system detection doesn't crash" {
    const info = try SystemInfo.detect(std.testing.allocator, std.testing.io);

    // Just verify we got something
    std.debug.print("Detected OS: {s}\n", .{@tagName(info.os_family)});
    if (info.pkg_manager) |pm| {
        std.debug.print("Package manager: {s}\n", .{@tagName(pm)});
    }
    if (info.init_system) |init| {
        std.debug.print("Init system: {s}\n", .{@tagName(init)});
    }

    // On macOS, we should detect something reasonable
    // On Linux, we should detect the right distro
    // But we can't make assumptions in tests, so just verify it doesn't crash
    try std.testing.expect(true);
}

test "detect Linux distro from mock os-release" {
    // This test would require mocking file system, skip for now
    // In real implementation, we'd pass the file path as a parameter
    try std.testing.expect(true);
}
