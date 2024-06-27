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

// ----------
// Public API
// ----------

// only imports, no implementation code

// Loader and Context
// ------------------

const internal = @import("internal_api.zig");

pub const reflect = internal.gen.reflect;
pub const loadEnv = internal.eng.loadEnv;
pub const ContextExecFn = internal.eng.ContextExecFn;

// Utils
// -----

pub const MergeTuple = internal.gen.MergeTuple;

pub const shell = @import("shell.zig").shell;
pub const shellExec = @import("shell.zig").shellExec;

pub const bench_allocator = @import("bench.zig").allocator;
pub const test_utils = @import("tests/test_utils.zig");

// JS types
// --------

pub const JSTypes = enum {
    object,
    function,
    string,
    number,
    boolean,
    bigint,
    null,
    undefined,
};

const types = @import("types.zig");
pub const i64Num = types.i64Num;
pub const u64Num = types.u64Num;

pub const Iterable = types.Iterable;
pub const Variadic = types.Variadic;

pub const Loop = @import("loop.zig").SingleThreaded;
pub const IO = @import("loop.zig").IO;
pub const Console = @import("console.zig").Console;

pub const UserContext = @import("user_context.zig").UserContext;

// JS engine
// ---------

const Engine = @import("private_api.zig").Engine;

pub const JSValue = Engine.JSValue;
pub const JSObject = Engine.JSObject;
pub const JSObjectID = Engine.JSObjectID;

pub const Callback = Engine.Callback;
pub const CallbackSync = Engine.CallbackSync;
pub const CallbackArg = Engine.CallbackArg;
pub const CallbackResult = Engine.CallbackResult;

pub const TryCatch = Engine.TryCatch;
pub const VM = Engine.VM;
pub const Env = Engine.Env;

pub const engineType = enum {
    v8,
};
