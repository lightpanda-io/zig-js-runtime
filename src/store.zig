const std = @import("std");

// TODO: make the Store a no-op
// if the allocator is an Arena like.
// In this case we do not need to free the items
// one by one, thew will be all freed at deinit of the allocator.
pub const Store = @This();

pub var default: Store = undefined;

// TODO: do not store size and alignement in each object
// as we know those values at comptime.
// Instead we can init thoses values for each type at comptime
// in some kind of map in the store,
// and use them at runtime when destroying objects
// This will allow reduce the memory needed of each object:
// - from 24 bytes (8 ptr addr, 8 size, 8 alignment
// - to 8 bytes (ptr addr)
const Object = struct {
    addr: usize,
    size: usize,
    alignment: u29,
};

const ObjectList = std.ArrayList(Object);
const StringList = std.ArrayList([]u8);

objects: ObjectList,
strings: StringList,

pub fn init(alloc: std.mem.Allocator) Store {
    const objects = ObjectList.init(alloc);
    const strings = StringList.init(alloc);
    return Store{
        .objects = objects,
        .strings = strings,
    };
}

// TODO: if the struct is empty we have the compile error
// panic: cast causes pointer to be null
pub fn addObject(self: *Store, ptr: anytype, size: usize, alignment: u29) !void {
    const item = Object{
        .addr = @ptrToInt(ptr),
        .size = size,
        .alignment = alignment,
    };
    try self.objects.append(item);
}

pub fn addString(self: *Store, str: []u8) !void {
    try self.strings.append(str);
}

pub fn deinit(self: Store, alloc: std.mem.Allocator) void {

    // free objects
    for (self.objects.items) |obj| {
        // copied from std.mem.Allocator.destroy()
        if (obj.size == 0) return;
        const non_const_ptr = @intToPtr([*]u8, obj.addr);
        alloc.rawFree(non_const_ptr[0..obj.size], obj.alignment, @returnAddress());
    }
    self.objects.deinit();

    // free strings
    for (self.strings.items) |str| {
        alloc.free(str);
    }
    self.strings.deinit();
}
