const std = @import("std");

const jsruntime = @import("../jsruntime.zig");

const u64Num = @import("../types.zig").u64Num;
const cbk = @import("../callback.zig");

const tests = jsruntime.test_utils;

pub const Window = struct {
    pub fn constructor() Window {
        return Window{};
    }

    pub fn _cbkSyncWithoutArg(_: Window, _: cbk.FuncSync) void {
        tests.sleep(1 * std.time.ns_per_ms);
    }

    pub fn _cbkSyncWithArg(_: Window, _: cbk.FuncSync, _: cbk.Arg) void {
        tests.sleep(1 * std.time.ns_per_ms);
    }

    pub fn _cbkAsync(
        _: Window,
        loop: *jsruntime.Loop,
        callback: cbk.Func,
        milliseconds: u32,
    ) void {
        const n = @intCast(u63, milliseconds);
        // TODO: check this value can be holded in u63
        loop.timeout(n * std.time.ns_per_ms, callback);
    }

    pub fn _cbkAsyncWithArg(
        _: Window,
        loop: *jsruntime.Loop,
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
pub fn generate() []jsruntime.API {
    return jsruntime.compile(.{Window});
}

// exec tests
pub fn exec(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {

    // start JS env
    js_env.start();
    defer js_env.stop();

    // constructor
    var case_cstr = [_]tests.Case{
        .{ .src = "let window = new Window();", .ex = "undefined" },
    };
    try tests.checkCases(js_env, &case_cstr);

    // cbkSyncWithoutArg
    var cases_cbk_sync_without_arg = [_]tests.Case{
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
    try tests.checkCases(js_env, &cases_cbk_sync_without_arg);

    // cbkSyncWithArg
    var cases_cbk_sync_with_arg = [_]tests.Case{
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
    try tests.checkCases(js_env, &cases_cbk_sync_with_arg);

    // cbkAsync
    var cases_cbk_async = [_]tests.Case{
        // traditional anonymous function
        .{
            .src = 
            \\let o = 1;
            \\function f() {
            \\o++;
            \\if (o != 2) {throw Error('cases_cbk_async error: o is not equal to 2');}
            \\};
            \\window.cbkAsync(f, 100); // 0.1 second
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
            \\}, 100); // 0.1 second
            ,
            .ex = "undefined",
        },
    };
    try tests.checkCases(js_env, &cases_cbk_async);

    // cbkAsyncWithArg
    var cases_cbk_async_with_arg = [_]tests.Case{
        // traditional anonymous function
        .{
            .src = 
            \\let i = 1;
            \\function f(a) {
            \\i = i + a;
            \\if (i != 3) {throw Error('i is not equal to 3');}
            \\};
            \\window.cbkAsyncWithArg(f, 100, 2); // 0.1 second
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
            \\}, 100, 2); // 0.1 second
            ,
            .ex = "undefined",
        },
    };
    try tests.checkCases(js_env, &cases_cbk_async_with_arg);
}
