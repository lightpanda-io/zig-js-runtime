const std = @import("std");
const v8 = @import("v8");

const utils = @import("../utils.zig");
const gen = @import("../generate.zig");
const eng = @import("../engine.zig");
const Loop = @import("../loop.zig").SingleThreaded;

const tests = @import("test_utils.zig");

// TODO: use functions instead of "fake" struct once we handle function API generation
const Primitives = struct {
    const i64Num = @import("../types.zig").i64Num;
    const u64Num = @import("../types.zig").u64Num;

    const Self = @This();

    pub fn constructor() Self {
        return .{};
    }

    // List of bytes (string)
    pub fn _checkString(_: Self, v: []u8) []u8 {
        return v;
    }

    // Integers signed

    pub fn _checkI32(_: Self, v: i32) i32 {
        return v;
    }

    pub fn _checkI64(_: Self, v: i64) i64 {
        return v;
    }

    pub fn _checkI64Num(_: Self, v: i64Num) i64Num {
        return v;
    }

    // Integers unsigned

    pub fn _checkU32(_: Self, v: u32) u32 {
        return v;
    }

    pub fn _checkU64(_: Self, v: u64) u64 {
        return v;
    }

    pub fn _checkU64Num(_: Self, v: u64Num) u64Num {
        return v;
    }

    // Floats

    pub fn _checkF32(_: Self, v: f32) f32 {
        return v;
    }

    pub fn _checkF64(_: Self, v: f64) f64 {
        return v;
    }

    // Bool
    pub fn _checkBool(_: Self, v: bool) bool {
        return v;
    }

    // Undefined
    // TODO: there is a bug with this function
    // void paramater does not work => avoid for now
    // pub fn _checkUndefined(_: Self, v: void) void {
    //     return v;
    // }

    // Null
    pub fn _checkNullEmpty(_: Self, v: ?u32) bool {
        return (v == null);
    }
    pub fn _checkNullNotEmpty(_: Self, v: ?u32) bool {
        return (v != null);
    }

    // Optionals
    pub fn _checkOptional(_: Self, _: ?u8, v: u8, _: ?u8, _: ?u8) u8 {
        return v;
    }
    pub fn _checkNonOptional(_: Self, v: u8) u8 {
        return v;
    }
};

// generate API, comptime
pub fn generate() []gen.API {
    return gen.compile(.{Primitives});
}

// exec tests
pub fn exec(
    loop: *Loop,
    isolate: v8.Isolate,
    globals: v8.ObjectTemplate,
    _: []gen.ProtoTpl,
    comptime _: []gen.API,
) !eng.ExecRes {

    // create v8 context
    var context = v8.Context.init(isolate, globals, null);
    context.enter();
    defer context.exit();

    // constructor
    const case_cstr = [_]tests.Case{
        .{ .src = "let p = new Primitives();", .ex = "undefined" },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, case_cstr.len, case_cstr);

    // JS <> Native translation of primitive types
    const cases = [_]tests.Case{

        // String
        .{ .src = "p.checkString('ok ascii') === 'ok ascii';", .ex = "true" },
        .{ .src = "p.checkString('ok emoji 🚀') === 'ok emoji 🚀';", .ex = "true" },
        .{ .src = "p.checkString('ok chinese 鿍') === 'ok chinese 鿍';", .ex = "true" },

        // String (JS liberal cases)
        .{ .src = "p.checkString(1) === '1';", .ex = "true" },
        .{ .src = "p.checkString(null) === 'null';", .ex = "true" },
        .{ .src = "p.checkString(undefined) === 'undefined';", .ex = "true" },

        // Integers

        // signed
        .{ .src = "const min_i32 = -2147483648", .ex = "undefined" },
        .{ .src = "p.checkI32(min_i32) === min_i32;", .ex = "true" },
        .{ .src = "p.checkI32(min_i32-1) === min_i32-1;", .ex = "false" },

        // unsigned
        .{ .src = "const max_u32 = 4294967295", .ex = "undefined" },
        .{ .src = "p.checkU32(max_u32) === max_u32;", .ex = "true" },
        .{ .src = "p.checkU32(max_u32+1) === max_u32+1;", .ex = "false" },

        // int64 (with Number)
        .{ .src = "p.checkI64Num(min_i32-1) === min_i32-1;", .ex = "true" },
        .{ .src = "p.checkU64Num(max_u32+1) === max_u32+1;", .ex = "true" },

        // int64 (with BigInt)
        .{ .src = "const big_int = 9007199254740995n", .ex = "undefined" },
        .{ .src = "p.checkI64(big_int) === big_int", .ex = "true" },
        .{ .src = "p.checkU64(big_int) === big_int;", .ex = "true" },

        // Floats
        // use round 2 decimals for float to ensure equality
        .{ .src = "const r = function(x) {return Math.round(x * 100) / 100};", .ex = "undefined" },
        .{ .src = "const double = 10.02;", .ex = "undefined" },
        .{ .src = "r(p.checkF32(double)) === double;", .ex = "true" },
        .{ .src = "r(p.checkF64(double)) === double;", .ex = "true" },

        // Bool
        .{ .src = "p.checkBool(true);", .ex = "true" },
        .{ .src = "p.checkBool(false);", .ex = "false" },
        .{ .src = "p.checkBool(0);", .ex = "false" },
        .{ .src = "p.checkBool(1);", .ex = "true" },

        // Bool (JS liberal cases)
        .{ .src = "p.checkBool(null);", .ex = "false" },
        .{ .src = "p.checkBool(undefined);", .ex = "false" },

        // Undefined
        // see TODO on Primitives.checkUndefined
        // .{ .src = "p.checkUndefined(undefined) === undefined;", .ex = "true" },

        // Null
        .{ .src = "p.checkNullEmpty(null);", .ex = "true" },
        .{ .src = "p.checkNullEmpty(undefined);", .ex = "true" },
        .{ .src = "p.checkNullNotEmpty(1);", .ex = "true" },

        // Optional
        .{ .src = "p.checkOptional(null, 3);", .ex = "3" },
        .{ .src = "p.checkNonOptional();", .ex = "TypeError" },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases.len, cases);
    return eng.ExecOK;
}
