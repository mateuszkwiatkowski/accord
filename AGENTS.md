# AGENTS.md - AI Agent Documentation for accord

## Project Overview

**accord** is a lightweight configuration management system written in Zig, inspired by CFEngine's promise theory. It provides a simple, UNIX-philosophy-driven approach to managing system state through declarative manifests written in Zig Object Notation (ZON).

### Core Principles

1. **Promise Theory**: Declare desired state, accord makes it so
2. **UNIX Philosophy**: Small, focused tool that does one thing well
3. **KISS**: Simple implementation, avoid over-engineering
4. **Lightweight**: Single binary, runs on-demand, clean exit codes
5. **Composable**: Works with other UNIX tools via proper exit codes
6. **Fail-Fast**: Stop on first error (unless `allow_failure = true`)
7. **Verbose by Default**: Clear output about what's happening

### Design Philosophy

- **Sequential Processing**: Resources applied in manifest order (no dependency graph)
- **Idempotent**: Running twice produces same result, no redundant changes
- **Extensible**: Easy to add new resource types and platform support
- **Type Safe**: Leverage Zig's compile-time safety
- **Cross-Platform**: Abstract platform differences behind clean interfaces
- **Sensible Defaults**: Most common operations require minimal configuration

---

## Architecture

### Directory Structure

```
accord/
├── src/
│   ├── main.zig              # Entry point, CLI parsing, main loop
│   ├── config.zig            # Config file parsing
│   ├── parser.zig            # ZON manifest parser
│   ├── system.zig            # Platform detection and abstraction
│   ├── apply.zig             # Resource application engine
│   ├── output.zig            # Logging and output formatting
│   └── resources/
│       ├── resource.zig      # Base resource interface and types
│       ├── file.zig          # File resource (content, mode, owner)
│       ├── directory.zig     # Directory resource
│       ├── package.zig       # Package resource (apt/yum/brew/etc)
│       ├── service.zig       # Service resource (systemd/launchd/etc)
│       ├── user.zig          # User resource
│       └── group.zig         # Group resource
├── test/
│   ├── parser_test.zig       # ZON parsing tests
│   ├── system_test.zig       # Platform detection tests
│   ├── resources/            # Per-resource unit tests
│   │   ├── file_test.zig
│   │   ├── directory_test.zig
│   │   ├── package_test.zig
│   │   ├── service_test.zig
│   │   ├── user_test.zig
│   │   └── group_test.zig
│   ├── integration_test.zig  # End-to-end tests
│   └── fixtures/             # Sample manifests for testing
│       ├── webserver.zon
│       ├── devenv.zon
│       ├── database.zon
│       └── invalid.zon
├── examples/                 # User-facing example manifests
│   ├── webserver.zon
│   ├── devenv.zon
│   ├── database.zon
│   └── docker-host.zon
├── build.zig                 # Build configuration
├── build.zig.zon             # Package dependencies (pinned Zig version)
├── AGENTS.md                 # This file
├── README.md                 # User-facing documentation
├── LICENSE                   # MIT license
└── doc/
    ├── accord.1              # Main command man page
    ├── accord-manifest.5     # Manifest format specification
    └── accord-resources.7    # Resource types reference
```

### Module Responsibilities

#### `main.zig`
- Parse command-line arguments
- Load config file if specified with `--config`
- Initialize system detection
- Parse manifest
- Execute resource application
- Handle errors and exit codes
- Manage log level

**Exit Codes**:
- `0` - Success (all resources satisfied or applied)
- `1` - General error
- `2` - Invalid manifest (parse error)
- `3` - Permission denied
- `4` - Resource operation failed

#### `config.zig`
- Parse ZON config file
- Merge config with CLI flags (CLI takes precedence)
- Config structure:
  ```zig
  .{
      .log_level = .verbose,  // .quiet, .normal, .verbose, .debug
      .color = true,          // Enable colored output
  }
  ```

#### `parser.zig`
- Parse ZON manifest into resource structures
- Validate manifest structure (strict mode - unknown fields = error)
- Return parsed resource list in order
- Apply sensible defaults for omitted fields

#### `system.zig`
Platform detection and abstraction layer. This is **critical for extensibility**.

**Key Types**:
```zig
pub const SystemInfo = struct {
    os_family: OsFamily,
    pkg_manager: ?PkgManager,
    init_system: ?InitSystem,
    
    pub fn detect() !SystemInfo;
};

pub const OsFamily = enum {
    debian,      // Current: Debian, Ubuntu
    redhat,      // Future: RHEL, CentOS, Fedora, Rocky
    arch,        // Future: Arch Linux, Manjaro
    alpine,      // Future: Alpine Linux
    macos,       // Future: macOS
    freebsd,     // Future: FreeBSD
    openbsd,     // Future: OpenBSD
    netbsd,      // Future: NetBSD
    unknown,
};

pub const PkgManager = enum {
    apt,         // Current: Debian/Ubuntu (apt-get)
    yum,         // Future: Legacy RHEL
    dnf,         // Future: Modern Fedora/RHEL
    pacman,      // Future: Arch
    apk,         // Future: Alpine
    brew,        // Future: macOS Homebrew
    pkg,         // Future: FreeBSD
    pkg_add,     // Future: OpenBSD
    pkgin,       // Future: NetBSD
};

pub const InitSystem = enum {
    systemd,     // Current: Modern Linux
    sysvinit,    // Future: Legacy init
    launchd,     // Future: macOS
    rc,          // Future: BSD rc.d
    openrc,      // Future: Alpine/Gentoo
};
```

**Detection Strategy**:
1. Check `/etc/os-release` for Linux distributions
2. Check `uname` for BSD/macOS
3. Test for package manager presence (`which apt-get`, etc.)
4. Test for init system (`systemctl --version`, etc.)
5. Cache result for duration of run

#### `apply.zig`
Resource application engine.

```zig
pub fn applyResources(
    resources: []const Resource,
    system: *const SystemInfo,
    dry_run: bool,
) !ApplyResult {
    // For each resource in order:
    //   1. Check current state
    //   2. If not satisfied, apply changes
    //   3. If allow_failure=false and error occurs, return immediately
    //   4. If allow_failure=true and error occurs, log and continue
    //   5. Track statistics
    
    // Return summary of applied changes
}

pub const ApplyResult = struct {
    total: usize,
    satisfied: usize,
    applied: usize,
    failed: usize,
    errors: []const Error,
};
```

#### `output.zig`
Logging and output formatting.

```zig
pub const LogLevel = enum {
    quiet,    // Only errors and summary
    normal,   // Changes only (not "already satisfied")
    verbose,  // All checks and changes (DEFAULT)
    debug,    // Internal details for debugging
};

pub fn logCheck(resource_type: []const u8, name: []const u8, state: ResourceState) void;
pub fn logApply(resource_type: []const u8, name: []const u8, action: []const u8) void;
pub fn logError(resource_type: []const u8, name: []const u8, err: anyerror) void;
pub fn logSummary(result: ApplyResult) void;
```

**Output Format** (verbose):
```
[CHECK] Package nginx... not installed
[APPLY] Installing package nginx... done
[CHECK] File /etc/nginx/nginx.conf... content differs
[APPLY] Writing file /etc/nginx/nginx.conf... done
[CHECK] Service nginx... stopped
[APPLY] Starting service nginx... done

Summary: 3 resources checked, 3 changes applied, 0 failed
```

#### `resources/resource.zig`
Base types and interfaces for all resources.

```zig
pub const ResourceState = enum {
    satisfied,    // Current state matches desired state
    needs_change, // Needs to be modified
    failed,       // Unable to check state
};

pub const ResourceResult = struct {
    state: ResourceState,
    message: []const u8,
    changed: bool,
};

// Common attributes for all resources
pub const ResourceBase = struct {
    allow_failure: bool = false,
};

// Generic resource interface using comptime polymorphism
pub fn Resource(comptime T: type) type {
    return struct {
        // Check if resource is in desired state
        pub fn check(self: *T, system: *const SystemInfo) !ResourceState;
        
        // Apply changes to reach desired state
        pub fn apply(self: *T, system: *const SystemInfo, dry_run: bool) !ResourceResult;
        
        // Human-readable description
        pub fn describe(self: *const T) []const u8;
    };
}
```

---

## Resource Defaults

All resources have sensible defaults to minimize configuration:

### Package Resource
```zig
pub const PackageResource = struct {
    base: ResourceBase = .{},
    name: []const u8,
    state: PackageState = .installed,  // DEFAULT: install
    version: ?[]const u8 = null,
};
```

**Manifest**:
```zig
.packages = .{
    .nginx = .{},  // Uses default: state = .installed
    .apache2 = .{ .state = .absent },  // Explicit removal
}
```

### File Resource
```zig
pub const FileResource = struct {
    base: ResourceBase = .{},
    path: []const u8,
    content: ?[]const u8 = null,
    source: ?[]const u8 = null,
    mode: ?u32 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
    state: FileState = .present,  // DEFAULT: create/ensure present
};
```

**Manifest**:
```zig
.files = .{
    .@"/etc/app.conf" = .{
        .content = "config",  // Uses default: state = .present
    },
    .@"/etc/old.conf" = .{
        .state = .absent,  // Explicit removal
    },
}
```

### Service Resource
```zig
pub const ServiceResource = struct {
    base: ResourceBase = .{},
    name: []const u8,
    state: ServiceState = .running,  // DEFAULT: running
    enabled: bool = true,            // DEFAULT: enabled at boot
};
```

**Manifest**:
```zig
.services = .{
    .nginx = .{},  // Uses defaults: running + enabled
    .old_service = .{
        .state = .stopped,
        .enabled = false,
    },
}
```

### Directory Resource
```zig
pub const DirectoryResource = struct {
    base: ResourceBase = .{},
    path: []const u8,
    mode: ?u32 = null,
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
    state: DirState = .present,  // DEFAULT: create/ensure present
};
```

---

## Extensibility Guide

### Adding a New Resource Type

Follow this checklist when implementing a new resource:

#### 1. Create resource file: `src/resources/newresource.zig`

```zig
const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");

pub const NewResource = struct {
    base: resource.ResourceBase = .{},
    
    // Resource-specific fields with sensible defaults
    name: []const u8,
    some_attribute: []const u8,
    optional_attribute: ?u32 = null,
    state: NewResourceState = .desired_default,
    
    pub const NewResourceState = enum { desired_default, alternative };
    
    // Implement required interface
    pub fn check(self: *NewResource, sys: *const system.SystemInfo) !resource.ResourceState {
        // 1. Read current system state
        // 2. Compare with desired state (self.*)
        // 3. Return .satisfied or .needs_change
    }
    
    pub fn apply(self: *NewResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        // 1. If dry_run, just return what would happen
        // 2. Otherwise, make the actual changes
        // 3. Return result with changed=true/false
    }
    
    pub fn describe(self: *const NewResource) []const u8 {
        // Return human-readable description like "NewResource myname"
        return self.name;
    }
};
```

#### 2. Add to manifest parser (`parser.zig`)

```zig
// Add to Manifest struct
pub const Manifest = struct {
    packages: ?std.StringHashMap(PackageResource) = null,
    files: ?std.StringHashMap(FileResource) = null,
    newresources: ?std.StringHashMap(NewResource) = null, // ADD THIS
    // ... other resources
};

// Add parsing logic in parse() function
if (manifest_obj.get("newresources")) |newres_obj| {
    var newres_map = std.StringHashMap(NewResource).init(allocator);
    var iter = newres_obj.iterator();
    while (iter.next()) |entry| {
        const resource_data = try parseNewResource(entry.value_ptr.*);
        try newres_map.put(entry.key_ptr.*, resource_data);
    }
    manifest.newresources = newres_map;
}
```

#### 3. Add to application loop (`apply.zig`)

```zig
// Add to applyResources function
if (manifest.newresources) |newres_map| {
    var iter = newres_map.iterator();
    while (iter.next()) |entry| {
        try applySingleResource(entry.value_ptr, system, dry_run);
    }
}
```

#### 4. Write unit tests (`test/resources/newresource_test.zig`)

```zig
const std = @import("std");
const testing = std.testing;
const NewResource = @import("../../src/resources/newresource.zig").NewResource;
const system = @import("../../src/system.zig");

test "NewResource check - satisfied" {
    // Test when resource is already in desired state
    var resource = NewResource{
        .name = "test",
        .some_attribute = "value",
    };
    
    // Mock system info
    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };
    
    const state = try resource.check(&sys_info);
    try testing.expectEqual(.satisfied, state);
}

test "NewResource check - needs change" {
    // Test when resource needs modification
}

test "NewResource apply - success" {
    // Test successful application
}

test "NewResource apply - dry run" {
    // Test that dry run doesn't modify anything
}

test "NewResource apply - failure" {
    // Test error handling
}
```

#### 5. Document in man page (`doc/accord-resources.7`)

Add section describing the new resource type, its attributes, and examples.

---

### Adding Platform Support

To add support for a new OS or platform:

#### 1. Update `system.zig` enums

```zig
pub const OsFamily = enum {
    // ... existing
    newos,  // Add your OS
};

pub const PkgManager = enum {
    // ... existing
    newpkg,  // Add package manager
};
```

#### 2. Update detection logic

```zig
pub fn detect() !SystemInfo {
    var info: SystemInfo = undefined;
    
    // Detect OS family
    if (try detectNewOs()) {
        info.os_family = .newos;
        info.pkg_manager = .newpkg;
        info.init_system = try detectInitSystem();
        return info;
    }
    
    // ... existing detection
}

fn detectNewOs() !bool {
    // Check for OS-specific files, commands, etc.
    // Example: check /etc/newos-release exists
    const file = std.fs.openFileAbsolute("/etc/newos-release", .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    file.close();
    return true;
}
```

#### 3. Implement platform-specific operations in resources

```zig
// In src/resources/package.zig
pub fn apply(self: *PackageResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
    return switch (sys.pkg_manager orelse return error.NoPkgManager) {
        .apt => try applyApt(self, dry_run),
        .newpkg => try applyNewPkg(self, dry_run),  // ADD THIS
        // ... other package managers
        else => error.UnsupportedPkgManager,
    };
}

fn applyNewPkg(self: *PackageResource, dry_run: bool) !resource.ResourceResult {
    const allocator = std.heap.page_allocator;
    
    const args = switch (self.state) {
        .installed => &[_][]const u8{ "newpkg", "install", self.name },
        .absent => &[_][]const u8{ "newpkg", "remove", self.name },
    };
    
    if (dry_run) {
        return .{
            .state = .needs_change,
            .message = "Would run newpkg",
            .changed = true,
        };
    }
    
    var child = std.ChildProcess.init(args, allocator);
    const result = try child.spawnAndWait();
    
    if (result != .Exited or result.Exited != 0) {
        return error.PackageOperationFailed;
    }
    
    return .{
        .state = .satisfied,
        .message = "Package operation completed",
        .changed = true,
    };
}
```

#### 4. Add platform-specific tests

```zig
test "Package install - newpkg" {
    // Test package operations on new platform
    // May need to skip on other platforms:
    if (builtin.os.tag != .newos) return error.SkipZigTest;
    
    // Test implementation
}
```

#### 5. Update documentation

- README.md: Add to supported platforms list
- doc/accord-resources.7: Note platform-specific behaviors
- AGENTS.md: Update roadmap

---

## Resource Implementation Examples

### Example: File Resource

```zig
// src/resources/file.zig
const std = @import("std");
const fs = std.fs;
const resource = @import("resource.zig");
const system = @import("../system.zig");

pub const FileResource = struct {
    base: resource.ResourceBase = .{},
    
    path: []const u8,
    content: ?[]const u8 = null,
    source: ?[]const u8 = null,  // Copy from source file
    mode: ?u32 = null,           // Octal file mode (e.g., 0o644)
    owner: ?[]const u8 = null,
    group: ?[]const u8 = null,
    state: FileState = .present, // DEFAULT
    
    pub const FileState = enum { present, absent };
    
    pub fn check(self: *FileResource, sys: *const system.SystemInfo) !resource.ResourceState {
        _ = sys; // May need for platform-specific checks
        
        const file = fs.openFileAbsolute(self.path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => if (self.state == .absent) 
                    .satisfied else .needs_change,
                else => error.CheckFailed,
            };
        };
        defer file.close();
        
        if (self.state == .absent) return .needs_change;
        
        // Check content if specified
        if (self.content) |desired_content| {
            const stat = try file.stat();
            if (stat.size != desired_content.len) return .needs_change;
            
            var buf = try std.heap.page_allocator.alloc(u8, stat.size);
            defer std.heap.page_allocator.free(buf);
            
            const actual_len = try file.readAll(buf);
            if (!std.mem.eql(u8, buf[0..actual_len], desired_content)) {
                return .needs_change;
            }
        }
        
        // Check mode if specified
        if (self.mode) |desired_mode| {
            const stat = try file.stat();
            const actual_mode = stat.mode & 0o777;
            if (actual_mode != desired_mode) {
                return .needs_change;
            }
        }
        
        // TODO: Check owner/group
        
        return .satisfied;
    }
    
    pub fn apply(self: *FileResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        _ = sys;
        
        if (dry_run) {
            return .{
                .state = .needs_change,
                .message = "Would modify file",
                .changed = true,
            };
        }
        
        switch (self.state) {
            .absent => {
                try fs.deleteFileAbsolute(self.path);
                return .{
                    .state = .satisfied,
                    .message = "File removed",
                    .changed = true,
                };
            },
            .present => {
                // Write content
                if (self.content) |content| {
                    const file = try fs.createFileAbsolute(self.path, .{});
                    defer file.close();
                    try file.writeAll(content);
                } else if (self.source) |src| {
                    try fs.copyFileAbsolute(src, self.path, .{});
                }
                
                // Set mode
                if (self.mode) |mode| {
                    const file = try fs.openFileAbsolute(self.path, .{});
                    defer file.close();
                    try file.chmod(mode);
                }
                
                // TODO: Set owner/group (chown)
                
                return .{
                    .state = .satisfied,
                    .message = "File created/updated",
                    .changed = true,
                };
            },
        }
    }
    
    pub fn describe(self: *const FileResource) []const u8 {
        return self.path;
    }
};
```

### Example: Package Resource (apt only, current)

```zig
// src/resources/package.zig
const std = @import("std");
const resource = @import("resource.zig");
const system = @import("../system.zig");

pub const PackageResource = struct {
    base: resource.ResourceBase = .{},
    
    name: []const u8,
    state: PackageState = .installed,  // DEFAULT
    version: ?[]const u8 = null,
    
    pub const PackageState = enum { installed, absent };
    
    pub fn check(self: *PackageResource, sys: *const system.SystemInfo) !resource.ResourceState {
        return switch (sys.pkg_manager orelse return error.NoPkgManager) {
            .apt => try checkApt(self),
            else => error.UnsupportedPkgManager,
        };
    }
    
    fn checkApt(self: *PackageResource) !resource.ResourceState {
        // Run: dpkg -s <package> 2>/dev/null
        var child = std.ChildProcess.init(
            &[_][]const u8{ "dpkg", "-s", self.name },
            std.heap.page_allocator,
        );
        child.stderr_behavior = .Ignore;
        
        const result = try child.spawnAndWait();
        
        const is_installed = result == .Exited and result.Exited == 0;
        
        return if (is_installed == (self.state == .installed))
            .satisfied
        else
            .needs_change;
    }
    
    pub fn apply(self: *PackageResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
        return switch (sys.pkg_manager orelse return error.NoPkgManager) {
            .apt => try applyApt(self, dry_run),
            else => error.UnsupportedPkgManager,
        };
    }
    
    fn applyApt(self: *PackageResource, dry_run: bool) !resource.ResourceResult {
        const allocator = std.heap.page_allocator;
        
        const args = switch (self.state) {
            .installed => &[_][]const u8{
                "apt-get", "install", "-y", self.name,
            },
            .absent => &[_][]const u8{
                "apt-get", "remove", "-y", self.name,
            },
        };
        
        if (dry_run) {
            return .{
                .state = .needs_change,
                .message = "Would run apt-get",
                .changed = true,
            };
        }
        
        var child = std.ChildProcess.init(args, allocator);
        const result = try child.spawnAndWait();
        
        if (result != .Exited or result.Exited != 0) {
            return error.PackageOperationFailed;
        }
        
        return .{
            .state = .satisfied,
            .message = "Package operation completed",
            .changed = true,
        };
    }
    
    pub fn describe(self: *const PackageResource) []const u8 {
        return self.name;
    }
};
```

---

## Testing Strategy

### Unit Tests

Each resource and module should have comprehensive unit tests.

**Test File Structure**:
```zig
const std = @import("std");
const testing = std.testing;
const FileResource = @import("../src/resources/file.zig").FileResource;
const system = @import("../src/system.zig");

test "FileResource check - file exists and matches" {
    // Setup: create temp file with known content
    const tmp_path = "/tmp/accord-test-file";
    const test_content = "test content";
    
    const file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};
    try file.writeAll(test_content);
    file.close();
    
    // Execute: check()
    var resource = FileResource{
        .path = tmp_path,
        .content = test_content,
    };
    
    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };
    
    const state = try resource.check(&sys_info);
    
    // Assert: returns .satisfied
    try testing.expectEqual(.satisfied, state);
}

test "FileResource check - file missing" {
    var resource = FileResource{
        .path = "/tmp/accord-nonexistent-file",
        .content = "test",
    };
    
    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };
    
    const state = try resource.check(&sys_info);
    try testing.expectEqual(.needs_change, state);
}

test "FileResource apply - creates file" {
    const tmp_path = "/tmp/accord-test-create";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};
    
    var resource = FileResource{
        .path = tmp_path,
        .content = "new content",
        .mode = 0o644,
    };
    
    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };
    
    const result = try resource.apply(&sys_info, false);
    try testing.expectEqual(true, result.changed);
    
    // Verify file exists
    const file = try std.fs.openFileAbsolute(tmp_path, .{});
    defer file.close();
}

test "FileResource apply - dry run doesn't modify" {
    const tmp_path = "/tmp/accord-test-dryrun";
    
    var resource = FileResource{
        .path = tmp_path,
        .content = "content",
    };
    
    var sys_info = system.SystemInfo{
        .os_family = .debian,
        .pkg_manager = .apt,
        .init_system = .systemd,
    };
    
    _ = try resource.apply(&sys_info, true);
    
    // File should not exist
    const result = std.fs.openFileAbsolute(tmp_path, .{});
    try testing.expectError(error.FileNotFound, result);
}
```

**Run Tests**:
```bash
zig build test
```

### Integration Tests

Test complete manifest parsing and application.

```zig
test "apply manifest - all resources" {
    const manifest_content =
        \\.{
        \\    .files = .{
        \\        .@"/tmp/accord-integration-test.txt" = .{
        \\            .content = "hello accord",
        \\            .mode = 0o644,
        \\        },
        \\    },
        \\}
    ;
    
    // Parse manifest
    const manifest = try parser.parse(manifest_content);
    defer manifest.deinit();
    
    // Apply with dry_run=false
    const result = try apply.applyResources(manifest, &sys_info, false);
    
    try testing.expectEqual(@as(usize, 1), result.applied);
    try testing.expectEqual(@as(usize, 0), result.failed);
    
    // Verify file was created
    const file = try std.fs.openFileAbsolute("/tmp/accord-integration-test.txt", .{});
    defer file.close();
    defer std.fs.deleteFileAbsolute("/tmp/accord-integration-test.txt") catch {};
}
```

### System Tests

Test on real systems (Docker containers recommended).

```bash
# Test on Debian container
docker run -v $(pwd):/accord debian:bookworm bash -c "cd /accord && zig build && ./zig-out/bin/accord apply examples/webserver.zon"

# Test on Ubuntu container
docker run -v $(pwd):/accord ubuntu:22.04 bash -c "cd /accord && zig build && ./zig-out/bin/accord apply examples/webserver.zon"
```

**Idempotency Test**:
```bash
# Run twice, second run should show 0 changes
accord apply manifest.zon
accord apply manifest.zon  # Should be all "already satisfied"
```

---

## Code Patterns and Idioms

### Error Handling

Use Zig's error unions consistently:

```zig
pub fn doSomething() !void {
    // Use try for propagation
    try operationThatMightFail();
    
    // Use catch for handling
    const result = operationThatMightFail() catch |err| {
        std.log.err("Operation failed: {}", .{err});
        return err;
    };
}
```

### Memory Management

Use arena allocator for request-scoped allocations:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    
    // Use arena_allocator for temporary allocations
    // Everything freed automatically when arena.deinit() is called
}
```

### Comptime Polymorphism

Use `comptime` for generic resource handling:

```zig
fn applySingleResource(
    comptime T: type,
    resource: *T,
    system_info: *const SystemInfo,
    dry_run: bool,
) !void {
    const state = try resource.check(system_info);
    if (state == .satisfied) return;
    
    _ = try resource.apply(system_info, dry_run);
}
```

### String Formatting

Use `std.fmt` for consistent formatting:

```zig
const msg = try std.fmt.allocPrint(
    allocator,
    "[APPLY] {s} {s}... {s}",
    .{ resource_type, name, status }
);
defer allocator.free(msg);
```

---

## Future Roadmap

### Phase 1: Foundation (Current - Debian/Ubuntu)
- ✓ Project setup and documentation
- [ ] ZON manifest parser
- [ ] System detection (Debian/Ubuntu, apt, systemd)
- [ ] Core resources: file, directory, package, service, user, group
- [ ] Unit and integration tests
- [ ] CLI with proper flags and exit codes

### Phase 2: Platform Expansion
- RedHat family (dnf/yum, systemd)
- Arch Linux (pacman, systemd)
- Alpine (apk, openrc)
- macOS (brew, launchd)
- FreeBSD (pkg, rc)
- OpenBSD (pkg_add, rc)

### Phase 3: Daemon Mode
- Optional background mode for continuous enforcement
- Watch manifest files for changes
- Periodic checks and convergence
- Socket-based control interface

### Phase 4: Advanced Features
- Manifest composition (include other manifests)
- Variables/interpolation (if needed)
- JSON output format for scripting
- Parallel resource application (where safe)
- Resource facts (query system state without applying)
- Rollback support

### Phase 5: Ecosystem
- Package manager integration (apt/yum repos)
- CI/CD examples and integrations
- Migration guides from Chef/Ansible/Salt
- Performance benchmarks
- Community resource library

---

## Common Pitfalls

### 1. Platform Detection
**Problem**: Assuming specific paths or commands exist  
**Solution**: Always check with `sys.pkg_manager` and handle `null` case

### 2. File Permissions
**Problem**: Running as non-root fails silently  
**Solution**: Return proper error codes (exit 3 for permission denied), check permissions early

### 3. Idempotency
**Problem**: Resource applies change even when not needed  
**Solution**: Always implement `check()` thoroughly, test by running twice

### 4. Error Messages
**Problem**: Generic errors that don't help debugging  
**Solution**: Include context (resource name, operation, system error)

### 5. Memory Leaks
**Problem**: Forgetting to free allocations  
**Solution**: Use arena allocator for request scope, always `defer` cleanup

### 6. Default Values
**Problem**: Not using Zig's default struct initialization  
**Solution**: Set defaults in struct definition, let parser use them

### 7. Sequential Processing
**Problem**: Trying to create dependency graphs  
**Solution**: Trust manifest ordering, keep it simple

---

## Development Workflow

### 1. Create Feature Branch
```bash
git checkout -b feature/new-resource
```

### 2. Implement Feature
- Write resource implementation with defaults
- Add unit tests
- Update parser and apply logic
- Update documentation

### 3. Test
```bash
zig build test                          # Unit tests
zig build -Doptimize=ReleaseSafe       # Build
./zig-out/bin/accord --version         # Smoke test
```

### 4. Integration Test
```bash
# Test on real system or container
sudo accord apply examples/test.zon
sudo accord apply examples/test.zon  # Idempotency check
```

### 5. Commit
```bash
git add .
git commit -m "Add new resource type: newresource"
```

---

## Questions for AI Agents

### When implementing a new resource:
1. What is the system state I'm managing?
2. What are sensible defaults for this resource?
3. How do I check if it's already in the desired state?
4. What commands/syscalls do I need to apply changes?
5. Is this operation idempotent?
6. What can fail, and how should I handle it?
7. Is this platform-specific?

### When adding platform support:
1. How do I detect this platform reliably?
2. What package manager(s) does it use?
3. What init system(s) does it use?
4. Are there platform-specific resource behaviors?
5. What testing environment can I use (Docker/VM)?

### When debugging:
1. What does the verbose output show?
2. Does the check() method correctly detect state?
3. Is apply() truly idempotent?
4. Are errors properly propagated?
5. Is the platform correctly detected?
6. Are defaults being applied correctly?

---

## Contact and Contribution

Repository: https://github.com/mateuszkwiatkowski/accord

This project follows UNIX philosophy and simplicity principles. When in doubt:
- Prefer explicit over implicit
- Prefer simple over clever
- Prefer readable over terse
- Use sensible defaults
- Test thoroughly
- Document clearly

Questions? Check README.md or man pages first, then open an issue on GitHub.
