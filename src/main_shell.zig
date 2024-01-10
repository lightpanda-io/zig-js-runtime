const std = @import("std");

const public = @import("api.zig");

const Window = @import("tests/cbk_test.zig").Window;

pub const Types = public.reflect(.{ public.Console, Window });

pub fn main() !void {

    // create JS vm
    const vm = public.VM.init();
    defer vm.deinit();

    // alloc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    // launch shell
    try public.shell(&arena, null, .{ .app_name = "jsruntime-shell" });
}
