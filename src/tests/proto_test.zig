const std = @import("std");

const public = @import("../api.zig");
const tests = public.test_utils;

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

    // static attributes
    pub const _AGE_MIN = 18;
    pub const _NATIONALITY = "French";

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

    pub fn get_allocator(_: Person, alloc: std.mem.Allocator) !bool {
        const v = try alloc.alloc(u8, 10);
        defer alloc.free(v);

        return true;
    }

    pub fn set_allocator(_: *Person, _: std.mem.Allocator, _: bool) bool {
        return true;
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

    // TODO: should be a static function
    // see https://github.com/Browsercore/jsruntime-lib/issues/127
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

const PersonPtr = struct {
    name: []u8,

    pub fn constructor(alloc: std.mem.Allocator, name: []u8) *PersonPtr {
        var person_ptr = alloc.create(PersonPtr) catch unreachable;
        person_ptr.* = .{ .name = name };
        return person_ptr;
    }

    pub fn get_name(self: PersonPtr) []u8 {
        return self.name;
    }

    pub fn set_name(self: *PersonPtr, name: []u8) void {
        self.name = name;
    }
};

const UserForContainer = struct {
    proto: Person,
    role: u8,

    pub const prototype = *Person;

    pub fn constructor(
        alloc: std.mem.Allocator,
        first_name: []u8,
        last_name: []u8,
        age: u32,
    ) UserForContainer {
        const proto = Person.constructor(alloc, first_name, last_name, age);
        return .{ .proto = proto, .role = 1 };
    }

    pub fn get_role(self: UserForContainer) u8 {
        return self.role;
    }
};

const UserContainer = struct {
    pub const Self = UserForContainer;
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

    pub fn get_role_container(self: UserForContainer) u8 {
        return self.role;
    }

    pub fn set_role_container(self: *UserForContainer, role: u8) void {
        self.role = role;
    }

    pub fn _roleVal(self: UserForContainer) u8 {
        return self.role;
    }
};

const PersonProtoCast = struct {
    first_name: []const u8,

    pub fn protoCast(child_ptr: anytype) *PersonProtoCast {
        return @ptrCast(child_ptr);
    }

    pub fn constructor(first_name: []u8) PersonProtoCast {
        return .{ .first_name = first_name };
    }

    pub fn get_name(self: PersonProtoCast) []const u8 {
        return self.first_name;
    }
};

const UserProtoCast = struct {
    not_proto: PersonProtoCast,

    pub const prototype = *PersonProtoCast;

    pub fn constructor(first_name: []u8) UserProtoCast {
        return .{ .not_proto = PersonProtoCast.constructor(first_name) };
    }
};

// generate API, comptime
pub fn generate() ![]public.API {
    return try public.compile(.{
        User,
        Person,
        PersonPtr,
        Entity,
        UserContainer,
        PersonProtoCast,
        UserProtoCast,
    });
}

// exec tests
pub fn exec(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
    comptime apis: []public.API,
) !void {

    // start JS env
    js_env.start(apis);
    defer js_env.stop();

    const ownBase = switch (public.Env.engine()) {
        .v8 => 5,
    };
    const ownBaseLen = intToStr(alloc, ownBase);
    defer alloc.free(ownBaseLen);

    // global
    try js_env.attachObject(try js_env.getGlobal(), "self", null);

    var global = [_]tests.Case{
        .{ .src = "self.foo = function() {} !== undefined", .ex = "true" },
        .{ .src = "foo !== undefined", .ex = "true" },
        .{ .src = "self.foo === foo", .ex = "true" },
        .{ .src = "var bar = function() {}", .ex = "undefined" },
        .{ .src = "self.bar !== undefined", .ex = "true" },
        .{ .src = "self.bar === bar", .ex = "true" },
        .{ .src = "let not_self = 0", .ex = "undefined" },
        .{ .src = "self.not_self === undefined", .ex = "true" },
    };
    try tests.checkCases(js_env, &global);

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
        .{ .src = "p.allocator", .ex = "true" },
    };
    try tests.checkCases(js_env, &cases2);

    // 3. setter
    var cases3 = [_]tests.Case{
        .{ .src = "p.age = 41;", .ex = "41" },
        .{ .src = "p.age", .ex = "41" },
        .{ .src = "p.allocator = true", .ex = "true" },
    };
    try tests.checkCases(js_env, &cases3);

    // 4. method
    var cases4 = [_]tests.Case{
        .{ .src = "p.fullName() === 'Bouvier';", .ex = "true" },
        .{ .src = "p.fullName('unused arg') === 'Bouvier';", .ex = "true" },
        .{ .src = "p.setAgeMethod(42); p.age", .ex = "42" },
    };
    try tests.checkCases(js_env, &cases4);

    // static attr
    const ownPersonLen = intToStr(alloc, ownBase + 2);
    defer alloc.free(ownPersonLen);
    var cases_static = [_]tests.Case{
        // basic static case
        .{ .src = "Person.AGE_MIN === 18", .ex = "true" },
        .{ .src = "Person.NATIONALITY === 'French'", .ex = "true" },
        // static attributes are own properties
        .{ .src = "let ownPerson = Object.getOwnPropertyNames(Person)", .ex = "undefined" },
        .{ .src = "ownPerson.length", .ex = ownPersonLen },
        // static attributes are also available on instances
        .{ .src = "p.AGE_MIN === 18", .ex = "true" },
        .{ .src = "p.NATIONALITY === 'French'", .ex = "true" },
    };
    try tests.checkCases(js_env, &cases_static);

    // prototype chain, constructor level
    var cases_proto_constructor = [_]tests.Case{
        // template level (load) FunctionTemplate.inherit
        .{ .src = "User.prototype.__proto__ === Person.prototype", .ex = "true" },
        // object level (context started) FunctionTemplate.getFunction.setPrototype
        .{ .src = "User.__proto__ === Person", .ex = "true" },
        // static attributes inherited on constructor
        .{ .src = "User.AGE_MIN === 18", .ex = "true" },
        .{ .src = "User.NATIONALITY === 'French'", .ex = "true" },
        // static attributes inherited are NOT own properties
        .{ .src = "let ownUser = Object.getOwnPropertyNames(User)", .ex = "undefined" },
        .{ .src = "ownUser.length", .ex = ownBaseLen },
    };
    try tests.checkCases(js_env, &cases_proto_constructor);

    // prototype chain, instance level
    var cases_proto_instance = [_]tests.Case{
        .{ .src = "let u = new User('Francis', 'Englund', 42);", .ex = "undefined" },
        .{ .src = "u.__proto__ === User.prototype", .ex = "true" },
        .{ .src = "u.__proto__.__proto__ === Person.prototype", .ex = "true" },
        .{ .src = "u[Symbol.toStringTag] === 'User';", .ex = "true" }, // generic string tag
        .{ .src = "u.fullName();", .ex = "Englund" },
        .{ .src = "u.age;", .ex = "42" },
        .{ .src = "u.age = 43;", .ex = "43" },
        .{ .src = "u.role = 2;", .ex = "2" },
        .{ .src = "u.age;", .ex = "43" },
        // static attributes inherited are also available on instances
        .{ .src = "u.AGE_MIN === 18", .ex = "true" },
        .{ .src = "u.NATIONALITY === 'French'", .ex = "true" },
    };
    try tests.checkCases(js_env, &cases_proto_instance);

    // constructor returning pointer
    var casesPtr = [_]tests.Case{
        .{ .src = "let pptr = new PersonPtr('Francis');", .ex = "undefined" },
        .{ .src = "pptr.name = 'Bouvier'; pptr.name === 'Bouvier'", .ex = "true" },
    };
    try tests.checkCases(js_env, &casesPtr);

    // container
    var casesContainer = [_]tests.Case{
        .{ .src = "let uc = new UserContainer('Francis', 'Bouvier', 40);", .ex = "undefined" },
        .{ .src = "uc.role_container === 1", .ex = "true" },
        .{ .src = "uc.role_container = 2; uc.role_container === 2", .ex = "true" },
        .{ .src = "uc.roleVal() === 2", .ex = "true" },
        .{ .src = "uc.age === 40", .ex = "true" },
    };
    try tests.checkCases(js_env, &casesContainer);

    // protoCast func
    var casesProtoCast = [_]tests.Case{
        .{ .src = "let ppc = new PersonProtoCast('Bouvier');", .ex = "undefined" },
        .{ .src = "ppc.name === 'Bouvier'", .ex = "true" },
        .{ .src = "let upc = new UserProtoCast('Francis');", .ex = "undefined" },
        .{ .src = "upc.name === 'Francis'", .ex = "true" },
    };
    try tests.checkCases(js_env, &casesProtoCast);
}

fn intToStr(alloc: std.mem.Allocator, nb: u8) []const u8 {
    return std.fmt.allocPrint(
        alloc,
        "{d}",
        .{nb},
    ) catch unreachable;
}
