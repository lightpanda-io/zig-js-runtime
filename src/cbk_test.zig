const std = @import("std");
const v8 = @import("v8");

const utils = @import("utils.zig");
const gen = @import("generate.zig");
const eng = @import("engine.zig");
const tests = @import("test_utils.zig");

const Window = struct {
    // value: u32,

    const Callback = @import("types.zig").Callback;

    pub fn constructor(_: u32) Window {
        return Window{};
    }

    pub fn cbkSyncWithoutArg(_: Window, _: Callback) void {
        // TODO: handle async
        std.time.sleep(1 * std.time.ns_per_ms);
    }
};

// generate API, comptime
pub fn generate() []gen.API {
    return gen.compile(.{Window});
}

// exec tests
pub fn exec(isolate: v8.Isolate, globals: v8.ObjectTemplate) !eng.ExecRes {

    // create v8 context
    var context = v8.Context.init(isolate, globals, null);
    context.enter();
    defer context.exit();

    // constructor
    const case_cstr = [_]tests.Case{
        .{ .src = "let window = new Window(0);", .ex = "undefined" },
    };
    try tests.checkCases(utils.allocator, isolate, context, case_cstr.len, case_cstr);

    // cbkAnonymous
    const case_cbk_anonymous = [_]tests.Case{
        // traditional anonymous function
        .{
            .src = 
            \\let n = 1;
            \\function f() {n++};
            \\window.cbkSyncWithoutArg(f);
            ,
            .ex = "undefined",
        },
        .{ .src = "n;", .ex = "2" },
        // arrow function
        .{
            .src = 
            \\let m = 1;
            \\window.cbkSyncWithoutArg(() => m++);
            ,
            .ex = "undefined",
        },
        .{ .src = "m;", .ex = "2" },
    };
    try tests.checkCases(utils.allocator, isolate, context, case_cbk_anonymous.len, case_cbk_anonymous);

    return eng.ExecOK;
}
