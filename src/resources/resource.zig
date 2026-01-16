const std = @import("std");
const system = @import("../system.zig");

/// Resource state after checking
pub const ResourceState = enum {
    satisfied,    // Current state matches desired state
    needs_change, // Needs to be modified
    failed,       // Unable to check state
};

/// Result of applying a resource
pub const ResourceResult = struct {
    state: ResourceState,
    message: []const u8,
    changed: bool,
};

/// Common attributes for all resources
pub const ResourceBase = struct {
    allow_failure: bool = false,
};

// Resource Interface Pattern
//
// All resources should implement these three methods:
//
// pub fn check(self: *Self, sys: *const system.SystemInfo) !ResourceState
//     Check if the resource is in the desired state.
//     Returns:
//       - .satisfied if current state matches desired state
//       - .needs_change if modifications are needed
//       - .failed if unable to check (error should be returned via !)
//
// pub fn apply(self: *Self, sys: *const system.SystemInfo, dry_run: bool) !ResourceResult
//     Apply changes to bring resource to desired state.
//     Parameters:
//       - dry_run: if true, don't make actual changes, just return what would happen
//     Returns ResourceResult with:
//       - state: final state after application
//       - message: human-readable description of what was done
//       - changed: true if changes were made, false if already satisfied
//
// pub fn describe(self: *const Self) []const u8
//     Return a human-readable description of this resource.
//     Used for logging (e.g., "Directory /opt/app", "File /etc/config")
//
// Example implementation pattern:
//
// pub const MyResource = struct {
//     base: resource.ResourceBase = .{},
//     name: []const u8,
//     state: MyState = .desired_default,
//
//     pub const MyState = enum { desired_default, alternative };
//
//     pub fn check(self: *MyResource, sys: *const system.SystemInfo) !resource.ResourceState {
//         // Read current system state
//         // Compare with self.state
//         // Return .satisfied or .needs_change
//     }
//
//     pub fn apply(self: *MyResource, sys: *const system.SystemInfo, dry_run: bool) !resource.ResourceResult {
//         if (dry_run) {
//             return .{
//                 .state = .needs_change,
//                 .message = "Would modify resource",
//                 .changed = true,
//             };
//         }
//
//         // Make actual changes
//         // Return result
//     }
//
//     pub fn describe(self: *const MyResource) []const u8 {
//         return self.name;
//     }
// };

// Tests
test "ResourceBase has default values" {
    const base = ResourceBase{};
    try std.testing.expect(base.allow_failure == false);
}

test "ResourceBase can override defaults" {
    const base = ResourceBase{ .allow_failure = true };
    try std.testing.expect(base.allow_failure == true);
}

test "ResourceState enum values" {
    const satisfied = ResourceState.satisfied;
    const needs_change = ResourceState.needs_change;
    const failed = ResourceState.failed;

    try std.testing.expect(satisfied == .satisfied);
    try std.testing.expect(needs_change == .needs_change);
    try std.testing.expect(failed == .failed);
}

test "ResourceResult can be created" {
    const result = ResourceResult{
        .state = .satisfied,
        .message = "Test message",
        .changed = false,
    };

    try std.testing.expect(result.state == .satisfied);
    try std.testing.expect(std.mem.eql(u8, result.message, "Test message"));
    try std.testing.expect(result.changed == false);
}
