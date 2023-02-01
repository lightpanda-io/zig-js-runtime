const std = @import("std");

const v8 = @import("v8");

const eng = @import("engine.zig");
const gen = @import("generate.zig");

pub const Console = struct {
    // TODO: configurable writer

    pub fn _log(_: Console, str: []const u8) void {
        std.debug.print("== JS console: {s} ==\n", .{str});
    }
};
