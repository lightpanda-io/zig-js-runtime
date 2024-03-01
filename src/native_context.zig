const std = @import("std");

const Loop = @import("api.zig").Loop;
const refs = @import("internal_api.zig").refs;

pub const NativeContext = struct {
    alloc: std.mem.Allocator,
    loop: *Loop,
    objects: *Objects,

    // NOTE: DO NOT ACCESS DIRECTLY js_types
    // - use once loadTypes at startup to set them
    // - and then getType during execution to access them
    js_types: ?[]usize = null,

    refs: refs.Map = .{},

    pub const Objects = std.AutoHashMapUnmanaged(usize, usize);

    pub fn init(alloc: std.mem.Allocator, loop: *Loop) !*NativeContext {
        const self = try alloc.create(NativeContext);
        const objects_ptr = try alloc.create(NativeContext.Objects);
        objects_ptr.* = NativeContext.Objects{};
        self.* = .{
            .alloc = alloc,
            .loop = loop,
            .objects = objects_ptr,
        };
        return self;
    }

    pub fn stop(self: *NativeContext) void {
        self.refs.clearAndFree(self.alloc);
    }

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

    pub fn deinit(self: *NativeContext) void {
        self.stop();
        self.objects.deinit(self.alloc);
        self.alloc.destroy(self.objects);
        self.* = undefined;
    }
};
