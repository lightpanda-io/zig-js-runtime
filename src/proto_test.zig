const std = @import("std");
const v8 = @import("v8");

const utils = @import("utils.zig");
const gen = @import("generate.zig");
const eng = @import("engine.zig");
const Loop = @import("loop.zig").SingleThreaded;

const tests = @import("test_utils.zig");

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

    pub fn constructor(first_name: []u8, last_name: []u8, age: u32) Person {
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
};

const User = struct {
    proto: Person,
    role: u8,

    pub const prototype = *Person;

    pub fn constructor(first_name: []u8, last_name: []u8, age: u32) User {
        const proto = Person.constructor(first_name, last_name, age);
        return .{ .proto = proto, .role = 1 };
    }

    pub fn get_role(self: User) u8 {
        return self.role;
    }
};

// generate API, comptime
pub fn generate() []gen.API {
    return gen.compile(.{ User, Person, Entity });
}

// exec tests
pub fn exec(
    loop: *Loop,
    isolate: v8.Isolate,
    globals: v8.ObjectTemplate,
    _: []gen.ProtoTpl,
    comptime _: []gen.API,
) !eng.ExecRes {

    // create v8 context
    var context = v8.Context.init(isolate, globals, null);
    context.enter();
    defer context.exit();

    // 1. constructor
    const cases1 = [_]tests.Case{
        .{ .src = "let p = new Person('Francis', 'Bouvier', 40);", .ex = "undefined" },
        .{ .src = "p.__proto__ === Person.prototype", .ex = "true" },
        .{ .src = "typeof(p.constructor) === 'function'", .ex = "true" },
        .{ .src = "new Person('Francis', 40)", .ex = "TypeError" }, // arg is missing (last_name)
        .{ .src = "new Entity()", .ex = "TypeError" }, // illegal constructor
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases1.len, cases1);

    // 2. getter
    const cases2 = [_]tests.Case{
        .{ .src = "p.age === 40", .ex = "true" },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases2.len, cases2);

    // 3. setter
    const cases3 = [_]tests.Case{
        .{ .src = "p.age = 41;", .ex = "41" },
        .{ .src = "p.age", .ex = "41" },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases3.len, cases3);

    // 4. method
    const cases4 = [_]tests.Case{
        .{ .src = "p.fullName() === 'Bouvier';", .ex = "true" },
        .{ .src = "p.fullName('unused arg') === 'Bouvier';", .ex = "true" },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases4.len, cases4);

    // prototype chain
    const cases_proto = [_]tests.Case{
        .{ .src = "let u = new User('Francis', 'Englund', 42);", .ex = "undefined" },
        .{ .src = "u.__proto__ === User.prototype", .ex = "true" },
        .{ .src = "u.__proto__.__proto__ === Person.prototype", .ex = "true" },
        .{ .src = "u.fullName();", .ex = "Englund" },
        .{ .src = "u.age;", .ex = "42" },
        .{ .src = "u.age = 43;", .ex = "43" },
        .{ .src = "u.role = 2;", .ex = "2" },
        .{ .src = "u.age;", .ex = "43" },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases_proto.len, cases_proto);
    return eng.ExecOK;
}
