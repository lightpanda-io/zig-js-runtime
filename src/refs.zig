const std = @import("std");

const refl = @import("reflect.zig");

pub const Map = std.AutoHashMapUnmanaged(usize, usize);
pub var map: Map = undefined;

pub fn addObject(alloc: std.mem.Allocator, key: usize, value: usize) !void {
    try map.put(alloc, key, value);
}

pub fn getObject(comptime T: type, comptime types: []refl.Struct, ptr: anytype) !*T {
    const key = @ptrCast(*usize, @alignCast(8, ptr));
    const T_index = map.get(key.*);
    if (T_index == null) {
        return error.NullReference;
    }
    inline for (types) |T_refl| {
        if (T_refl.index == T_index.?) {
            if (T_refl.size != 0) { // stage1: condition is needed for empty structs
                const target_ptr = @intToPtr(*T_refl.T, key.*);
                return try getRealObject(T, target_ptr);
            }
        }
    }
    return error.Reference;
}

fn getRealObject(comptime T: type, target_ptr: anytype) !*T {
    const T_target = @TypeOf(target_ptr.*);
    if (T_target == T) {
        return target_ptr;
    }
    if (@hasField(T_target, "proto")) {
        // here we retun the "right" pointer: &(field(...))
        // ie. the direct pointer to the field
        // and not a pointer to a new const/var holding the field

        // TODO: and what if we have more than 2 types in the chain?
        return getRealObject(T, &(@field(target_ptr, "proto")));
    }
    return error.Reference;
}
