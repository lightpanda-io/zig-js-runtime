const std = @import("std");

const v8 = @import("v8");

const Loop = @import("loop.zig").SingleThreaded;

// TODO: using global allocator, not sure it's the best way
// better allocator ?
pub var allocator: std.mem.Allocator = undefined;

pub var loop: *Loop = undefined;

pub fn valueToUtf8(alloc: std.mem.Allocator, value: v8.Value, isolate: v8.Isolate, ctx: v8.Context) ![]u8 {
    const str = try value.toString(ctx);
    const len = str.lenUtf8(isolate);
    const buf = try alloc.alloc(u8, len);
    _ = str.writeUtf8(isolate, buf);
    return buf;
}
