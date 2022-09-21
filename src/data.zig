const std = @import("std");

pub const Entity = struct {};

pub const Person = struct {
    age: i32,

    pub const prototype = Entity;

    pub fn constructor(age: i32) Person {
        return .{ .age = age };
    }

    pub fn getAge(self: Person) i32 {
        return self.age;
    }

    pub fn setAge(self: *Person, age: i32) void {
        self.age = age;
    }

    pub fn otherAge(self: Person) i32 {
        return self.age;
    }
};
