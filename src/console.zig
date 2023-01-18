const std = @import("std");

pub const Console = struct {
    // TODO: configurable writer

    pub fn _log(_: Console, str: []const u8) void {
        std.debug.print("== JS console: {s} ==\n", .{str});
    }
};
