const std = @import("std");

const public = @import("../api.zig");
const tests = public.test_utils;

const GlobalParent = struct {
    pub fn _parent(_: GlobalParent) bool {
        return true;
    }
};

pub const Global = struct {
    pub const prototype = *GlobalParent;
    pub const global_type = true;

    proto: GlobalParent = .{},

    pub fn _self(_: Global) bool {
        return true;
    }
};

pub const Types = .{
    GlobalParent,
    Global,
};

// exec tests
pub fn exec(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
) anyerror!void {

    // start JS env
    try js_env.start(alloc);
    defer js_env.stop();

    // global
    const global = Global{};
    try js_env.bindGlobal(global);
    try js_env.attachObject(try js_env.getGlobal(), "global", null);

    var globals = [_]tests.Case{
        .{ .src = "Global.name", .ex = "Global" },
        .{ .src = "GlobalParent.name", .ex = "GlobalParent" },
        .{ .src = "self()", .ex = "true" },
        .{ .src = "parent()", .ex = "true" },
        .{ .src = "global.self()", .ex = "true" },
        .{ .src = "global.parent()", .ex = "true" },
        .{ .src = "global.foo = () => true; foo()", .ex = "true" },
        .{ .src = "bar = () => true; global.bar()", .ex = "true" },
    };
    try tests.checkCases(js_env, &globals);
}
