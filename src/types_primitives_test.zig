const v8 = @import("v8");

const refl = @import("reflect.zig");
const gen = @import("generate.zig");
const utils = @import("utils.zig");

// TODO: use functions instead of "fake" struct once we handle function API generation
const Primitives = struct {
    const i64Num = @import("types.zig").i64Num;
    const u64Num = @import("types.zig").u64Num;

    const Self = @This();

    // TODO: remove when the empty struct Store bug is fixed
    content: []const u8,

    pub fn constructor() Self {
        return .{ .content = "ok" };
    }

    // List of bytes (string)
    pub fn checkString(_: Self, v: []u8) []u8 {
        return v;
    }

    // Integers signed

    pub fn checkI32(_: Self, v: i32) i32 {
        return v;
    }

    pub fn checkI64(_: Self, v: i64) i64 {
        return v;
    }

    pub fn checkI64Num(_: Self, v: i64Num) i64Num {
        return v;
    }

    // Integers unsigned

    pub fn checkU32(_: Self, v: u32) u32 {
        return v;
    }

    pub fn checkU64(_: Self, v: u64) u64 {
        return v;
    }

    pub fn checkU64Num(_: Self, v: u64Num) u64Num {
        return v;
    }

    // Floats

    pub fn checkF32(_: Self, v: f32) f32 {
        return v;
    }

    pub fn checkF64(_: Self, v: f64) f64 {
        return v;
    }

    // Bool
    pub fn checkBool(_: Self, v: bool) bool {
        return v;
    }

    // Undefined
    pub fn checkUndefined(_: Self, v: void) void {
        return v;
    }

    // Null
    pub fn checkNullEmpty(_: Self, v: ?u32) bool {
        return (v == null);
    }
    pub fn checkNullNotEmpty(_: Self, v: ?u32) bool {
        return (v != null);
    }
};

pub fn doTest(isolate: v8.Isolate) !void {
    const tests = @import("test_utils.zig");

    // generate API
    const prim_refl = comptime refl.AsStruct(Primitives);
    const prim_api = comptime gen.API(Primitives, prim_refl);

    // create a v8 ObjectTemplate for the global namespace
    const globals = v8.ObjectTemplate.initDefault(isolate);

    // load API, before creating context
    prim_api.load(isolate, globals);

    // create v8 context
    var context = v8.Context.init(isolate, globals, null);
    context.enter();
    defer context.exit();

    // constructor
    const case_cstr = [_]tests.Case{
        .{ .src = "let p = new Primitives();", .ex = "undefined" },
    };
    try tests.checkCases(utils.allocator, isolate, context, case_cstr.len, case_cstr);

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
        .{ .src = "p.checkUndefined(undefined) === undefined;", .ex = "true" },

        // Null
        .{ .src = "p.checkNullEmpty(null);", .ex = "true" },
        .{ .src = "p.checkNullEmpty(undefined);", .ex = "true" },
        .{ .src = "p.checkNullNotEmpty(1);", .ex = "true" },
    };
    try tests.checkCases(utils.allocator, isolate, context, cases.len, cases);
}
