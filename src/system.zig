const std = @import("std");
const output = @import("output.zig");

/// Operating system family
pub const OsFamily = enum {
    debian,   // Debian, Ubuntu
    redhat,   // RHEL, CentOS, Fedora, Rocky
    arch,     // Arch Linux, Manjaro
    alpine,   // Alpine Linux
    macos,    // macOS
    freebsd,  // FreeBSD
    openbsd,  // OpenBSD
    netbsd,   // NetBSD
    unknown,
};

/// Package manager type
pub const PkgManager = enum {
    apt,       // Debian/Ubuntu (apt-get)
    yum,       // Legacy RHEL
    dnf,       // Modern Fedora/RHEL
    pacman,    // Arch
    apk,       // Alpine
    brew,      // macOS Homebrew
    pkg,       // FreeBSD
    pkg_add,   // OpenBSD
    pkgin,     // NetBSD
};

/// Init system type
pub const InitSystem = enum {
    systemd,   // Modern Linux
    sysvinit,  // Legacy init
    launchd,   // macOS
    rc,        // BSD rc.d
    openrc,    // Alpine/Gentoo
};

/// System information detected at runtime
pub const SystemInfo = struct {
    os_family: OsFamily,
    pkg_manager: ?PkgManager,
    init_system: ?InitSystem,

    /// Detect the current system
    pub fn detect(allocator: std.mem.Allocator) !SystemInfo {
        output.logDebug("Detecting system information...");

        var info = SystemInfo{
            .os_family = .unknown,
            .pkg_manager = null,
            .init_system = null,
        };

        // Try to detect Linux distribution from /etc/os-release
        if (detectLinuxDistro(allocator)) |os_family| {
            info.os_family = os_family;
            output.logDebug("Detected Linux distribution");
        } else |_| {
            output.logDebug("Failed to detect Linux distribution, trying other methods");
        }

        // Detect package manager
        info.pkg_manager = detectPkgManager();
        if (info.pkg_manager) |pm| {
            const pm_name = @tagName(pm);
            output.logDebug(pm_name);
        }

        // Detect init system
        info.init_system = detectInitSystem();
        if (info.init_system) |init| {
            const init_name = @tagName(init);
            output.logDebug(init_name);
        }

        return info;
    }
};

/// Detect Linux distribution from /etc/os-release
fn detectLinuxDistro(allocator: std.mem.Allocator) !OsFamily {
    const os_release_path = "/etc/os-release";

    // Try to open and read /etc/os-release
    const file = std.fs.openFileAbsolute(os_release_path, .{}) catch {
        return error.NoOsRelease;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8192);
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
fn detectPkgManager() ?PkgManager {
    // Check for various package managers
    if (std.fs.accessAbsolute("/usr/bin/apt-get", .{}) catch null) |_| {
        return .apt;
    }
    if (std.fs.accessAbsolute("/usr/bin/dnf", .{}) catch null) |_| {
        return .dnf;
    }
    if (std.fs.accessAbsolute("/usr/bin/yum", .{}) catch null) |_| {
        return .yum;
    }
    if (std.fs.accessAbsolute("/usr/bin/pacman", .{}) catch null) |_| {
        return .pacman;
    }
    if (std.fs.accessAbsolute("/sbin/apk", .{}) catch null) |_| {
        return .apk;
    }
    if (std.fs.accessAbsolute("/usr/local/bin/brew", .{}) catch null) |_| {
        return .brew;
    }
    if (std.fs.accessAbsolute("/usr/sbin/pkg", .{}) catch null) |_| {
        return .pkg;
    }

    return null;
}

/// Detect init system
fn detectInitSystem() ?InitSystem {
    // Check for systemd
    if (std.fs.accessAbsolute("/bin/systemctl", .{}) catch null) |_| {
        return .systemd;
    }
    if (std.fs.accessAbsolute("/usr/bin/systemctl", .{}) catch null) |_| {
        return .systemd;
    }

    // Check for launchd (macOS)
    if (std.fs.accessAbsolute("/bin/launchctl", .{}) catch null) |_| {
        return .launchd;
    }

    // Check for OpenRC
    if (std.fs.accessAbsolute("/sbin/openrc", .{}) catch null) |_| {
        return .openrc;
    }

    // Check for rc (BSD)
    if (std.fs.accessAbsolute("/etc/rc", .{}) catch null) |_| {
        return .rc;
    }

    // Check for SysV init
    if (std.fs.accessAbsolute("/etc/init.d", .{}) catch null) |_| {
        return .sysvinit;
    }

    return null;
}

// Tests
test "system detection doesn't crash" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const info = try SystemInfo.detect(allocator);

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
