// Public API
// only imports, no implementation code

pub const Loop = @import("loop.zig").SingleThreaded;
pub const shell = @import("shell.zig").shell;
pub const shellExec = @import("shell.zig").shellExec;
pub const Console = @import("console.zig").Console;

const gen = @import("generate.zig");
pub const compile = gen.compile;
pub const TPL = gen.ProtoTpl;
pub const API = gen.API;

const eng = @import("engine.zig");
pub const VM = eng.VM;
pub const loadEnv = eng.loadEnv;
pub const Env = eng.Env;
pub const ContextExecFn = eng.ContextExecFn;
pub const JSResult = eng.JSResult;

const types = @import("types.zig");
pub const i64Num = types.i64Num;
pub const u64Num = types.u64Num;
pub const Iterable = types.Iterable;

pub const bench_allocator = @import("bench.zig").allocator;

pub const test_utils = @import("tests/test_utils.zig");
