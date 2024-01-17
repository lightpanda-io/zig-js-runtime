const std = @import("std");

const jsruntime = @import("../api.zig");

const u64Num = jsruntime.u64Num;
const Callback = jsruntime.Callback;
const CallbackSync = jsruntime.CallbackSync;
const CallbackArg = jsruntime.CallbackArg;

const tests = jsruntime.test_utils;

pub const OtherCbk = struct {
    val: u8,

    pub fn get_val(self: OtherCbk) u8 {
        return self.val;
    }
};

pub const Window = struct {
    pub fn constructor() Window {
        return Window{};
    }

    pub fn _cbkSyncWithoutArg(_: Window, _: CallbackSync) void {
        tests.sleep(1 * std.time.ns_per_ms);
    }

    pub fn _cbkSyncWithArg(_: Window, _: CallbackSync, _: CallbackArg) void {
        tests.sleep(1 * std.time.ns_per_ms);
    }

    pub fn _cbkAsync(
        _: Window,
        loop: *jsruntime.Loop,
        callback: Callback,
        milliseconds: u32,
    ) void {
        const n: u63 = @intCast(milliseconds);
        // TODO: check this value can be holded in u63
        loop.timeout(n * std.time.ns_per_ms, callback);
    }

    pub fn _cbkAsyncWithJSArg(
        _: Window,
        loop: *jsruntime.Loop,
        callback: Callback,
        milliseconds: u32,
        _: CallbackArg,
    ) void {
        const n: u63 = @intCast(milliseconds);
        // TODO: check this value can be holded in u63
        loop.timeout(n * std.time.ns_per_ms, callback);
    }

    pub fn _cbkAsyncWithNatArg(_: Window, callback: Callback) !void {
        const other = OtherCbk{ .val = 5 };
        callback.call(.{other}) catch {};
        // ignore the error to let the JS msg
    }

    pub fn deinit(_: *Window, _: std.mem.Allocator) void {}
};

pub const Types = .{
    OtherCbk,
    Window,
};

// exec tests
pub fn exec(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {

    // start JS env
    try js_env.start(alloc);
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

    // cbkAsyncWithJSArg
    var cases_cbk_async_with_js_arg = [_]tests.Case{
        // traditional anonymous function
        .{
            .src =
            \\let i = 1;
            \\function f(a) {
            \\i = i + a;
            \\if (i != 3) {throw Error('i is not equal to 3');}
            \\};
            \\window.cbkAsyncWithJSArg(f, 100, 2); // 0.1 second
            ,
            .ex = "undefined",
        },
        // arrow functional
        .{
            .src =
            \\let j = 1;
            \\window.cbkAsyncWithJSArg((a) => {
            \\j = j + a;
            \\if (j != 3) {throw Error('j is not equal to 3');}
            \\}, 100, 2); // 0.1 second
            ,
            .ex = "undefined",
        },
    };
    try tests.checkCases(js_env, &cases_cbk_async_with_js_arg);

    // cbkAsyncWithNatArg
    var cases_cbk_async_with_nat_arg = [_]tests.Case{
        .{ .src = "let exp = 5", .ex = "undefined" },

        // traditional anonymous function
        .{
            .src =
            \\function f(other) {
            \\if (other.val != exp) {throw Error('other.val expected ' + exp + ', got ' + other.val);}
            \\};
            \\window.cbkAsyncWithNatArg(f);
            ,
            .ex = "undefined",
        },
        // arrow functional
        .{
            .src =
            \\window.cbkAsyncWithNatArg((other) => {
            \\if (other.val != exp) {throw Error('other.val expected ' + exp + ', got ' + other.val);}
            \\});
            ,
            .ex = "undefined",
        },
    };
    try tests.checkCases(js_env, &cases_cbk_async_with_nat_arg);
}
