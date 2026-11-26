const std = @import("std");
const builtin = @import("builtin");
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

/// Tool set for managing users and groups
pub const UserTool = enum {
    shadow, // useradd, usermod, gpasswd... (Debian, Ubuntu, RHEL family)
    busybox, // adduser, addgroup, deluser, delgroup (Alpine)
    pw, // pw(8) (FreeBSD)
};

/// System information detected at runtime
pub const SystemInfo = struct {
    os_family: OsFamily,
    pkg_manager: ?PkgManager,
    init_system: ?InitSystem,
    user_tool: ?UserTool = null,
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

        info.os_family = detectOsFamily(allocator, io);

        // Detect package manager
        info.pkg_manager = detectPkgManager(io);

        // Detect init system
        info.init_system = detectInitSystem(io);

        info.user_tool = pickUserTool(
            info.os_family,
            exists(io, "/usr/sbin/useradd"),
            exists(io, "/bin/busybox"),
            exists(io, "/usr/sbin/pw"),
        );

        // One stable line; scripts/vm-test.sh asserts on it
        var buf: [160]u8 = undefined;
        output.logDebug(std.fmt.bufPrint(&buf, "os_family={t} pkg_manager={s} init_system={s} user_tool={s}", .{
            info.os_family,
            if (info.pkg_manager) |pm| @tagName(pm) else "none",
            if (info.init_system) |init| @tagName(init) else "none",
            if (info.user_tool) |tool| @tagName(tool) else "none",
        }) catch "system detected");

        return info;
    }
};

/// Detect the OS family. A binary is built for exactly one OS, so outside
/// Linux the compile target answers it; Linux distributions are told apart
/// by /etc/os-release.
fn detectOsFamily(allocator: std.mem.Allocator, io: std.Io) OsFamily {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const content = std.Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", allocator, .limited(8192)) catch {
                output.logDebug("Cannot read /etc/os-release");
                break :blk .unknown;
            };
            defer allocator.free(content);
            break :blk parseOsRelease(content);
        },
        .freebsd => .freebsd,
        .openbsd => .openbsd,
        .netbsd => .netbsd,
        .macos => .macos,
        else => .unknown,
    };
}

/// Map os-release contents to an OS family. ID is checked before ID_LIKE,
/// whatever their order in the file, so a distribution that names itself
/// wins over the ones it resembles.
pub fn parseOsRelease(content: []const u8) OsFamily {
    for ([_][]const u8{ "ID", "ID_LIKE" }) |key| {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len <= key.len or !std.mem.startsWith(u8, line, key) or line[key.len] != '=') continue;
            const value = std.mem.trim(u8, line[key.len + 1 ..], "\"'");
            // ID_LIKE is a space-separated list
            var ids = std.mem.tokenizeScalar(u8, value, ' ');
            while (ids.next()) |id| {
                if (familyForId(id)) |family| return family;
            }
        }
    }
    return .unknown;
}

fn familyForId(id: []const u8) ?OsFamily {
    const map = [_]struct { []const u8, OsFamily }{
        .{ "debian", .debian },
        .{ "ubuntu", .debian },
        .{ "rhel", .redhat },
        .{ "fedora", .redhat },
        .{ "centos", .redhat },
        .{ "rocky", .redhat },
        .{ "almalinux", .redhat },
        .{ "arch", .arch },
        .{ "alpine", .alpine },
    };
    for (map) |entry| {
        if (std.mem.eql(u8, id, entry[0])) return entry[1];
    }
    return null;
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

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Pick the user/group tool set. Alpine always gets busybox: a default
/// install has nothing else (its cloud images carry shadow only because
/// cloud-init depends on it), so behavior does not depend on extra packages.
pub fn pickUserTool(os_family: OsFamily, have_useradd: bool, have_busybox: bool, have_pw: bool) ?UserTool {
    if (have_pw) return .pw;
    if (os_family == .alpine and have_busybox) return .busybox;
    if (have_useradd) return .shadow;
    if (have_busybox) return .busybox;
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

test "parseOsRelease" {
    const cases = [_]struct { []const u8, OsFamily }{
        .{ "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nID=debian\n", .debian },
        .{ "NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n", .debian },
        .{ "NAME=\"Rocky Linux\"\nID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n", .redhat },
        .{ "NAME=\"AlmaLinux\"\nID_LIKE=\"rhel centos fedora\"\nID=\"almalinux\"\n", .redhat },
        .{ "NAME=\"Alpine Linux\"\nID=alpine\nVERSION_ID=3.24.4\n", .alpine },
        .{ "ID=linuxmint\nID_LIKE=\"ubuntu debian\"\n", .debian },
        .{ "NAME=FreeBSD\nID=freebsd\n", .unknown },
        .{ "ID=archlinux\nID_LIKE=arch\n", .arch },
        .{ "IDENTITY=debian\n", .unknown },
        .{ "", .unknown },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case[1], parseOsRelease(case[0]));
    }
}

test "pickUserTool" {
    try std.testing.expectEqual(UserTool.shadow, pickUserTool(.debian, true, false, false).?);
    try std.testing.expectEqual(UserTool.shadow, pickUserTool(.redhat, true, false, false).?);
    // Alpine with shadow installed still uses busybox
    try std.testing.expectEqual(UserTool.busybox, pickUserTool(.alpine, true, true, false).?);
    try std.testing.expectEqual(UserTool.busybox, pickUserTool(.unknown, false, true, false).?);
    try std.testing.expectEqual(UserTool.pw, pickUserTool(.freebsd, false, false, true).?);
    try std.testing.expect(pickUserTool(.macos, false, false, false) == null);
}
