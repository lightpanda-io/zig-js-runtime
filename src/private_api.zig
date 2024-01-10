const std = @import("std");

const interfaces = @import("interfaces.zig");

fn checkInterfaces(engine: anytype) void {

    // public api
    interfaces.API(engine.API, engine.LoadFnType);

    interfaces.Callback(engine.Callback);
    interfaces.CallbackSync(engine.CallbackSync);
    interfaces.CallbackArg(engine.CallbackArg);

    interfaces.JSResult(engine.JSResult);
    interfaces.TryCatch(engine.TryCatch, engine.Env);

    interfaces.VM(engine.VM);
    interfaces.Env(
        engine.Env,
        engine.JSResult,
        engine.Object,
    );

    // private api
}

pub const Engine = blk: {

    // retrieve JS engine

    // - as a build option
    const build_opts = @import("jsruntime_build_options");
    if (@hasDecl(build_opts, "engine")) {
        if (build_opts.engine) |eng| {
            if (std.mem.eql(u8, eng, "v8")) {
                const engine = @import("engines/v8/v8.zig");
                checkInterfaces(engine);
                break :blk engine;
            }
            @compileError("unknwon -Dengine '" ++ eng ++ "'");
        }
        @compileError("empty -Dengine");
    }

    // - as a root declaration
    const root = @import("root");
    if (@hasDecl(root, "JSEngine")) {
        checkInterfaces(root.JSEngine);
        break :blk root.JSEngine;
    }

    @compileError("you need to specify a JS engine as a build option (-Dengine) or as a root file declaration (pub const JSEngine)");
};

pub const API = Engine.API;

// loadFn is a function which generates
// the loading and binding of the native API into the JS engine
pub const loadFn = Engine.loadFn;

pub const Object = Engine.Object;
