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

    pub fn constructor(alloc: std.mem.Allocator, first_name: []u8, last_name: []u8, age: u32) Person {

        // alloc last_name slice to keep them after function returns
        // NOTE: we do not alloc first_name on purpose to check freeArgs
        const last_name_alloc = alloc.alloc(u8, last_name.len) catch unreachable;
        @memcpy(last_name_alloc, last_name);

        return .{
            .first_name = first_name,
            .last_name = last_name_alloc,
            .age = age,
        };
    }

    pub fn get_age(self: Person) u32 {
        return self.age;
    }

    fn allocTest(alloc: std.mem.Allocator) !void {
        const v = try alloc.alloc(u8, 10);
        defer alloc.free(v);
    }

    pub fn get_allocator(_: Person, alloc: std.mem.Allocator) !bool {
        try Person.allocTest(alloc);
        return true;
    }

    pub fn get_UPPER(_: Person) bool {
        return true;
    }

    pub fn _UPPERMETHOD(_: Person) bool {
        return true;
    }

    pub fn set_allocator(_: *Person, alloc: std.mem.Allocator, _: bool) void {
        Person.allocTest(alloc) catch unreachable;
    }

    pub fn get_nonAllocFirstName(self: Person) []const u8 {
        return self.first_name;
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

    pub fn _say(_: *Person, _: ?[]const u8) void {}

    // TODO: should be a static function
    // see https://github.com/Browsercore/jsruntime-lib/issues/127
    pub fn get_symbol_toStringTag(_: Person) []const u8 {
        return "MyPerson";
    }

    pub fn deinit(self: *Person, alloc: std.mem.Allocator) void {
        alloc.free(self.last_name);
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

    pub fn deinit(self: *User, alloc: std.mem.Allocator) void {
        self.proto.deinit(alloc);
    }
};

const PersonPtr = struct {
    name: []u8,

    pub fn constructor(alloc: std.mem.Allocator, name: []u8) *PersonPtr {
        const name_alloc = alloc.alloc(u8, name.len) catch unreachable;
        @memcpy(name_alloc, name);

        const person_ptr = alloc.create(PersonPtr) catch unreachable;
        person_ptr.* = .{ .name = name_alloc };
        return person_ptr;
    }

    pub fn get_name(self: PersonPtr) []u8 {
        return self.name;
    }

    pub fn set_name(self: *PersonPtr, alloc: std.mem.Allocator, name: []u8) void {
        const name_alloc = alloc.alloc(u8, name.len) catch unreachable;
        @memcpy(name_alloc, name);
        self.name = name_alloc;
    }

    pub fn deinit(self: *PersonPtr, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
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

    pub fn deinit(self: *UserForContainer, alloc: std.mem.Allocator) void {
        self.proto.deinit(alloc);
    }
};

const PersonProtoCast = struct {
    first_name: []const u8,

    pub fn protoCast(child_ptr: anytype) *PersonProtoCast {
        return @ptrCast(child_ptr);
    }

    pub fn constructor(alloc: std.mem.Allocator, first_name: []u8) PersonProtoCast {
        const first_name_alloc = alloc.alloc(u8, first_name.len) catch unreachable;
        @memcpy(first_name_alloc, first_name);
        return .{ .first_name = first_name_alloc };
    }

    pub fn get_name(self: PersonProtoCast) []const u8 {
        return self.first_name;
    }

    pub fn deinit(self: *PersonProtoCast, alloc: std.mem.Allocator) void {
        alloc.free(self.first_name);
    }
};

const UserProtoCast = struct {
    not_proto: PersonProtoCast,

    pub const prototype = *PersonProtoCast;

    pub fn constructor(alloc: std.mem.Allocator, first_name: []u8) UserProtoCast {
        return .{ .not_proto = PersonProtoCast.constructor(alloc, first_name) };
    }

    pub fn deinit(self: *UserProtoCast, alloc: std.mem.Allocator) void {
        self.not_proto.deinit(alloc);
    }
};

pub const Types = .{
    User,
    Person,
    PersonPtr,
    Entity,
    UserContainer,
    PersonProtoCast,
    UserProtoCast,
};

// exec tests
pub fn exec(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
) anyerror!void {

    // start JS env
    try js_env.start(alloc);
    defer js_env.stop();

    const ownBase = tests.engineOwnPropertiesDefault();
    const ownBaseStr = tests.intToStr(alloc, ownBase);
    defer alloc.free(ownBaseStr);

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
        .{ .src = "p.UPPER", .ex = "true" },
        .{ .src = "p.UPPERMETHOD()", .ex = "true" },
        // first name has not been allocated, so it's a normal behavior
        // here we check that freeArgs works well
        .{ .src = "p.nonAllocFirstName !== 'Francis'", .ex = "true" },
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
    const ownPersonStr = intToStr(alloc, ownBase + 2);
    defer alloc.free(ownPersonStr);
    var cases_static = [_]tests.Case{
        // basic static case
        .{ .src = "Person.AGE_MIN === 18", .ex = "true" },
        .{ .src = "Person.NATIONALITY === 'French'", .ex = "true" },
        // static attributes are own properties
        .{ .src = "let ownPerson = Object.getOwnPropertyNames(Person)", .ex = "undefined" },
        .{ .src = "ownPerson.length", .ex = ownPersonStr },
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
        .{ .src = "ownUser.length", .ex = ownBaseStr },
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

    // free func arguments
    var casesFreeArguments = [_]tests.Case{
        .{ .src = "let dt = new Person('Deep', 'Thought', 7500000);", .ex = "undefined" },
        .{ .src = "dt.say('42')", .ex = "undefined" },
        .{ .src = "dt.say(null)", .ex = "undefined" },
    };
    try tests.checkCases(js_env, &casesFreeArguments);
}

fn intToStr(alloc: std.mem.Allocator, nb: u8) []const u8 {
    return std.fmt.allocPrint(
        alloc,
        "{d}",
        .{nb},
    ) catch unreachable;
}
