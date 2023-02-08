const std = @import("std");

const jsruntime = @import("jsruntime.zig");

const Window = @import("tests/cbk_test.zig").Window;

pub fn main() !void {

    // generate APIs
    const apis = jsruntime.compile(.{ jsruntime.Console, Window });

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // alloc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    // launch shell
    try jsruntime.shell(&arena, apis, null, .{ .app_name = "jsruntime-shell" });
}
