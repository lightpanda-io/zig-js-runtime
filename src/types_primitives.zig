const std = @import("std");
const v8 = @import("v8");

const refl = @import("reflect.zig");
const utils = @import("utils.zig");
const engine = @import("engine.zig");
const Store = @import("store.zig");

const i64Num = @import("types.zig").i64Num;
const u64Num = @import("types.zig").u64Num;
const Callback = @import("types.zig").Callback;
const CallbackArg = @import("types.zig").CallbackArg;

/// Convert a Native value to a JS value
/// and set it to the JS result provided.
pub fn nativeToJS(comptime zig_T: refl.Type, zig_val: zig_T.T, js_res: v8.ReturnValue, isolate: v8.Isolate) !void {

    // null
    if (zig_T.optional_T != null and zig_val == null) {
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
        bool => v8.Boolean.init(isolate, zig_val),

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
    if (js_val.isUndefined()) {
        // distinct comptime condition, otherwise compile error
        comptime {
            if (zig_T.T == void) {
                return {};
            }
        }
    }

    // JS Null or Undefined value
    if (js_val.isNull() or js_val.isUndefined()) {
        // distinct comptime condition, otherwise compile error
        comptime {
            // if Native optional type return null
            if (zig_T.optional_T != null) {
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
        []u8, ?[]u8, []const u8, ?[]const u8 => {
            const buf = try utils.valueToUtf8(alloc, js_val, isolate, ctx);
            if (Store.default != null) {
                try Store.default.?.addString(buf);
            }
            return buf;
        },

        // floats
        f32, ?f32 => return try js_val.toF32(ctx),
        f64, ?f64 => return try js_val.toF64(ctx),

        // integers signed
        i8, ?i8, i16, ?i16 => {
            const v = try js_val.toI32(ctx);
            if (zig_T.optional_T != null) {
                return @intCast(zig_T.optional_T.?, v);
            }
            return @intCast(zig_T.T, v);
        },
        i32, ?i32 => return try js_val.toI32(ctx),
        i64Num => {
            const v = try js_val.bitCastToI64(ctx);
            return i64Num.init(v);
        },
        i64, ?i64 => {
            if (js_val.isBigInt()) {
                const v = js_val.castTo(v8.BigInt);
                return v.getInt64();
            }
            unreachable;
        },

        // integers unsigned
        u8, ?u8, u16, ?u16 => {
            const v = try js_val.toU32(ctx);
            if (zig_T.optional_T != null) {
                return @intCast(zig_T.optional_T.?, v);
            }
            return @intCast(zig_T.T, v);
        },
        u32, ?u32 => return try js_val.toU32(ctx),
        u64Num, ?u64Num => {
            const v = try js_val.bitCastToU64(ctx);
            return u64Num.init(v);
        },
        u64, ?u64 => {
            if (js_val.isBigInt()) {
                const v = js_val.castTo(v8.BigInt);
                return v.getUint64();
            }
            unreachable;
        },

        // bool
        bool, ?bool => return js_val.toBool(isolate),

        // Callback
        // These values are not supposed to be used by native function,
        // instead callback is handled specifically after function returns.
        // So here we just return void values.
        Callback => return Callback{}, // stage1: we need type
        CallbackArg => return CallbackArg{}, // stage1: we need type

        else => return error.JSTypeUnhandled,
    }
}
