const std = @import("std");

const public = @import("../api.zig");
const tests = public.test_utils;

const Config = struct {
    use_proxy: bool,
};

pub const UserContext = Config;

const Request = struct {
    use_proxy: bool,

    pub fn constructor(ctx: Config) Request {
        return .{
            .use_proxy = ctx.use_proxy,
        };
    }

    pub fn get_proxy(self: *Request) bool {
        return self.use_proxy;
    }

    pub fn _configProxy(_: *Request, ctx: Config) bool {
        return ctx.use_proxy;
    }
};

pub const Types = .{
    Request,
};

// exec tests
pub fn exec(
    _: std.mem.Allocator,
    js_env: *public.Env,
) anyerror!void {
    try js_env.setUserContext(Config{
        .use_proxy = true,
    });

    // start JS env
    try js_env.start();
    defer js_env.stop();

    var tc = [_]tests.Case{
        .{ .src = "const req = new Request();", .ex = "undefined" },
        .{ .src = "req.proxy", .ex = "true" },
        .{ .src = "req.configProxy()", .ex = "true" },
    };
    try tests.checkCases(js_env, &tc);
}
