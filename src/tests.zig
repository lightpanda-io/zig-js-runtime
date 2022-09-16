const std = @import("std");
const v8 = @import("v8");
const engine = @import("engine.zig");
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

fn checkEqualCases(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, comptime n: comptime_int, cases: [n][]const u8) !void {
    var isErr = false;
    for (cases) |case| {
        var res_case = try engine.jsExecScript(alloc, isolate, context, case, "test.js");
        defer res_case.deinit();
        const equal = expectStringsEquals("true", res_case.result.?, case, !isErr);
        if (!equal and !isErr) {
            isErr = true;
        }
    }
    if (isErr) {
        std.debug.print("\n", .{});
        return error.NotEqual;
    }
}

test "proto" {
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
    data.loadAPI(isolate, globals);

    // create v8 context
    var context = iso.initContext(globals);
    defer iso.deinitContext(context);

    // 1. constructor and getter
    const script =
        \\let p = new Person(40);
    ;
    var res = try engine.jsExecScript(alloc, isolate, context, script, "test.js");
    defer res.deinit();
    try assertStringsEquals("undefined", res.result.?, script);

    // equlaity cases
    const cases = [_][]const u8{
        "p.age === 40",
        "p.__proto__ === Person.prototype",
        "typeof(p.constructor) === 'function'",
    };
    try checkEqualCases(alloc, isolate, context, cases.len, cases);
}
