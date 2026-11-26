//! Fill in @VERSION@ and @DATE@ in a man page: stamp_man IN OUT VERSION DATE
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) std.process.fatal("usage: stamp_man IN OUT VERSION DATE", .{});

    const cwd = std.Io.Dir.cwd();
    const in = try cwd.readFileAlloc(io, args[1], arena, .limited(1 << 20));
    const with_version = try std.mem.replaceOwned(u8, arena, in, "@VERSION@", args[3]);
    const out = try std.mem.replaceOwned(u8, arena, with_version, "@DATE@", args[4]);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}
