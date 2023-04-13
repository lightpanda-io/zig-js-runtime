const std = @import("std");

const jsruntime = @import("../jsruntime.zig");

const tests = jsruntime.test_utils;

// TODO: handle memory allocation in the data struct itself.
// Each struct should have a deinit method to free internal memory and destroy object itself.
// Each setter should accept an alloc arg in order to free pre-existing internal allocation.
// Each method should accept an alloc arg in order to handle internal allocation (alloc or free).
// Is it worth it with an Arena like allocator?
// see the balance between memory size and cost of free

const Entity = struct {};

const Person = struct {
    first_name: []u8,
    last_name: []u8,
    age: u32,

    pub fn constructor(_: std.mem.Allocator, first_name: []u8, last_name: []u8, age: u32) Person {
        return .{
            .first_name = first_name,
            .last_name = last_name,
            .age = age,
        };
    }

    pub fn get_age(self: Person) u32 {
        return self.age;
    }

    pub fn set_age(self: *Person, age: u32) void {
        self.age = age;
    }

    pub fn _fullName(self: Person) []u8 {
        return self.last_name;
    }

    pub fn _setAgeMethod(self: *Person, age: u32) void {
        self.age = age;
    }

    pub fn get_symbol_toStringTag(_: Person) []const u8 {
        return "MyPerson";
    }
};

const User = struct {
    proto: Person,
    role: u8,

    pub const prototype = *Person;

    pub fn constructor(
        alloc: std.mem.Allocator,
        first_name: []u8,
        last_name: []u8,
        age: u32,
    ) User {
        const proto = Person.constructor(alloc, first_name, last_name, age);
        return .{ .proto = proto, .role = 1 };
    }

    pub fn get_role(self: User) u8 {
        return self.role;
    }
};

// generate API, comptime
pub fn generate() []jsruntime.API {
    return jsruntime.compile(.{ User, Person, Entity });
}

// exec tests
pub fn exec(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {

    // start JS env
    js_env.start();
    defer js_env.stop();

    // 1. constructor
    var cases1 = [_]tests.Case{
        .{ .src = "let p = new Person('Francis', 'Bouvier', 40);", .ex = "undefined" },
        .{ .src = "p.__proto__ === Person.prototype", .ex = "true" },
        .{ .src = "typeof(p.constructor) === 'function'", .ex = "true" },
        .{ .src = "p[Symbol.toStringTag] === 'MyPerson';", .ex = "true" }, // custom string tag
        .{ .src = "new Person('Francis', 40)", .ex = "TypeError" }, // arg is missing (last_name)
        .{ .src = "new Entity()", .ex = "TypeError" }, // illegal constructor
    };
    try tests.checkCases(js_env, &cases1);

    // 2. getter
    var cases2 = [_]tests.Case{
        .{ .src = "p.age === 40", .ex = "true" },
    };
    try tests.checkCases(js_env, &cases2);

    // 3. setter
    var cases3 = [_]tests.Case{
        .{ .src = "p.age = 41;", .ex = "41" },
        .{ .src = "p.age", .ex = "41" },
    };
    try tests.checkCases(js_env, &cases3);

    // 4. method
    var cases4 = [_]tests.Case{
        .{ .src = "p.fullName() === 'Bouvier';", .ex = "true" },
        .{ .src = "p.fullName('unused arg') === 'Bouvier';", .ex = "true" },
        .{ .src = "p.setAgeMethod(42); p.age", .ex = "42" },
    };
    try tests.checkCases(js_env, &cases4);

    // prototype chain
    var cases_proto = [_]tests.Case{
        .{ .src = "let u = new User('Francis', 'Englund', 42);", .ex = "undefined" },
        .{ .src = "u.__proto__ === User.prototype", .ex = "true" },
        .{ .src = "u.__proto__.__proto__ === Person.prototype", .ex = "true" },
        .{ .src = "u.fullName();", .ex = "Englund" },
        .{ .src = "u.age;", .ex = "42" },
        .{ .src = "u.age = 43;", .ex = "43" },
        .{ .src = "u.role = 2;", .ex = "2" },
        .{ .src = "u.age;", .ex = "43" },
    };
    try tests.checkCases(js_env, &cases_proto);
}
