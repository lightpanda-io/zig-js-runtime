const std = @import("std");

pub const Entity = struct {};

// TODO: handle memory allocation in the data struct itself.
// Each struct should have a deinit method to free internal memory and destroy object itself.
// Each setter should accept an alloc arg in order to free pre-existing internal allocation.
// Each method should accept an alloc arg in order to handle internal allocation (alloc or free).
// Is it worth it with an Arena like allocator?
// see the balance between memory size and cost of free

pub const Person = struct {
    first_name: []u8,
    last_name: []u8,
    age: u32,

    pub const prototype = Entity;

    pub fn constructor(first_name: []u8, last_name: []u8, age: u32) Person {
        return .{
            .first_name = first_name,
            .last_name = last_name,
            .age = age,
        };
    }

    pub fn getAge(self: Person) u32 {
        return self.age;
    }

    pub fn setAge(self: *Person, age: u32) void {
        self.age = age;
    }

    pub fn fullName(self: Person) []u8 {
        return self.last_name;
    }
};
