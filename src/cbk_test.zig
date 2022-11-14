const std = @import("std");
const v8 = @import("v8");

const utils = @import("utils.zig");
const gen = @import("generate.zig");
const eng = @import("engine.zig");
const tests = @import("test_utils.zig");

const Window = struct {
    // value: u32,

    const Callback = @import("types.zig").Callback;
    const CallbackArg = @import("types.zig").CallbackArg;

    pub fn constructor(_: u32) Window {
        return Window{};
    }

    pub fn cbkSyncWithoutArg(_: Window, _: Callback) void {
        // TODO: handle async
        std.time.sleep(1 * std.time.ns_per_ms);
    }

    pub fn cbkSyncWithArg(_: Window, _: Callback, _: CallbackArg) void {
        // TODO: handle async
        std.time.sleep(1 * std.time.ns_per_ms);
    }
};

// generate API, comptime
pub fn generate() []gen.API {
    return gen.compile(.{Window});
}

// exec tests
pub fn exec(
    isolate: v8.Isolate,
    globals: v8.ObjectTemplate,
    tpls: []gen.ProtoTpl,
    comptime apis: []gen.API,
) !eng.ExecRes {

    // create v8 context
    var context = v8.Context.init(isolate, globals, null);
    context.enter();
    defer context.exit();

    // constructor
    const case_cstr = [_]tests.Case{
        .{ .src = "let window = new Window(0);", .ex = "undefined" },
    };
    try tests.checkCases(utils.allocator, isolate, context, case_cstr.len, case_cstr);

    // cbkSyncWithoutArg
    const cases_cbk_sync_without_arg = [_]tests.Case{
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
    try tests.checkCases(utils.allocator, isolate, context, cases_cbk_sync_without_arg.len, cases_cbk_sync_without_arg);

    // cbkSyncWithoutArg
    const cases_cbk_sync_with_arg = [_]tests.Case{
        // traditional anonymous function
        .{
            .src = 
            \\let x = 1;
            \\function f(a) {x = x + a};
            \\window.cbkSyncWithArg(f, 2);
            ,
            .ex = "undefined",
        },
        .{ .src = "x;", .ex = "3" },
        // arrow function
        .{
            .src = 
            \\let y = 1;
            \\window.cbkSyncWithArg((a) => y = y + a, 2);
            ,
            .ex = "undefined",
        },
        .{ .src = "y;", .ex = "3" },
    };
    try tests.checkCases(utils.allocator, isolate, context, cases_cbk_sync_with_arg.len, cases_cbk_sync_with_arg);

    return eng.ExecOK;
}
