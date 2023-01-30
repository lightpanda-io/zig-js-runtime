const std = @import("std");

const v8 = @import("v8");

const eng = @import("engine.zig");
const gen = @import("generate.zig");

pub const Console = struct {
    // TODO: configurable writer

    pub fn _log(_: Console, str: []const u8) void {
        std.debug.print("== JS console: {s} ==\n", .{str});
    }
};

pub fn addAPI(comptime apis: []gen.API) []gen.API {
    comptime var apis_with_console: [apis.len + 1]gen.API = undefined;
    comptime {
        var console_api = gen.compile(.{Console})[0];
        console_api.T_refl.index = apis.len;
        inline for (apis) |api, i| {
            apis_with_console[i] = api;
        }
        apis_with_console[apis.len] = console_api;
    }
    return &apis_with_console;
}

pub fn load(
    alloc: std.mem.Allocator,
    comptime apis: []gen.API,
    tpls: []gen.ProtoTpl,
    isolate: v8.Isolate,
    context: v8.Context,
) !void {

    // retrieve console API
    comptime var console_index: comptime_int = undefined;
    comptime {
        inline for (apis) |api| {
            if (std.mem.eql(u8, api.T_refl.name, "Console")) {
                console_index = api.T_refl.index;
            }
        }
    }

    // create JS object
    const console = Console{};
    // TODO: use pointer (and allocator) here
    try eng.createV8Object(
        alloc,
        apis[console_index].T_refl,
        console,
        tpls[console_index].tpl,
        context.getGlobal(),
        context,
        isolate,
    );
}
