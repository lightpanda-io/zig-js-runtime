const std = @import("std");

const eng = @import("engine.zig");

const shell = @import("shell.zig").shell;

const callback = @import("tests/cbk_test.zig");

pub fn main() !void {

    // generate APIs
    const apis = comptime callback.generate();

    // create v8 vm
    const vm = eng.VM.init();
    defer vm.deinit();

    // alloc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // launch shell
    try shell(alloc, apis, "/tmp/jsruntime-shell.sock");
}
