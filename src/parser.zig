const std = @import("std");
const DirectoryResource = @import("resources/directory.zig").DirectoryResource;
const FileResource = @import("resources/file.zig").FileResource;
const PackageResource = @import("resources/package.zig").PackageResource;
const ServiceResource = @import("resources/service.zig").ServiceResource;
const AptUpdateResource = @import("resources/apt_update.zig").AptUpdateResource;
const output = @import("output.zig");

/// Manifest structure containing all resources
pub const Manifest = struct {
    apt_update: ?AptUpdateResource = null, // Singular, nameless pattern
    directories: ?std.StringHashMap(DirectoryResource) = null,
    files: ?std.StringHashMap(FileResource) = null,
    packages: ?std.StringHashMap(PackageResource) = null,
    services: ?std.StringHashMap(ServiceResource) = null,
    // Future: users, groups

    allocator: std.mem.Allocator,

    // Track allocated strings for multi-line content (to be freed on deinit)
    allocated_strings: [][]const u8 = &[_][]const u8{},

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
        if (self.files) |*files| {
            files.deinit();
        }
        if (self.packages) |*pkgs| {
            pkgs.deinit();
        }
        if (self.services) |*svcs| {
            svcs.deinit();
        }
        // Free allocated strings
        for (self.allocated_strings) |str| {
            self.allocator.free(str);
        }
        if (self.allocated_strings.len > 0) {
            self.allocator.free(self.allocated_strings);
        }
    }
};

/// Simple ZON parser for MVP
/// For now, we use a simplified string-based parser
/// This can be replaced with proper AST parsing later
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Manifest {
    output.logDebug("Parsing manifest...");

    var manifest = Manifest.init(allocator);

    // Look for .apt_update (nameless pattern - single resource)
    if (std.mem.indexOf(u8, content, ".apt_update")) |_| {
        // For nameless pattern: just create a default resource
        manifest.apt_update = AptUpdateResource{};
    }

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

    // Look for .files section
    if (std.mem.indexOf(u8, content, ".files")) |start| {
        // Find the opening brace after .files
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

            // Extract files section content
            const files_content = content[open_pos + 2 .. close_pos];
            const parse_result = try parseFilesSimple(allocator, files_content);
            manifest.files = parse_result.files;
            // Merge with any existing allocated strings
            if (manifest.allocated_strings.len > 0 or parse_result.allocated_strings.len > 0) {
                const combined = try allocator.alloc([]const u8, manifest.allocated_strings.len + parse_result.allocated_strings.len);
                @memcpy(combined[0..manifest.allocated_strings.len], manifest.allocated_strings);
                @memcpy(combined[manifest.allocated_strings.len..], parse_result.allocated_strings);
                if (manifest.allocated_strings.len > 0) allocator.free(manifest.allocated_strings);
                if (parse_result.allocated_strings.len > 0) allocator.free(parse_result.allocated_strings);
                manifest.allocated_strings = combined;
            }
        }
    }

    // Look for .packages section
    if (std.mem.indexOf(u8, content, ".packages")) |start| {
        // Find the opening brace after .packages
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

            // Extract packages section content
            const pkgs_content = content[open_pos + 2 .. close_pos];
            manifest.packages = try parsePackagesSimple(allocator, pkgs_content);
        }
    }

    // Look for .services section
    if (std.mem.indexOf(u8, content, ".services")) |start| {
        // Find the opening brace after .services
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

            // Extract services section content
            const svcs_content = content[open_pos + 2 .. close_pos];
            manifest.services = try parseServicesSimple(allocator, svcs_content);
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

/// Simple parser for packages section
fn parsePackagesSimple(
    allocator: std.mem.Allocator,
    content: []const u8,
) !std.StringHashMap(PackageResource) {
    var packages = std.StringHashMap(PackageResource).init(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_name: ?[]const u8 = null;
    var current_resource: ?PackageResource = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
            continue;
        }

        // Check if this is a new package entry (starts with . and has = .{)
        // Package entries: .nginx = .{}, or .@"package-name" = .{}
        const is_package_entry = std.mem.startsWith(u8, trimmed, ".") and
            std.mem.indexOf(u8, trimmed, "= .{") != null;

        if (std.mem.startsWith(u8, trimmed, ".@\"")) {
            // Save previous entry if exists
            if (current_name) |name| {
                if (current_resource) |res| {
                    try packages.put(name, res);
                }
            }

            // Extract name with @"" syntax
            const start = std.mem.indexOf(u8, trimmed, "\"").? + 1;
            const end = std.mem.indexOfPos(u8, trimmed, start, "\"").?;
            const name = trimmed[start..end];

            current_name = name;
            current_resource = PackageResource{ .name = name };

            // Check for inline attributes on the same line
            if (std.mem.indexOf(u8, trimmed, ".{")) |brace_pos| {
                const inline_attrs = trimmed[brace_pos..];
                current_resource = try parsePackageInlineAttributes(current_resource.?, inline_attrs);
            }
        } else if (is_package_entry) {
            // Regular identifier (no quotes needed)
            // Save previous entry if exists
            if (current_name) |name| {
                if (current_resource) |res| {
                    try packages.put(name, res);
                }
            }

            // Extract name until = or whitespace
            var name_end: usize = 1; // Skip the leading .
            while (name_end < trimmed.len) : (name_end += 1) {
                const c = trimmed[name_end];
                if (c == ' ' or c == '=' or c == '\t') break;
            }
            const name = trimmed[1..name_end];

            current_name = name;
            current_resource = PackageResource{ .name = name };

            // Check for inline attributes on the same line
            if (std.mem.indexOf(u8, trimmed, ".{")) |brace_pos| {
                const inline_attrs = trimmed[brace_pos..];
                current_resource = try parsePackageInlineAttributes(current_resource.?, inline_attrs);
            }
        } else if (current_resource != null) {
            // Parse attributes
            if (std.mem.indexOf(u8, trimmed, ".state")) |_| {
                if (std.mem.indexOf(u8, trimmed, ".absent")) |_| {
                    current_resource.?.state = .absent;
                } else if (std.mem.indexOf(u8, trimmed, ".installed")) |_| {
                    current_resource.?.state = .installed;
                }
            } else if (std.mem.indexOf(u8, trimmed, ".version")) |_| {
                if (std.mem.indexOf(u8, trimmed, "\"")) |quote_start| {
                    const start = quote_start + 1;
                    if (std.mem.indexOfPos(u8, trimmed, start, "\"")) |quote_end| {
                        current_resource.?.version = trimmed[start..quote_end];
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
    if (current_name) |name| {
        if (current_resource) |res| {
            try packages.put(name, res);
        }
    }

    return packages;
}

/// Parse inline attributes for packages
fn parsePackageInlineAttributes(resource: PackageResource, attrs_line: []const u8) !PackageResource {
    var res = resource;

    if (std.mem.indexOf(u8, attrs_line, ".state")) |_| {
        if (std.mem.indexOf(u8, attrs_line, ".absent")) |_| {
            res.state = .absent;
        } else if (std.mem.indexOf(u8, attrs_line, ".installed")) |_| {
            res.state = .installed;
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".version")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "\"")) |quote_start| {
            const start = quote_start + 1;
            if (std.mem.indexOfPos(u8, attrs_line, start, "\"")) |quote_end| {
                res.version = attrs_line[start..quote_end];
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

/// Simple parser for services section
fn parseServicesSimple(
    allocator: std.mem.Allocator,
    content: []const u8,
) !std.StringHashMap(ServiceResource) {
    var services = std.StringHashMap(ServiceResource).init(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_name: ?[]const u8 = null;
    var current_resource: ?ServiceResource = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
            continue;
        }

        // Check if this is a new service entry (starts with . and has = .{)
        const is_service_entry = std.mem.startsWith(u8, trimmed, ".") and
            std.mem.indexOf(u8, trimmed, "= .{") != null;

        if (std.mem.startsWith(u8, trimmed, ".@\"")) {
            // Save previous entry if exists
            if (current_name) |name| {
                if (current_resource) |res| {
                    try services.put(name, res);
                }
            }

            // Extract name with @"" syntax
            const start = std.mem.indexOf(u8, trimmed, "\"").? + 1;
            const end = std.mem.indexOfPos(u8, trimmed, start, "\"").?;
            const name = trimmed[start..end];

            current_name = name;
            current_resource = ServiceResource{ .name = name };

            // Check for inline attributes on the same line
            if (std.mem.indexOf(u8, trimmed, ".{")) |brace_pos| {
                const inline_attrs = trimmed[brace_pos..];
                current_resource = try parseServiceInlineAttributes(current_resource.?, inline_attrs);
            }
        } else if (is_service_entry) {
            // Regular identifier (no quotes needed)
            // Save previous entry if exists
            if (current_name) |name| {
                if (current_resource) |res| {
                    try services.put(name, res);
                }
            }

            // Extract name until = or whitespace
            var name_end: usize = 1; // Skip the leading .
            while (name_end < trimmed.len) : (name_end += 1) {
                const c = trimmed[name_end];
                if (c == ' ' or c == '=' or c == '\t') break;
            }
            const name = trimmed[1..name_end];

            current_name = name;
            current_resource = ServiceResource{ .name = name };

            // Check for inline attributes on the same line
            if (std.mem.indexOf(u8, trimmed, ".{")) |brace_pos| {
                const inline_attrs = trimmed[brace_pos..];
                current_resource = try parseServiceInlineAttributes(current_resource.?, inline_attrs);
            }
        } else if (current_resource != null) {
            // Parse attributes
            if (std.mem.indexOf(u8, trimmed, ".state")) |_| {
                if (std.mem.indexOf(u8, trimmed, ".stopped")) |_| {
                    current_resource.?.state = .stopped;
                } else if (std.mem.indexOf(u8, trimmed, ".running")) |_| {
                    current_resource.?.state = .running;
                }
            } else if (std.mem.indexOf(u8, trimmed, ".enabled")) |_| {
                if (std.mem.indexOf(u8, trimmed, "false")) |_| {
                    current_resource.?.enabled = false;
                } else if (std.mem.indexOf(u8, trimmed, "true")) |_| {
                    current_resource.?.enabled = true;
                }
            } else if (std.mem.indexOf(u8, trimmed, ".allow_failure")) |_| {
                if (std.mem.indexOf(u8, trimmed, "true")) |_| {
                    current_resource.?.base.allow_failure = true;
                }
            }
        }
    }

    // Save last entry
    if (current_name) |name| {
        if (current_resource) |res| {
            try services.put(name, res);
        }
    }

    return services;
}

/// Parse inline attributes for services
fn parseServiceInlineAttributes(resource: ServiceResource, attrs_line: []const u8) !ServiceResource {
    var res = resource;

    if (std.mem.indexOf(u8, attrs_line, ".state")) |_| {
        if (std.mem.indexOf(u8, attrs_line, ".stopped")) |_| {
            res.state = .stopped;
        } else if (std.mem.indexOf(u8, attrs_line, ".running")) |_| {
            res.state = .running;
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".enabled")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "false")) |_| {
            res.enabled = false;
        } else if (std.mem.indexOf(u8, attrs_line, "true")) |_| {
            res.enabled = true;
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".allow_failure")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "true")) |_| {
            res.base.allow_failure = true;
        }
    }

    return res;
}

/// Parse result for files section
const FilesParseResult = struct {
    files: std.StringHashMap(FileResource),
    allocated_strings: [][]const u8,
};

/// Simple parser for files section
fn parseFilesSimple(
    allocator: std.mem.Allocator,
    content: []const u8,
) !FilesParseResult {
    var files = std.StringHashMap(FileResource).init(allocator);

    // Track allocated strings
    var allocated_strings_buffer: [128][]const u8 = undefined;
    var allocated_strings_count: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_path: ?[]const u8 = null;
    var current_resource: ?FileResource = null;
    var in_multiline_content = false;

    // Use a fixed-size buffer for collecting multi-line content
    var content_buffer: [512][]const u8 = undefined;
    var content_line_count: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
            continue;
        }

        // Handle multi-line content collection
        if (in_multiline_content) {
            // Check if this line is the terminating comma
            // (not a content line starting with \\)
            if (!std.mem.startsWith(u8, trimmed, "\\\\") and std.mem.indexOf(u8, trimmed, ",") != null) {
                // End of multi-line content
                in_multiline_content = false;

                // Join collected lines and track allocation
                const joined_content = try joinLines(allocator, content_buffer[0..content_line_count]);
                if (allocated_strings_count < allocated_strings_buffer.len) {
                    allocated_strings_buffer[allocated_strings_count] = joined_content;
                    allocated_strings_count += 1;
                }
                current_resource.?.content = joined_content;
                content_line_count = 0;
                continue;
            }

            // Collect multi-line content (strip \\ prefix and leading whitespace)
            if (std.mem.startsWith(u8, trimmed, "\\\\")) {
                const line_content = std.mem.trimLeft(u8, trimmed[2..], " \t");
                if (content_line_count < content_buffer.len) {
                    content_buffer[content_line_count] = line_content;
                    content_line_count += 1;
                }
            }
            continue;
        }

        // Check if this is a new file entry (starts with .@")
        if (std.mem.indexOf(u8, trimmed, ".@\"")) |_| {
            // Save previous entry if exists
            if (current_path) |path| {
                if (current_resource) |res| {
                    try files.put(path, res);
                }
            }

            // Extract path
            const start = std.mem.indexOf(u8, trimmed, "\"").? + 1;
            const end = std.mem.indexOfPos(u8, trimmed, start, "\"").?;
            const path = trimmed[start..end];

            current_path = path;
            current_resource = FileResource{ .path = path };

            // Check for inline attributes on the same line
            if (std.mem.indexOf(u8, trimmed, ".{")) |brace_pos| {
                const inline_attrs = trimmed[brace_pos..];
                current_resource = try parseFileInlineAttributes(current_resource.?, inline_attrs);
            }
        } else if (current_resource != null) {
            // Parse attributes
            if (std.mem.indexOf(u8, trimmed, ".content")) |_| {
                // Check for inline quoted content
                if (std.mem.indexOf(u8, trimmed, "\"")) |quote_start| {
                    const start = quote_start + 1;
                    if (std.mem.indexOfPos(u8, trimmed, start, "\"")) |quote_end| {
                        current_resource.?.content = trimmed[start..quote_end];
                    }
                } else {
                    // Check if next line starts multi-line content
                    // We'll detect \\ on the next iteration
                    in_multiline_content = true;
                    content_line_count = 0;
                }
            } else if (std.mem.indexOf(u8, trimmed, ".source")) |_| {
                if (std.mem.indexOf(u8, trimmed, "\"")) |quote_start| {
                    const start = quote_start + 1;
                    if (std.mem.indexOfPos(u8, trimmed, start, "\"")) |quote_end| {
                        current_resource.?.source = trimmed[start..quote_end];
                    }
                }
            } else if (std.mem.indexOf(u8, trimmed, ".mode")) |_| {
                if (std.mem.indexOf(u8, trimmed, "0o")) |mode_start| {
                    const mode_end = mode_start + 5; // 0o### format
                    if (mode_end <= trimmed.len) {
                        const mode_str = trimmed[mode_start + 2 .. mode_end];
                        const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o644;
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
            try files.put(path, res);
        }
    }

    // Copy allocated strings to a properly-sized slice
    var allocated_strings_slice: [][]const u8 = undefined;
    if (allocated_strings_count > 0) {
        allocated_strings_slice = try allocator.alloc([]const u8, allocated_strings_count);
        @memcpy(allocated_strings_slice, allocated_strings_buffer[0..allocated_strings_count]);
    } else {
        allocated_strings_slice = &[_][]const u8{};
    }

    return FilesParseResult{
        .files = files,
        .allocated_strings = allocated_strings_slice,
    };
}

/// Parse inline attributes for files (attributes on the same line as the file)
fn parseFileInlineAttributes(resource: FileResource, attrs_line: []const u8) !FileResource {
    var res = resource;

    if (std.mem.indexOf(u8, attrs_line, ".content")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "\"")) |quote_start| {
            const start = quote_start + 1;
            if (std.mem.indexOfPos(u8, attrs_line, start, "\"")) |quote_end| {
                res.content = attrs_line[start..quote_end];
            }
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".source")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "\"")) |quote_start| {
            const start = quote_start + 1;
            if (std.mem.indexOfPos(u8, attrs_line, start, "\"")) |quote_end| {
                res.source = attrs_line[start..quote_end];
            }
        }
    }

    if (std.mem.indexOf(u8, attrs_line, ".mode")) |_| {
        if (std.mem.indexOf(u8, attrs_line, "0o")) |mode_start| {
            const mode_end = mode_start + 5; // 0o### format
            if (mode_end <= attrs_line.len) {
                const mode_str = attrs_line[mode_start + 2 .. mode_end];
                const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o644;
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

/// Join multiple lines with Unix newlines
fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";
    if (lines.len == 1) return lines[0];

    // Calculate total size needed (lines + newlines between them)
    var total_size: usize = 0;
    for (lines) |line| {
        total_size += line.len;
    }
    total_size += lines.len - 1; // Add newlines between lines

    // Allocate and build result
    var result = try allocator.alloc(u8, total_size);
    var pos: usize = 0;

    for (lines, 0..) |line, i| {
        @memcpy(result[pos .. pos + line.len], line);
        pos += line.len;
        if (i < lines.len - 1) {
            result[pos] = '\n';
            pos += 1;
        }
    }

    return result;
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

test "parse file with multi-line content" {
    const content =
        \\.{
        \\    .files = .{
        \\        .@"/tmp/test.html" = .{
        \\            .content =
        \\                \\<!DOCTYPE html>
        \\                \\<html>
        \\                \\<body>
        \\                \\    <h1>Hello</h1>
        \\                \\</body>
        \\                \\</html>
        \\            ,
        \\            .mode = 0o644,
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.files != null);

    if (manifest.files) |files| {
        const file = files.get("/tmp/test.html");
        try std.testing.expect(file != null);
        if (file) |f| {
            try std.testing.expect(f.content != null);
            if (f.content) |c| {
                const expected = "<!DOCTYPE html>\n<html>\n<body>\n<h1>Hello</h1>\n</body>\n</html>";
                try std.testing.expect(std.mem.eql(u8, c, expected));
            }
            try std.testing.expect(f.mode != null);
            if (f.mode) |mode| {
                try std.testing.expect(mode == 0o644);
            }
        }
    }
}

test "parse file multi-line strips leading whitespace" {
    const content =
        \\.{
        \\    .files = .{
        \\        .@"/tmp/test.txt" = .{
        \\            .content =
        \\                \\Line 1
        \\                \\    Line 2 indented
        \\                \\Line 3
        \\            ,
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    if (manifest.files) |files| {
        if (files.get("/tmp/test.txt")) |f| {
            if (f.content) |c| {
                const expected = "Line 1\nLine 2 indented\nLine 3";
                try std.testing.expect(std.mem.eql(u8, c, expected));
            }
        }
    }
}

test "parse file multi-line with empty lines" {
    const content =
        \\.{
        \\    .files = .{
        \\        .@"/tmp/test.txt" = .{
        \\            .content =
        \\                \\First line
        \\                \\
        \\                \\Third line
        \\            ,
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    if (manifest.files) |files| {
        if (files.get("/tmp/test.txt")) |f| {
            if (f.content) |c| {
                const expected = "First line\n\nThird line";
                try std.testing.expect(std.mem.eql(u8, c, expected));
            }
        }
    }
}

test "parse file with inline quoted content still works" {
    const content =
        \\.{
        \\    .files = .{
        \\        .@"/tmp/test.txt" = .{
        \\            .content = "inline content",
        \\            .mode = 0o644,
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.files != null);

    if (manifest.files) |files| {
        const file = files.get("/tmp/test.txt");
        try std.testing.expect(file != null);
        if (file) |f| {
            try std.testing.expect(f.content != null);
            if (f.content) |c| {
                try std.testing.expect(std.mem.eql(u8, c, "inline content"));
            }
        }
    }
}

test "parse file multi-line with other attributes" {
    const content =
        \\.{
        \\    .files = .{
        \\        .@"/tmp/test.conf" = .{
        \\            .content =
        \\                \\server=localhost
        \\                \\port=8080
        \\            ,
        \\            .mode = 0o600,
        \\            .owner = "root",
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    if (manifest.files) |files| {
        if (files.get("/tmp/test.conf")) |f| {
            try std.testing.expect(f.content != null);
            if (f.content) |c| {
                try std.testing.expect(std.mem.eql(u8, c, "server=localhost\nport=8080"));
            }
            try std.testing.expect(f.mode != null);
            if (f.mode) |mode| {
                try std.testing.expect(mode == 0o600);
            }
            try std.testing.expect(f.owner != null);
            if (f.owner) |owner| {
                try std.testing.expect(std.mem.eql(u8, owner, "root"));
            }
        }
    }
}

test "parse file multi-line with commas in content" {
    const content =
        \\.{
        \\    .files = .{
        \\        .@"/tmp/test-comma.html" = .{
        \\            .content =
        \\                \\<!DOCTYPE html>
        \\                \\<html lang="en">
        \\                \\<head>
        \\                \\<meta charset="UTF-8">
        \\                \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\                \\<title>Test, with, commas</title>
        \\                \\<style>
        \\                \\body { font-family: sans-serif; }
        \\                \\</style>
        \\                \\</head>
        \\                \\<body>
        \\                \\<h1>Hello, world!</h1>
        \\                \\<p>One, two, three</p>
        \\                \\</body>
        \\                \\</html>
        \\            ,
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    if (manifest.files) |files| {
        if (files.get("/tmp/test-comma.html")) |f| {
            try std.testing.expect(f.content != null);
            if (f.content) |c| {
                // Should have all 15 lines of content
                var line_count: usize = 1;
                for (c) |char| {
                    if (char == '\n') line_count += 1;
                }
                try std.testing.expectEqual(@as(usize, 15), line_count);

                // Verify specific content with commas is present
                try std.testing.expect(std.mem.indexOf(u8, c, "width=device-width, initial-scale=1.0") != null);
                try std.testing.expect(std.mem.indexOf(u8, c, "Test, with, commas") != null);
                try std.testing.expect(std.mem.indexOf(u8, c, "Hello, world!") != null);
                try std.testing.expect(std.mem.indexOf(u8, c, "One, two, three") != null);
                try std.testing.expect(std.mem.indexOf(u8, c, "</html>") != null);
            }
        }
    }
}

test "parse manifest with single package" {
    const content =
        \\.{
        \\    .packages = .{
        \\        .nginx = .{},
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.packages != null);

    if (manifest.packages) |pkgs| {
        try std.testing.expect(pkgs.count() == 1);

        const pkg = pkgs.get("nginx");
        try std.testing.expect(pkg != null);
        if (pkg) |p| {
            try std.testing.expect(std.mem.eql(u8, p.name, "nginx"));
            try std.testing.expect(p.state == .installed); // Default
            try std.testing.expect(p.version == null);
        }
    }
}

test "parse manifest with multiple packages" {
    const content =
        \\.{
        \\    .packages = .{
        \\        .nginx = .{},
        \\        .postgresql = .{ .state = .installed },
        \\        .apache2 = .{ .state = .absent },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.packages != null);

    if (manifest.packages) |pkgs| {
        try std.testing.expect(pkgs.count() == 3);

        if (pkgs.get("nginx")) |p| {
            try std.testing.expect(p.state == .installed);
        }

        if (pkgs.get("postgresql")) |p| {
            try std.testing.expect(p.state == .installed);
        }

        if (pkgs.get("apache2")) |p| {
            try std.testing.expect(p.state == .absent);
        }
    }
}

test "parse package with version" {
    const content =
        \\.{
        \\    .packages = .{
        \\        .nginx = .{
        \\            .version = "1.18.0-1",
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.packages != null);

    if (manifest.packages) |pkgs| {
        const pkg = pkgs.get("nginx");
        try std.testing.expect(pkg != null);
        if (pkg) |p| {
            try std.testing.expect(p.version != null);
            if (p.version) |ver| {
                try std.testing.expect(std.mem.eql(u8, ver, "1.18.0-1"));
            }
        }
    }
}

test "parse package with hyphenated name" {
    const content =
        \\.{
        \\    .packages = .{
        \\        .@"build-essential" = .{},
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    if (manifest.packages) |pkgs| {
        const pkg = pkgs.get("build-essential");
        try std.testing.expect(pkg != null);
        if (pkg) |p| {
            try std.testing.expect(std.mem.eql(u8, p.name, "build-essential"));
        }
    }
}

test "parse manifest with single service" {
    const content =
        \\.{
        \\    .services = .{
        \\        .nginx = .{},
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.services != null);

    if (manifest.services) |svcs| {
        try std.testing.expect(svcs.count() == 1);

        const svc = svcs.get("nginx");
        try std.testing.expect(svc != null);
        if (svc) |s| {
            try std.testing.expect(std.mem.eql(u8, s.name, "nginx"));
            try std.testing.expect(s.state == .running); // Default
            try std.testing.expect(s.enabled == true); // Default
        }
    }
}

test "parse manifest with multiple services" {
    const content =
        \\.{
        \\    .services = .{
        \\        .nginx = .{},
        \\        .postgresql = .{ .state = .running },
        \\        .apache2 = .{ .state = .stopped, .enabled = false },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.services != null);

    if (manifest.services) |svcs| {
        try std.testing.expect(svcs.count() == 3);

        if (svcs.get("nginx")) |s| {
            try std.testing.expect(s.state == .running);
            try std.testing.expect(s.enabled == true);
        }

        if (svcs.get("postgresql")) |s| {
            try std.testing.expect(s.state == .running);
            try std.testing.expect(s.enabled == true);
        }

        if (svcs.get("apache2")) |s| {
            try std.testing.expect(s.state == .stopped);
            try std.testing.expect(s.enabled == false);
        }
    }
}

test "parse service with custom state and enabled" {
    const content =
        \\.{
        \\    .services = .{
        \\        .nginx = .{
        \\            .state = .stopped,
        \\            .enabled = false,
        \\        },
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    if (manifest.services) |svcs| {
        if (svcs.get("nginx")) |s| {
            try std.testing.expect(s.state == .stopped);
            try std.testing.expect(s.enabled == false);
        }
    }
}

test "parse service with hyphenated name" {
    const content =
        \\.{
        \\    .services = .{
        \\        .@"my-service" = .{},
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    if (manifest.services) |svcs| {
        const svc = svcs.get("my-service");
        try std.testing.expect(svc != null);
        if (svc) |s| {
            try std.testing.expect(std.mem.eql(u8, s.name, "my-service"));
        }
    }
}

test "parse manifest with apt_update" {
    const content =
        \\.{
        \\    .apt_update = .{},
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.apt_update != null);

    if (manifest.apt_update) |apt| {
        try std.testing.expect(std.mem.eql(u8, apt.name, "update"));
    }
}

test "parse manifest with apt_update and packages" {
    const content =
        \\.{
        \\    .apt_update = .{},
        \\    .packages = .{
        \\        .nginx = .{},
        \\    },
        \\}
    ;

    var manifest = try parse(std.testing.allocator, content);
    defer manifest.deinit();

    try std.testing.expect(manifest.apt_update != null);
    try std.testing.expect(manifest.packages != null);

    if (manifest.apt_update) |apt| {
        try std.testing.expect(std.mem.eql(u8, apt.name, "update"));
    }
}
