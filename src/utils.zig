const std = @import("std");

const public = @import("api.zig");
const Loop = public.Loop;

// TODO: using global allocator, not sure it's the best way
// better allocator ?
pub var allocator: std.mem.Allocator = undefined;

pub var loop: *Loop = undefined;
