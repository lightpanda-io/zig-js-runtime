const std = @import("std");

pub const Entity = struct {};

pub const Person = struct {
    age: u32,

    pub const prototype = Entity;

    pub fn constructor(age: u32) Person {
        return .{ .age = age };
    }

    pub fn getAge(self: Person) u32 {
        return self.age;
    }

    pub fn setAge(self: *Person, age: u32) void {
        self.age = age;
    }

    pub fn otherAge(self: Person) u32 {
        return self.age;
    }
};
