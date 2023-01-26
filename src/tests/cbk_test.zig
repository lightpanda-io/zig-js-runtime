const std = @import("std");
const v8 = @import("v8");

const utils = @import("../utils.zig");
const gen = @import("../generate.zig");
const eng = @import("../engine.zig");
const Loop = @import("../loop.zig").SingleThreaded;

const u64Num = @import("../types.zig").u64Num;
const cbk = @import("../callback.zig");

const tests = @import("test_utils.zig");

const Console = @import("../console.zig").Console;

const Window = struct {
    pub fn constructor() Window {
        return Window{};
    }

    pub fn _cbkSyncWithoutArg(_: Window, _: cbk.FuncSync) void {
        tests.sleep(1 * std.time.ns_per_ms);
    }

    pub fn _cbkSyncWithArg(_: Window, _: cbk.FuncSync, _: cbk.Arg) void {
        tests.sleep(1 * std.time.ns_per_ms);
    }

    pub fn _cbkAsync(_: Window, loop: *Loop, callback: cbk.Func, milliseconds: u32) void {
        const n = @intCast(u63, milliseconds);
        // TODO: check this value can be holded in u63
        loop.timeout(n * std.time.ns_per_ms, callback);
    }

    pub fn _cbkAsyncWithArg(
        _: Window,
        loop: *Loop,
        callback: cbk.Func,
        milliseconds: u32,
        _: cbk.Arg,
    ) void {
        const n = @intCast(u63, milliseconds);
        // TODO: check this value can be holded in u63
        loop.timeout(n * std.time.ns_per_ms, callback);
    }
};

// generate API, comptime
pub fn generate() []gen.API {
    return gen.compile(.{ Console, Window });
}

// exec tests
pub fn exec(
    loop: *Loop,
    isolate: v8.Isolate,
    globals: v8.ObjectTemplate,
    tpls: []gen.ProtoTpl,
    comptime apis: []gen.API,
) !eng.ExecRes {

    // create v8 context
    var context = v8.Context.init(isolate, globals, null);
    context.enter();
    defer context.exit();

    // console
    const console = Console{};
    try eng.createV8Object(
        utils.allocator,
        apis[0].T_refl,
        console,
        tpls[0].tpl,
        context.getGlobal(),
        context,
        isolate,
    );

    // constructor
    const case_cstr = [_]tests.Case{
        .{ .src = "let window = new Window();", .ex = "undefined" },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, case_cstr.len, case_cstr);

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
    try tests.checkCases(loop, utils.allocator, isolate, context, cases_cbk_sync_without_arg.len, cases_cbk_sync_without_arg);

    // cbkSyncWithArg
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
    try tests.checkCases(loop, utils.allocator, isolate, context, cases_cbk_sync_with_arg.len, cases_cbk_sync_with_arg);

    // cbkAsync
    const cases_cbk_async = [_]tests.Case{
        // traditional anonymous function
        .{
            .src = 
            \\let o = 1;
            \\function f() {
            \\o++;
            \\if (o != 2) {throw Error('cases_cbk_async error: o is not equal to 2');}
            \\};
            \\window.cbkAsync(f, 300); // 0.3 second
            ,
            .ex = "undefined",
        },
        // arrow functional
        .{
            .src = 
            \\let p = 1;
            \\window.cbkAsync(() => {
            \\p++;
            \\if (p != 2) {throw Error('cases_cbk_async error: p is not equal to 2');}
            \\}, 300); // 0.3 second
            ,
            .ex = "undefined",
        },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases_cbk_async.len, cases_cbk_async);

    // cbkAsyncWithArg
    const cases_cbk_async_with_arg = [_]tests.Case{
        // traditional anonymous function
        .{
            .src = 
            \\let i = 1;
            \\function f(a) {
            \\i = i + a;
            \\if (i != 3) {throw Error('i is not equal to 3');}
            \\};
            \\window.cbkAsyncWithArg(f, 300, 2); // 0.3 second
            ,
            .ex = "undefined",
        },
        // arrow functional
        .{
            .src = 
            \\let j = 1;
            \\window.cbkAsyncWithArg((a) => {
            \\j = j + a;
            \\if (j != 3) {throw Error('j is not equal to 3');}
            \\}, 300, 2); // 0.3 second
            ,
            .ex = "undefined",
        },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases_cbk_async_with_arg.len, cases_cbk_async_with_arg);

    return eng.ExecOK;
}
