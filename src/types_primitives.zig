const std = @import("std");
const v8 = @import("v8");

const refl = @import("reflect.zig");
const utils = @import("utils.zig");
const engine = @import("engine.zig");
const Store = @import("store.zig");
const i64Num = @import("types.zig").i64Num;
const u64Num = @import("types.zig").u64Num;

// JS String
// ---------
// JS String will transalte to Native []u8.
// JS String are a set of "elements" of 16-bit unsigned integer values,
// however as with use v8 String, especially the NewFromUtf8 (Native -> JS)
// and WriteUtf8 (JS -> Native) functions, we manipulate chars, ie. []u8 in Native.
//
// => If you want to have []u8 for an other thing than a string
// you must use a custom u8Array.

// JS Number, JS BigInt, and Native int64
// --------------------------------------
// for safe representation we choose to always use a JS BigInt for native int64
// even if it's value could fit into a JS Number
// ie. between JS Number.MIN_SAFE_INTEGER and JS Number.MAX_SAFE_INTEGER
// => if you want to have a JS Number with a value > native int32
// you must use the custom native types u64Num or i64Num
// see: https://v8.dev/blog/bigint

// Native integers less than int32
// -------------------------------
// v8 handle int32 (signed or unsigned)
// for convenience we handle also int8 and int16 Native types
// which are just cast to/from v8 int32

// JS Null
// -------
// JS Null is not handled has a Native type
// but instead is used to represent Native optional value.

// JS Undefined
// ------------
// When JS Undefined is provided has an argument (JS -> Native)
// it is handled as JS Null, ie. Native optional value.

/// Convert a Native value to a JS value
/// and set it to the JS result provided.
pub fn nativeToJS(comptime zig_T: refl.Type, zig_val: zig_T.T, js_res: v8.ReturnValue, isolate: v8.Isolate) !void {

    // null
    if (zig_T.is_optional and zig_val == null) {
        return js_res.set(v8.initNull(isolate));
    }

    const js_val = switch (zig_T.T) {

        // undefined
        void => return,

        // list of bytes (ie. string)
        []u8 => v8.String.initUtf8(isolate, zig_val),

        // floats
        f32 => v8.Number.init(isolate, @floatCast(f32, zig_val)),
        f64 => v8.Number.init(isolate, zig_val),

        // integers signed
        i8, i16 => v8.Integer.initI32(isolate, @intCast(i32, zig_val)),
        i32 => v8.Integer.initI32(isolate, zig_val),
        i64Num => v8.Number.initBitCastedI64(isolate, zig_val.get()),
        i64 => v8.BigInt.initI64(isolate, zig_val),

        // integers unsigned
        u8, u16 => v8.Integer.initU32(isolate, @intCast(u32, zig_val)),
        u32 => v8.Integer.initU32(isolate, zig_val),
        u64Num => v8.Number.initBitCastedU64(isolate, zig_val.get()),
        u64 => v8.BigInt.initU64(isolate, zig_val),

        // bool
        bool => v8.Boolean.init(isolate, @boolToInt(zig_val)),

        else => return error.NativeTypeUnhandled,
    };

    js_res.set(js_val);
}

/// Convert a JS value to a Native value
/// allocator is only used if the JS value is a string.
pub fn jsToNative(alloc: std.mem.Allocator, comptime zig_T: refl.Type, js_val: v8.Value, isolate: v8.Isolate, ctx: v8.Context) !zig_T.T {

    // JS Undefined value for an Native void
    // not sure if this case make any sense (a void argument)
    // but let's support it for completeness
    if (js_val.isUndefined() == 1) {
        // distinct comptime condition, otherwise compile error
        comptime {
            if (zig_T.T == void) {
                return {};
            }
        }
    }

    // JS Null or Undefined value
    if (js_val.isNull() == 1 or js_val.isUndefined() == 1) {
        // distinct comptime condition, otherwise compile error
        comptime {
            // if Native optional type return null
            if (zig_T.is_optional) {
                return null;
            }
        }
        // Here we should normally return an error
        // ie. a JS Null/Undefined value has been used for a non-optional Native type.
        // But JS is liberal, you can pass null/undefined to:
        // - string (=> 'null' and 'undefined')
        // - bool (=> false),
        // - numeric types (null => 0 value, undefined => NaN)
        // TODO: return JS NaN for JS Undefined on int/float Native types.
    }

    // JS is liberal, you can pass:
    // - numeric value as string arg
    // - string value as numeric arg
    // - null as 0 numeric arg
    // - null and undefined as string or bool arg
    // Therefore we do not check the type of the JS value (ie. IsString, IsBool, etc.)
    // instead we directly try to return the corresponding Native value.

    switch (zig_T.T) {

        // list of bytes (including strings)
        []u8, ?[]u8 => {
            const buf = try utils.valueToUtf8(alloc, js_val, isolate, ctx);
            try Store.default.addString(buf);
            return buf;
        },

        // floats
        f32, ?f32 => return try js_val.toF32(ctx),
        f64, ?f64 => return try js_val.toF64(ctx),

        // integers signed
        i8, ?i8, i16, ?i16 => {
            const v = try js_val.toI32(ctx);
            return @intCast(zig_T.T, v);
        },
        i32, ?i32 => return try js_val.toI32(ctx),
        i64Num => {
            const v = try js_val.bitCastToI64(ctx);
            return i64Num.init(v);
        },
        i64, ?i64 => {
            if (js_val.isBigInt() == 1) {
                const v = js_val.castTo(v8.BigInt);
                return v.getInt64();
            }
            unreachable;
        },

        // integers unsigned
        u8, ?u8, u16, ?u16 => {
            const v = try js_val.toU32(ctx);
            return @intCast(zig_T.T, v);
        },
        u32, ?u32 => return try js_val.toU32(ctx),
        u64Num, ?u64Num => {
            const v = try js_val.bitCastToU64(ctx);
            return u64Num.init(v);
        },
        u64, ?u64 => {
            if (js_val.isBigInt() == 1) {
                const v = js_val.castTo(v8.BigInt);
                return v.getUint64();
            }
            unreachable;
        },

        // bool
        bool, ?bool => return js_val.toBool(isolate) == 1,

        else => return error.JSTypeUnhandled,
    }
}
