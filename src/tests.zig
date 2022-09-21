const std = @import("std");
const v8 = @import("v8");
const engine = @import("engine.zig");
const refl = @import("reflect.zig");
const gen = @import("generate.zig");
const data = @import("data.zig");

fn expectStringsEquals(expected: []const u8, actual: []const u8, case: []const u8, first: bool) bool {
    const equal = std.mem.eql(u8, expected, actual);
    if (!equal) {
        if (first) {
            std.debug.print("\n", .{});
        }
        std.debug.print("\n\tcase: ", .{});
        std.debug.print("\t\t{s}\n", .{case});
        std.debug.print("\texpected: ", .{});
        std.debug.print("\t{s}\n", .{expected});
        std.debug.print("\tactual: ", .{});
        std.debug.print("\t{s}\n", .{actual});
    }
    return equal;
}

fn assertStringsEquals(expected: []const u8, actual: []const u8, case: []const u8) !void {
    const equal = expectStringsEquals(expected, actual, case, true);
    if (!equal) {
        return error.NotEqual;
    }
}

fn checkCases(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, comptime n: comptime_int, cases: [n]Expected) !void {
    var isErr = false;
    for (cases) |case| {
        var res_case = try engine.jsExecScript(alloc, isolate, context, case.script, "test.js");
        defer res_case.deinit();
        const equal = expectStringsEquals(case.expected, res_case.result.?, case.script, !isErr);
        if (!equal and !isErr) {
            isErr = true;
        }
    }
    if (isErr) {
        std.debug.print("\n", .{});
        return error.NotEqual;
    }
}

const Expected = struct {
    script: []const u8,
    expected: []const u8,
};

test "proto" {
    const person_refl = comptime refl.reflectStruct(data.Person);
    const person_api = comptime gen.generateAPI(data.Person, person_refl);

    // allocator
    const alloc = std.testing.allocator;

    // create v8 vm
    var vm = engine.VM.init();
    defer vm.deinit();

    // create v8 isolate
    var iso = engine.Isolate.init(alloc);
    defer iso.deinit(alloc);
    var isolate = iso.isolate;

    // create a v8 ObjectTemplate for the global namespace
    var globals = v8.ObjectTemplate.initDefault(isolate);

    // load API, before creating context
    person_api.load(isolate, globals);

    // create v8 context
    var context = iso.initContext(globals);
    defer iso.deinitContext(context);

    // 1. constructor
    const cases1 = [_]Expected{
        .{ .script = "let p = new Person(40);", .expected = "undefined" },
        .{ .script = "p.__proto__ === Person.prototype", .expected = "true" },
        .{ .script = "typeof(p.constructor) === 'function'", .expected = "true" },
    };
    try checkCases(alloc, isolate, context, cases1.len, cases1);

    // 2. getter
    const cases2 = [_]Expected{
        .{ .script = "p.age === 40", .expected = "true" },
    };
    try checkCases(alloc, isolate, context, cases2.len, cases2);

    // 3. setter
    const cases3 = [_]Expected{
        .{ .script = "p.age = 41;", .expected = "41" },
        .{ .script = "p.age === 41", .expected = "true" },
    };
    try checkCases(alloc, isolate, context, cases3.len, cases3);

    // 4. method
    const cases4 = [_]Expected{
        .{ .script = "p.otherAge(10) === 41;", .expected = "true" },
    };
    try checkCases(alloc, isolate, context, cases4.len, cases4);
}
