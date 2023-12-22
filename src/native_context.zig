const std = @import("std");

const Loop = @import("api.zig").Loop;

pub const NativeContext = struct {
    alloc: std.mem.Allocator,
    loop: *Loop,
    objects: *Objects,

    // NOTE: DO NOT ACCESS DIRECTLY js_types
    // - use once loadTypes at startup to set them
    // - and then getType during execution to access them
    js_types: ?[]usize = null,

    pub const Objects = std.AutoHashMapUnmanaged(usize, usize);

    // loadTypes into the NativeContext
    // The caller holds the memory of the js_types slice,
    // no heap allocation is performed at the NativeContext level
    pub fn loadTypes(self: *NativeContext, js_types: []usize) void {
        std.debug.assert(self.js_types == null);
        self.js_types = js_types;
    }

    pub fn getType(self: NativeContext, comptime T: type, index: usize) *T {
        std.debug.assert(self.js_types != null);
        const t = self.js_types.?[index];
        return @as(*T, @ptrFromInt(t));
    }
};
