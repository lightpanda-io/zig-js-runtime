// Copyright 2023-2024 Lightpanda (Selecy SAS)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

const interfaces = @import("interfaces.zig");

fn checkInterfaces(engine: anytype) void {

    // public api
    interfaces.API(engine.API, engine.LoadFnType);

    interfaces.CallbackResult(engine.CallbackResult);
    interfaces.Callback(engine.Callback, engine.CallbackResult);
    interfaces.CallbackSync(engine.CallbackSync, engine.CallbackResult);
    interfaces.CallbackArg(engine.CallbackArg);

    interfaces.JSValue(engine.JSValue, engine.Env);
    interfaces.JSObjectID(engine.JSObjectID);

    interfaces.TryCatch(engine.TryCatch, engine.Env);

    interfaces.VM(engine.VM);
    interfaces.Env(
        engine.Env,
        engine.JSValue,
        engine.Object,
    );

    // private api
}

pub const Engine = blk: {

    // retrieve JS engine

    // - as a build option
    const build_opts = @import("jsruntime_build_options");
    if (@hasDecl(build_opts, "engine")) {
        // use v8 by default.
        const eng = build_opts.engine orelse "v8";
        if (std.mem.eql(u8, eng, "v8")) {
            const engine = @import("engines/v8/v8.zig");
            checkInterfaces(engine);
            break :blk engine;
        }
        @compileError("unknwon -Dengine '" ++ eng ++ "'");
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
