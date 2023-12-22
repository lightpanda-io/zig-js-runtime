// ----------
// Public API
// ----------

// only imports, no implementation code

// Loader and Context
// ------------------

const internal = @import("internal_api.zig");

pub const compile = internal.gen.compile;
pub const loadEnv = internal.eng.loadEnv;
pub const ContextExecFn = internal.eng.ContextExecFn;

// Utils
// -----

pub const shell = @import("shell.zig").shell;
pub const shellExec = @import("shell.zig").shellExec;

pub const bench_allocator = @import("bench.zig").allocator;
pub const test_utils = @import("tests/test_utils.zig");

// JS types
// --------

const types = @import("types.zig");
pub const i64Num = types.i64Num;
pub const u64Num = types.u64Num;

pub const Iterable = types.Iterable;
pub const Variadic = types.Variadic;

pub const Loop = @import("loop.zig").SingleThreaded;
pub const Console = @import("console.zig").Console;

// JS engine
// ---------

const Engine = @import("private_api.zig").Engine;

pub const API = Engine.API;

pub const JSResult = Engine.JSResult;
pub const JSObject = Engine.JSObject;
pub const Callback = Engine.Callback;
pub const CallbackSync = Engine.CallbackSync;
pub const CallbackArg = Engine.CallbackArg;
pub const TryCatch = Engine.TryCatch;
pub const VM = Engine.VM;
pub const Env = Engine.Env;

pub const engineType = enum {
    v8,
};
