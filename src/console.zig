const std = @import("std");

const log = std.log.scoped(.console);

pub const Console = struct {
    // TODO: configurable writer

    pub fn _log(_: Console, str: []const u8) void {
        log.debug("{s}\n", .{str});
    }
};
