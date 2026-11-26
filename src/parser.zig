const std = @import("std");
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const DirectoryResource = @import("resources/directory.zig").DirectoryResource;
const FileResource = @import("resources/file.zig").FileResource;
const PackageResource = @import("resources/package.zig").PackageResource;
const ServiceResource = @import("resources/service.zig").ServiceResource;
const PackageCacheResource = @import("resources/package_cache.zig").PackageCacheResource;
const GroupResource = @import("resources/group.zig").GroupResource;
const UserResource = @import("resources/user.zig").UserResource;
const output = @import("output.zig");

/// Manifest structure containing all resources, each section in manifest order
pub const Manifest = struct {
    package_cache: ?PackageCacheResource = null, // Singular, nameless pattern
    directories: []DirectoryResource = &.{},
    files: []FileResource = &.{},
    packages: []PackageResource = &.{},
    services: []ServiceResource = &.{},
    groups: []GroupResource = &.{},
    users: []UserResource = &.{},

    /// Owns the resource slices and every string they point to
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{ InvalidManifest, OutOfMemory };

/// Top-level sections, for the "unknown section" message
const sections_list = "package_cache, packages, groups, users, directories, files, services";

/// Resource bodies as written in a manifest. The key (path or name) is not
/// part of the body, and `allow_failure` sits beside the other attributes.
/// Any field not listed here is rejected.
const DirectorySpec = struct {
    mode: ?u32 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
    state: DirectoryResource.DirState = .present,
    allow_failure: bool = false,
};

const FileSpec = struct {
    content: ?[]const u8 = null,
    source: ?[]const u8 = null,
    mode: ?u32 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
    state: FileResource.FileState = .present,
    allow_failure: bool = false,
};

const PackageSpec = struct {
    state: PackageResource.PackageState = .installed,
    version: ?[]const u8 = null,
    allow_failure: bool = false,
};

const ServiceSpec = struct {
    state: ServiceResource.ServiceState = .running,
    enabled: bool = true,
    allow_failure: bool = false,
};

const GroupSpec = struct {
    gid: ?u32 = null,
    state: GroupResource.GroupState = .present,
    allow_failure: bool = false,
};

const UserSpec = struct {
    uid: ?u32 = null,
    group: ?[]const u8 = null,
    groups: []const []const u8 = &.{},
    membership: UserResource.Membership = .append,
    shell: ?[]const u8 = null,
    home: ?[]const u8 = null,
    state: UserResource.UserState = .present,
    remove_home: bool = false,
    allow_failure: bool = false,
};

const PackageCacheSpec = struct {
    allow_failure: bool = false,
};

/// Parse a manifest. On error.InvalidManifest the reason is discarded; use
/// parseReporting to get it.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) ParseError!Manifest {
    var message: ?[]u8 = null;
    defer if (message) |m| gpa.free(m);
    return parseReporting(gpa, source, "manifest", &message);
}

/// Parse a manifest with Zig's ZON parser. Unknown sections, unknown
/// attributes, wrong types and syntax errors are all error.InvalidManifest;
/// then `message` is set to a "path:line:col: error: ..." description,
/// allocated with `gpa` and owned by the caller.
pub fn parseReporting(
    gpa: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    message: *?[]u8,
) ParseError!Manifest {
    output.logDebug("Parsing manifest...");

    const source_z = try gpa.dupeSentinel(u8, source, 0);
    defer gpa.free(source_z);

    var ast = try Ast.parse(gpa, source_z, .{ .mode = .zon });
    defer ast.deinit(gpa);
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var p = Parser{
        .gpa = gpa,
        .arena = arena.allocator(),
        .ast = &ast,
        .zoir = &zoir,
        .path = path,
        .message = message,
    };

    var manifest = Manifest{ .arena = undefined };
    try p.parseRoot(&manifest);
    manifest.arena = arena;
    return manifest;
}

const Parser = struct {
    gpa: std.mem.Allocator,
    /// Results: outlives the parser as Manifest.arena
    arena: std.mem.Allocator,
    ast: *const Ast,
    zoir: *const Zoir,
    path: []const u8,
    message: *?[]u8,

    fn parseRoot(p: *Parser, manifest: *Manifest) ParseError!void {
        // Syntax errors: let std.zon report them in its own format
        if (p.zoir.hasCompileErrors()) {
            _ = try p.typed(bool, .root);
            unreachable;
        }

        const root = switch (Zoir.Node.Index.root.get(p.zoir)) {
            .empty_literal => return,
            .struct_literal => |s| s,
            else => return p.fail(.root, false, "a manifest is a struct literal: .{{ .files = .{{ ... }}, ... }}", .{}),
        };

        for (root.names, 0..) |name_nts, i| {
            const name = name_nts.get(p.zoir);
            const node = root.vals.at(@intCast(i));

            if (std.mem.eql(u8, name, "package_cache") or std.mem.eql(u8, name, "apt_update")) {
                if (manifest.package_cache != null) {
                    return p.fail(node, true, "package_cache given twice (apt_update is another name for it)", .{});
                }
                const spec = try p.typed(PackageCacheSpec, node);
                manifest.package_cache = .{ .base = .{ .allow_failure = spec.allow_failure } };
            } else if (std.mem.eql(u8, name, "directories")) {
                const entries = try p.section(DirectorySpec, node, true);
                const dirs = try p.arena.alloc(DirectoryResource, entries.len);
                for (entries, dirs) |e, *dir| dir.* = .{
                    .base = .{ .allow_failure = e.spec.allow_failure },
                    .path = e.key,
                    .mode = e.spec.mode,
                    .owner = e.spec.owner,
                    .group = e.spec.group,
                    .state = e.spec.state,
                };
                manifest.directories = dirs;
            } else if (std.mem.eql(u8, name, "files")) {
                const entries = try p.section(FileSpec, node, true);
                const files = try p.arena.alloc(FileResource, entries.len);
                for (entries, files) |e, *file| file.* = .{
                    .base = .{ .allow_failure = e.spec.allow_failure },
                    .path = e.key,
                    .content = e.spec.content,
                    .source = e.spec.source,
                    .mode = e.spec.mode,
                    .owner = e.spec.owner,
                    .group = e.spec.group,
                    .state = e.spec.state,
                };
                manifest.files = files;
            } else if (std.mem.eql(u8, name, "packages")) {
                const entries = try p.section(PackageSpec, node, false);
                const pkgs = try p.arena.alloc(PackageResource, entries.len);
                for (entries, pkgs) |e, *pkg| pkg.* = .{
                    .base = .{ .allow_failure = e.spec.allow_failure },
                    .name = e.key,
                    .state = e.spec.state,
                    .version = e.spec.version,
                };
                manifest.packages = pkgs;
            } else if (std.mem.eql(u8, name, "services")) {
                const entries = try p.section(ServiceSpec, node, false);
                const svcs = try p.arena.alloc(ServiceResource, entries.len);
                for (entries, svcs) |e, *svc| svc.* = .{
                    .base = .{ .allow_failure = e.spec.allow_failure },
                    .name = e.key,
                    .state = e.spec.state,
                    .enabled = e.spec.enabled,
                };
                manifest.services = svcs;
            } else if (std.mem.eql(u8, name, "groups")) {
                const entries = try p.section(GroupSpec, node, false);
                const groups = try p.arena.alloc(GroupResource, entries.len);
                for (entries, groups) |e, *group| group.* = .{
                    .base = .{ .allow_failure = e.spec.allow_failure },
                    .name = e.key,
                    .gid = e.spec.gid,
                    .state = e.spec.state,
                };
                manifest.groups = groups;
            } else if (std.mem.eql(u8, name, "users")) {
                const entries = try p.section(UserSpec, node, false);
                const users = try p.arena.alloc(UserResource, entries.len);
                for (entries, users) |e, *user| {
                    // Account names reach useradd & co. as arguments
                    if (e.spec.group) |g| try p.checkAccountName(node, g);
                    for (e.spec.groups) |g| try p.checkAccountName(node, g);
                    user.* = .{
                        .base = .{ .allow_failure = e.spec.allow_failure },
                        .name = e.key,
                        .uid = e.spec.uid,
                        .group = e.spec.group,
                        .groups = e.spec.groups,
                        .membership = e.spec.membership,
                        .shell = e.spec.shell,
                        .home = e.spec.home,
                        .state = e.spec.state,
                        .remove_home = e.spec.remove_home,
                    };
                }
                manifest.users = users;
            } else {
                return p.fail(node, true, "unknown section '.{s}' (supported: {s})", .{ name, sections_list });
            }
        }
    }

    fn Entry(comptime Spec: type) type {
        return struct { key: []const u8, spec: Spec };
    }

    /// A section is `.{ .key = .{ ...body... }, ... }`; keys are paths when
    /// `paths` is set, names otherwise
    fn section(p: *Parser, comptime Spec: type, node: Zoir.Node.Index, paths: bool) ParseError![]Entry(Spec) {
        const s = switch (node.get(p.zoir)) {
            .empty_literal => return &.{},
            .struct_literal => |s| s,
            else => return p.fail(node, false, "expected .{{ .@\"key\" = .{{ ... }}, ... }}", .{}),
        };

        const entries = try p.arena.alloc(Entry(Spec), s.names.len);
        for (s.names, entries, 0..) |name_nts, *entry, i| {
            const body = s.vals.at(@intCast(i));
            const key = name_nts.get(p.zoir);
            // Resources use *Absolute filesystem calls, which assert this
            if (paths and !std.fs.path.isAbsolute(key)) {
                return p.fail(body, true, "'{s}' is not an absolute path", .{key});
            }
            if (!paths) try p.checkName(body, key);
            entry.* = .{
                .key = try p.arena.dupe(u8, key),
                .spec = try p.typed(Spec, body),
            };
        }
        return entries;
    }

    /// Names are passed to package, service and account tools as arguments:
    /// one starting with '-' would be read as an option
    fn checkName(p: *Parser, node: Zoir.Node.Index, name: []const u8) ParseError!void {
        if (name.len == 0 or name[0] == '-' or std.mem.indexOfAny(u8, name, " \t\n/:,") != null) {
            return p.fail(node, true, "'{s}' is not a valid name", .{name});
        }
    }

    fn checkAccountName(p: *Parser, section_node: Zoir.Node.Index, name: []const u8) ParseError!void {
        if (name.len == 0 or name[0] == '-' or std.mem.indexOfAny(u8, name, " \t\n/:,") != null) {
            return p.fail(section_node, true, "'{s}' is not a valid group name", .{name});
        }
    }

    /// Parse one node into T with std.zon: strict about unknown fields and types
    fn typed(p: *Parser, comptime T: type, node: Zoir.Node.Index) ParseError!T {
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        return std.zon.parse.fromZoir(T, .{
            .arena = p.arena,
            .ast = p.ast,
            .zoir = p.zoir,
            .node = node,
            .diagnostics = &diagnostics,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => {
                p.message.* = try std.fmt.allocPrint(p.gpa, "{f}", .{diagnostics.fmt(p.path)});
                return error.InvalidManifest;
            },
        };
    }

    /// Record an error at `node`, or at the field name in front of it
    fn fail(p: *Parser, node: Zoir.Node.Index, at_name: bool, comptime fmt: []const u8, args: anytype) ParseError {
        const ast_node = node.getAstNode(p.zoir);
        // `.name = value`: the name is two tokens before the value
        const token = if (at_name) p.ast.firstToken(ast_node) - 2 else p.ast.firstToken(ast_node);
        const loc = p.ast.tokenLocation(0, token);
        const reason = try std.fmt.allocPrint(p.gpa, fmt, args);
        defer p.gpa.free(reason);
        p.message.* = try std.fmt.allocPrint(p.gpa, "{s}:{d}:{d}: error: {s}", .{
            p.path, loc.line + 1, loc.column + 1, reason,
        });
        return error.InvalidManifest;
    }
};

// Tests
const testing = std.testing;

/// Parse content that must be rejected; return the message
fn expectInvalid(content: []const u8) ![]u8 {
    var message: ?[]u8 = null;
    var manifest = parseReporting(testing.allocator, content, "m.zon", &message) catch |err| {
        try testing.expectEqual(error.InvalidManifest, err);
        return message orelse error.NoMessage;
    };
    manifest.deinit();
    return error.ExpectedInvalidManifest;
}

fn expectInvalidWith(content: []const u8, needle: []const u8) !void {
    const message = try expectInvalid(content);
    defer testing.allocator.free(message);
    if (std.mem.indexOf(u8, message, needle) == null) {
        std.debug.print("message: {s}\nexpected to contain: {s}\n", .{ message, needle });
        return error.TestUnexpectedMessage;
    }
}

test "parse empty manifest" {
    var manifest = try parse(testing.allocator, ".{}");
    defer manifest.deinit();

    try testing.expect(manifest.package_cache == null);
    try testing.expectEqual(0, manifest.directories.len);
    try testing.expectEqual(0, manifest.files.len);
    try testing.expectEqual(0, manifest.packages.len);
    try testing.expectEqual(0, manifest.services.len);
}

test "parse empty sections" {
    var manifest = try parse(testing.allocator, ".{ .directories = .{}, .services = .{} }");
    defer manifest.deinit();
    try testing.expectEqual(0, manifest.directories.len);
}

test "parse directories with defaults and attributes, in manifest order" {
    const content =
        \\.{
        \\    .directories = .{
        \\        .@"/tmp/z" = .{},
        \\        .@"/tmp/a" = .{
        \\            .mode = 0o750,
        \\            .owner = "www-data",
        \\            .group = "www-data",
        \\        },
        \\        .@"/tmp/m" = .{ .state = .absent, .allow_failure = true },
        \\    },
        \\}
    ;
    var manifest = try parse(testing.allocator, content);
    defer manifest.deinit();

    const dirs = manifest.directories;
    try testing.expectEqual(3, dirs.len);
    try testing.expectEqualStrings("/tmp/z", dirs[0].path);
    try testing.expectEqualStrings("/tmp/a", dirs[1].path);
    try testing.expectEqualStrings("/tmp/m", dirs[2].path);

    try testing.expect(dirs[0].mode == null);
    try testing.expectEqual(DirectoryResource.DirState.present, dirs[0].state);
    try testing.expect(!dirs[0].base.allow_failure);

    try testing.expectEqual(@as(?u32, 0o750), dirs[1].mode);
    try testing.expectEqualStrings("www-data", dirs[1].owner.?);
    try testing.expectEqualStrings("www-data", dirs[1].group.?);

    try testing.expectEqual(DirectoryResource.DirState.absent, dirs[2].state);
    try testing.expect(dirs[2].base.allow_failure);
}

test "parse file with multi-line content" {
    const content =
        \\.{
        \\    .files = .{
        \\        .@"/tmp/test.html" = .{
        \\            .content =
        \\            \\<html>
        \\            \\    <h1>Hello, world</h1>
        \\            \\</html>
        \\            ,
        \\            .mode = 0o644,
        \\        },
        \\    },
        \\}
    ;
    var manifest = try parse(testing.allocator, content);
    defer manifest.deinit();

    const file = manifest.files[0];
    try testing.expectEqualStrings("/tmp/test.html", file.path);
    // ZON semantics: indentation after \\ is content
    try testing.expectEqualStrings("<html>\n    <h1>Hello, world</h1>\n</html>", file.content.?);
    try testing.expectEqual(@as(?u32, 0o644), file.mode);
}

test "parse file content decodes escapes" {
    var manifest = try parse(testing.allocator,
        \\.{ .files = .{ .@"/tmp/x" = .{ .content = "a\n\t\"b\"\x41" } } }
    );
    defer manifest.deinit();
    try testing.expectEqualStrings("a\n\t\"b\"A", manifest.files[0].content.?);
}

test "parse file with every attribute" {
    const content =
        \\.{
        \\    .files = .{
        \\        .@"/etc/app.conf" = .{
        \\            .source = "/srv/app.conf",
        \\            .mode = 0o600,
        \\            .owner = "root",
        \\            .group = "0",
        \\            .allow_failure = true,
        \\        },
        \\        .@"/etc/old.conf" = .{ .state = .absent },
        \\    },
        \\}
    ;
    var manifest = try parse(testing.allocator, content);
    defer manifest.deinit();

    const files = manifest.files;
    try testing.expectEqual(2, files.len);
    try testing.expectEqualStrings("/srv/app.conf", files[0].source.?);
    try testing.expect(files[0].content == null);
    try testing.expectEqual(@as(?u32, 0o600), files[0].mode);
    try testing.expectEqualStrings("root", files[0].owner.?);
    try testing.expectEqualStrings("0", files[0].group.?);
    try testing.expect(files[0].base.allow_failure);
    try testing.expectEqual(FileResource.FileState.absent, files[1].state);
}

test "parse packages" {
    const content =
        \\.{
        \\    .packages = .{
        \\        .nginx = .{},
        \\        .@"build-essential" = .{ .version = "12.10" },
        \\        .apache2 = .{ .state = .absent },
        \\    },
        \\}
    ;
    var manifest = try parse(testing.allocator, content);
    defer manifest.deinit();

    const pkgs = manifest.packages;
    try testing.expectEqual(3, pkgs.len);
    try testing.expectEqualStrings("nginx", pkgs[0].name);
    try testing.expectEqual(PackageResource.PackageState.installed, pkgs[0].state);
    try testing.expectEqualStrings("build-essential", pkgs[1].name);
    try testing.expectEqualStrings("12.10", pkgs[1].version.?);
    try testing.expectEqual(PackageResource.PackageState.absent, pkgs[2].state);
}

test "parse services" {
    const content =
        \\.{
        \\    .services = .{
        \\        .nginx = .{},
        \\        .@"systemd-timesyncd" = .{ .state = .stopped, .enabled = false },
        \\    },
        \\}
    ;
    var manifest = try parse(testing.allocator, content);
    defer manifest.deinit();

    const svcs = manifest.services;
    try testing.expectEqualStrings("nginx", svcs[0].name);
    try testing.expectEqual(ServiceResource.ServiceState.running, svcs[0].state);
    try testing.expect(svcs[0].enabled);
    try testing.expectEqualStrings("systemd-timesyncd", svcs[1].name);
    try testing.expectEqual(ServiceResource.ServiceState.stopped, svcs[1].state);
    try testing.expect(!svcs[1].enabled);
}

test "parse package_cache and its apt_update alias" {
    for ([_][]const u8{ ".{ .package_cache = .{} }", ".{ .apt_update = .{} }" }) |content| {
        var manifest = try parse(testing.allocator, content);
        defer manifest.deinit();
        try testing.expect(manifest.package_cache != null);
        try testing.expectEqualStrings("update", manifest.package_cache.?.name);
    }

    var manifest = try parse(testing.allocator, ".{ .package_cache = .{ .allow_failure = true } }");
    defer manifest.deinit();
    try testing.expect(manifest.package_cache.?.base.allow_failure);
}

test "reject package_cache given twice" {
    try expectInvalidWith(".{ .package_cache = .{}, .apt_update = .{} }", "given twice");
}

test "reject unknown section" {
    try expectInvalidWith(
        \\.{
        \\    .files = .{},
        \\    .user = .{ .deployer = .{} },
        \\}
    , "m.zon:3:6: error: unknown section '.user'");
    try expectInvalidWith(".{ .servics = .{} }", "unknown section '.servics'");
}

test "reject unknown attribute" {
    try expectInvalidWith(
        \\.{ .directories = .{ .@"/tmp/x" = .{ .mdoe = 0o755 } } }
    , "mdoe");
}

test "reject wrong attribute type" {
    try expectInvalidWith(".{ .files = .{ .@\"/tmp/x\" = .{ .mode = \"0644\" } } }", "m.zon:1:");
    try expectInvalidWith(".{ .services = .{ .nginx = .{ .state = .started } } }", "m.zon:1:");
}

test "reject relative paths" {
    try expectInvalidWith(".{ .files = .{ .@\"etc/x\" = .{} } }", "'etc/x' is not an absolute path");
}

test "reject syntax errors" {
    try expectInvalidWith(".{ .files = .{ .@\"/tmp/x\" = .{ .mode = 0o644 } }", "m.zon:");
    try expectInvalidWith(".{ .files = .{}, .files = .{} }", "m.zon:");
}

test "reject a root that is not a struct" {
    try expectInvalidWith("\"hello\"", "a manifest is a struct literal");
    try expectInvalidWith(".{ .packages = \"nginx\" }", "expected .{");
}

test "plain parse frees the message" {
    try testing.expectError(error.InvalidManifest, parse(testing.allocator, ".{ .usrs = .{} }"));
}

test "parse groups and users" {
    const content =
        \\.{
        \\    .groups = .{
        \\        .app = .{ .gid = 4200 },
        \\        .old = .{ .state = .absent },
        \\    },
        \\    .users = .{
        \\        .deploy = .{
        \\            .uid = 4300,
        \\            .group = "app",
        \\            .groups = .{ "web", "docker" },
        \\            .membership = .exact,
        \\            .shell = "/bin/sh",
        \\            .home = "/srv/deploy",
        \\        },
        \\        .bare = .{},
        \\        .gone = .{ .state = .absent, .remove_home = true },
        \\    },
        \\}
    ;
    var manifest = try parse(testing.allocator, content);
    defer manifest.deinit();

    const groups = manifest.groups;
    try testing.expectEqual(2, groups.len);
    try testing.expectEqualStrings("app", groups[0].name);
    try testing.expectEqual(@as(?u32, 4200), groups[0].gid);
    try testing.expectEqual(GroupResource.GroupState.absent, groups[1].state);

    const users = manifest.users;
    try testing.expectEqual(3, users.len);
    const deploy = users[0];
    try testing.expectEqualStrings("deploy", deploy.name);
    try testing.expectEqual(@as(?u32, 4300), deploy.uid);
    try testing.expectEqualStrings("app", deploy.group.?);
    try testing.expectEqual(2, deploy.groups.len);
    try testing.expectEqualStrings("docker", deploy.groups[1]);
    try testing.expectEqual(UserResource.Membership.exact, deploy.membership);
    try testing.expectEqualStrings("/bin/sh", deploy.shell.?);
    try testing.expectEqualStrings("/srv/deploy", deploy.home.?);

    const bare = users[1];
    try testing.expect(bare.uid == null and bare.group == null and bare.shell == null and bare.home == null);
    try testing.expectEqual(0, bare.groups.len);
    try testing.expectEqual(UserResource.Membership.append, bare.membership);
    try testing.expect(users[2].remove_home);
}

test "reject unknown user attribute and bad names" {
    try expectInvalidWith(".{ .users = .{ .deploy = .{ .password = \"x\" } } }", "password");
    try expectInvalidWith(".{ .groups = .{ .@\"-r\" = .{} } }", "'-r' is not a valid name");
    try expectInvalidWith(".{ .users = .{ .deploy = .{ .groups = .{\"-f\"} } } }", "'-f' is not a valid group name");
    try expectInvalidWith(".{ .packages = .{ .@\"--force\" = .{} } }", "not a valid name");
}
