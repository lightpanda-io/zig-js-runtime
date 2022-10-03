const std = @import("std");
const v8 = @import("v8");

const engine = @import("engine.zig");
const utils = @import("utils.zig");
const Store = @import("store.zig");
const refl = @import("reflect.zig");
const gen = @import("generate.zig");

// TODO: handle memory allocation in the data struct itself.
// Each struct should have a deinit method to free internal memory and destroy object itself.
// Each setter should accept an alloc arg in order to free pre-existing internal allocation.
// Each method should accept an alloc arg in order to handle internal allocation (alloc or free).
// Is it worth it with an Arena like allocator?
// see the balance between memory size and cost of free

pub const Entity = struct {};

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

pub fn doTest(isolate: v8.Isolate) !void {
    const tests = @import("test_utils.zig");

    // generate API
    const person_refl = comptime refl.AsStruct(Person);
    const person_api = comptime gen.API(Person, person_refl);

    const entity_refl = comptime refl.AsStruct(Entity);
    const entity_api = comptime gen.API(Entity, entity_refl);

    // create a v8 ObjectTemplate for the global namespace
    const globals = v8.ObjectTemplate.initDefault(isolate);

    // load API, before creating context
    person_api.load(isolate, globals);
    entity_api.load(isolate, globals);

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
    try tests.checkCases(utils.allocator, isolate, context, cases1.len, cases1);

    // 2. getter
    const cases2 = [_]tests.Case{
        .{ .src = "p.age === 40", .ex = "true" },
    };
    try tests.checkCases(utils.allocator, isolate, context, cases2.len, cases2);

    // 3. setter
    const cases3 = [_]tests.Case{
        .{ .src = "p.age = 41;", .ex = "41" },
        .{ .src = "p.age === 41", .ex = "true" },
    };
    try tests.checkCases(utils.allocator, isolate, context, cases3.len, cases3);

    // 4. method
    const cases4 = [_]tests.Case{
        .{ .src = "p.fullName() === 'Bouvier';", .ex = "true" },
        .{ .src = "p.fullName('unused arg') === 'Bouvier';", .ex = "true" },
    };
    try tests.checkCases(utils.allocator, isolate, context, cases4.len, cases4);
}
