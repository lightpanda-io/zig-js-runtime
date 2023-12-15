const std = @import("std");

const Loop = @import("api.zig").Loop;

pub const NativeContext = struct {
    alloc: std.mem.Allocator,
    loop: *Loop,
    objects: *Objects,

    pub const Objects = std.AutoHashMapUnmanaged(usize, usize);
};
