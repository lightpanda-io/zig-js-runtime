const std = @import("std");
const v8 = @import("v8");
const engine = @import("engine.zig");
const utils = @import("utils.zig");
const Store = @import("store.zig");
const reflect = @import("reflect.zig");
const generate = @import("generate.zig");
const data = @import("data.zig");

fn isTypeError(expected: []const u8, msg: []const u8) bool {
    if (!std.mem.eql(u8, expected, "TypeError")) {
        return false;
    }
    return std.mem.startsWith(u8, msg, "Uncaught TypeError: ");
}

fn checkCases(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, comptime n: comptime_int, cases: [n]Case) !void {
    var has_error = false;
    for (cases) |case, i| {
        const res = engine.jsExecScript(alloc, isolate, context, case.src, "test.js");
        defer res.deinit();
        var case_error = false;
        if (res.success) {
            const equal = std.mem.eql(u8, case.ex, res.result);
            if (!equal) {
                case_error = true;
            }
        } else {
            if (!isTypeError(case.ex, res.result)) {
                case_error = true;
            }
        }
        if (case_error) {
            if (!has_error) {
                has_error = true;
            }
            if (i == 0) {
                std.debug.print("\n", .{});
            }
            std.debug.print("\n\tcase: ", .{});
            std.debug.print("\t\t{s}\n", .{case.src});
            std.debug.print("\texpected: ", .{});
            std.debug.print("\t{s}\n", .{case.ex});
            std.debug.print("\tactual: ", .{});
            std.debug.print("\t{s}\n", .{res.result});
        }
    }
    if (has_error) {
        std.debug.print("\n", .{});
        return error.NotEqual;
    }
}

const Case = struct {
    src: []const u8,
    ex: []const u8,
};

test "proto" {

    // generate API
    const person_refl = comptime reflect.Struct(data.Person);
    const person_api = comptime generate.API(data.Person, person_refl);

    const entity_refl = comptime reflect.Struct(data.Entity);
    const entity_api = comptime generate.API(data.Entity, entity_refl);

    // allocator
    utils.allocator = std.testing.allocator;

    // store
    Store.default = Store.init(utils.allocator);
    defer Store.default.deinit(utils.allocator);

    // create v8 vm
    const vm = engine.VM.init();
    defer vm.deinit();

    // create v8 isolate
    const iso = engine.Isolate.init(utils.allocator);
    defer iso.deinit(utils.allocator);
    const isolate = iso.isolate;

    // create a v8 ObjectTemplate for the global namespace
    const globals = v8.ObjectTemplate.initDefault(isolate);

    // load API, before creating context
    person_api.load(isolate, globals);
    entity_api.load(isolate, globals);

    // create v8 context
    const context = iso.initContext(globals);
    defer iso.deinitContext(context);

    // 1. constructor
    const cases1 = [_]Case{
        .{ .src = "let p = new Person('Francis', 'Bouvier', 40);", .ex = "undefined" },
        .{ .src = "p.__proto__ === Person.prototype", .ex = "true" },
        .{ .src = "typeof(p.constructor) === 'function'", .ex = "true" },
        .{ .src = "new Person('Francis', 40)", .ex = "TypeError" }, // arg is missing (last_name)
        .{ .src = "new Entity()", .ex = "TypeError" }, // illegal constructor
    };
    try checkCases(utils.allocator, isolate, context, cases1.len, cases1);

    // 2. getter
    const cases2 = [_]Case{
        .{ .src = "p.age === 40", .ex = "true" },
    };
    try checkCases(utils.allocator, isolate, context, cases2.len, cases2);

    // 3. setter
    const cases3 = [_]Case{
        .{ .src = "p.age = 41;", .ex = "41" },
        .{ .src = "p.age === 41", .ex = "true" },
    };
    try checkCases(utils.allocator, isolate, context, cases3.len, cases3);

    // 4. method
    const cases4 = [_]Case{
        .{ .src = "p.fullName() === 'Bouvier';", .ex = "true" },
    };
    try checkCases(utils.allocator, isolate, context, cases4.len, cases4);
}
