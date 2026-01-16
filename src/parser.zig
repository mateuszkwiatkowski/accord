const std = @import("std");
const DirectoryResource = @import("resources/directory.zig").DirectoryResource;
const output = @import("output.zig");

/// Manifest structure containing all resources
pub const Manifest = struct {
    directories: ?std.StringHashMap(DirectoryResource) = null,
    // Future: files, packages, services, users, groups

    allocator: std.mem.Allocator,

    /// Initialize empty manifest
    pub fn init(allocator: std.mem.Allocator) Manifest {
        return .{
            .allocator = allocator,
        };
    }

    /// Free all resources
    pub fn deinit(self: *Manifest) void {
        if (self.directories) |*dirs| {
            dirs.deinit();
        }
    }
};

/// Simple ZON parser for MVP
/// For now, we use a simplified string-based parser
/// This can be replaced with proper AST parsing later
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Manifest {
    output.logDebug("Parsing manifest...");

    var manifest = Manifest.init(allocator);

    // Look for .directories section
    if (std.mem.indexOf(u8, content, ".directories")) |start| {
        // Find the opening brace after .directories
        if (std.mem.indexOfPos(u8, content, start, ".{")) |open_pos| {
            // Find matching closing brace
            var brace_count: i32 = 1;
            var pos = open_pos + 2;
            var close_pos: usize = pos;

            while (pos < content.len and brace_count > 0) : (pos += 1) {
                if (content[pos] == '{') {
                    brace_count += 1;
                } else if (content[pos] == '}') {
                    brace_count -= 1;
                    if (brace_count == 0) {
                        close_pos = pos;
                        break;
                    }
                }
            }

            // Extract directories section content
            const dirs_content = content[open_pos + 2 .. close_pos];
            manifest.directories = try parseDirectoriesSimple(allocator, dirs_content);
        }
    }

    return manifest;
}

/// Simple parser for directories section
fn parseDirectoriesSimple(
    allocator: std.mem.Allocator,
    content: []const u8,
) !std.StringHashMap(DirectoryResource) {
    var directories = std.StringHashMap(DirectoryResource).init(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_path: ?[]const u8 = null;
    var current_resource: ?DirectoryResource = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
            continue;
        }

        // Check if this is a new directory entry (starts with .@")
        if (std.mem.indexOf(u8, trimmed, ".@\"")) |_| {
            // Save previous entry if exists
            if (current_path) |path| {
                if (current_resource) |res| {
                    try directories.put(path, res);
                }
            }

            // Extract path
            const start = std.mem.indexOf(u8, trimmed, "\"").? + 1;
            const end = std.mem.indexOfPos(u8, trimmed, start, "\"").?;
            const path = trimmed[start..end];

            current_path = path;
            current_resource = DirectoryResource{ .path = path };

            // Check for inline attributes on the same line
            if (std.mem.indexOf(u8, trimmed, ".{")) |brace_pos| {
                const inline_attrs = trimmed[brace_pos..];
                current_resource = try parseInlineAttributes(current_resource.?, inline_attrs);
            }
        } else if (current_resource != null) {
            // Parse attributes
            if (std.mem.indexOf(u8, trimmed, ".mode")) |_| {
                if (std.mem.indexOf(u8, trimmed, "0o")) |mode_start| {
                    const mode_end = mode_start + 5; // 0o### format
                    if (mode_end <= trimmed.len) {
                        const mode_str = trimmed[mode_start + 2 .. mode_end];
                        const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o755;
                        current_resource.?.mode = mode;
                    }
                }
            } else if (std.mem.indexOf(u8, trimmed, ".state")) |_| {
                if (std.mem.indexOf(u8, trimmed, ".absent")) |_| {
                    current_resource.?.state = .absent;
                } else {
                    current_resource.?.state = .present;
                }
            } else if (std.mem.indexOf(u8, trimmed, ".owner")) |_| {
                if (std.mem.indexOf(u8, trimmed, "\"")) |quote_start| {
                    const start = quote_start + 1;
                    if (std.mem.indexOfPos(u8, trimmed, start, "\"")) |quote_end| {
                        current_resource.?.owner = trimmed[start..quote_end];
                    }
                }
            } else if (std.mem.indexOf(u8, trimmed, ".group")) |_| {
                if (std.mem.indexOf(u8, trimmed, "\"")) |quote_start| {
                    const start = quote_start + 1;
                    if (std.mem.indexOfPos(u8, trimmed, start, "\"")) |quote_end| {
                        current_resource.?.group = trimmed[start..quote_end];
                    }
                }
            } else if (std.mem.indexOf(u8, trimmed, ".allow_failure")) |_| {
                if (std.mem.indexOf(u8, trimmed, "true")) |_| {
                    current_resource.?.base.allow_failure = true;
                }
            }
        }
    }

    // Save last entry
    if (current_path) |path| {
        if (current_resource) |res| {
            try directories.put(path, res);
        }
    }

    return directories;
}

/// Parse inline attributes (attributes on the same line as the directory)
fn parseInlineAttributes(resource: DirectoryResource, attrs_line: []const u8) !DirectoryResource {
    var res = resource;

    if (std.mem.indexOf(u8, attrs_line, ".mode")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "0o")) |mode_start| {
            const mode_end = mode_start + 5; // 0o### format
            if (mode_end <= attrs_line.len) {
                const mode_str = attrs_line[mode_start + 2 .. mode_end];
                const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o755;
                res.mode = mode;
            }
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".state")) |_| {
        if (std.mem.indexOf(u8, attrs_line, ".absent")) |_| {
            res.state = .absent;
        } else {
            res.state = .present;
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".owner")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "\"")) |quote_start| {
            const start = quote_start + 1;
            if (std.mem.indexOfPos(u8, attrs_line, start, "\"")) |quote_end| {
                res.owner = attrs_line[start..quote_end];
            }
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".group")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "\"")) |quote_start| {
            const start = quote_start + 1;
            if (std.mem.indexOfPos(u8, attrs_line, start, "\"")) |quote_end| {
                res.group = attrs_line[start..quote_end];
            }
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".allow_failure")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "true")) |_| {
            res.base.allow_failure = true;
        }
    }

    return res;
}

// Tests
test "parse empty manifest" {
    const content =
        \\.{}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.directories == null);
}

test "parse manifest with single directory" {
    const content =
        \\.{
        \\    .directories = .{
        \\        .@"/tmp/test" = .{},
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.directories != null);

    if (manifest.directories) |dirs| {
        try std.testing.expect(dirs.count() == 1);

        const dir = dirs.get("/tmp/test");
        try std.testing.expect(dir != null);
        if (dir) |d| {
            try std.testing.expect(std.mem.eql(u8, d.path, "/tmp/test"));
            try std.testing.expect(d.state == .present);
        }
    }
}

test "parse manifest with directory attributes" {
    const content =
        \\.{
        \\    .directories = .{
        \\        .@"/opt/app" = .{
        \\            .mode = 0o755,
        \\            .state = .present,
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.directories != null);

    if (manifest.directories) |dirs| {
        const dir = dirs.get("/opt/app");
        try std.testing.expect(dir != null);
        if (dir) |d| {
            try std.testing.expect(d.mode != null);
            if (d.mode) |mode| {
                try std.testing.expect(mode == 0o755);
            }
            try std.testing.expect(d.state == .present);
        }
    }
}

test "parse manifest with multiple directories" {
    const content =
        \\.{
        \\    .directories = .{
        \\        .@"/tmp/dir1" = .{},
        \\        .@"/tmp/dir2" = .{ .mode = 0o700 },
        \\        .@"/tmp/dir3" = .{ .state = .absent },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.directories != null);

    if (manifest.directories) |dirs| {
        try std.testing.expect(dirs.count() == 3);
        try std.testing.expect(dirs.get("/tmp/dir1") != null);
        try std.testing.expect(dirs.get("/tmp/dir2") != null);
        try std.testing.expect(dirs.get("/tmp/dir3") != null);

        // Check mode was parsed
        if (dirs.get("/tmp/dir2")) |d2| {
            try std.testing.expect(d2.mode != null);
            if (d2.mode) |mode| {
                try std.testing.expect(mode == 0o700);
            }
        }

        // Check state was parsed
        if (dirs.get("/tmp/dir3")) |d3| {
            try std.testing.expect(d3.state == .absent);
        }
    }
}
