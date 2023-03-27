const std = @import("std");
const v8 = @import("v8");

const refl = @import("reflect.zig");
const utils = @import("utils.zig");
const engine = @import("engine.zig");

const i64Num = @import("types.zig").i64Num;
const u64Num = @import("types.zig").u64Num;

/// Convert a Native value to a JS value
pub fn nativeToJS(
    comptime T: type,
    val: T,
    isolate: v8.Isolate,
) !v8.Value {
    const js_val = switch (T) {

        // undefined
        void => v8.initUndefined(isolate),

        // list of bytes (ie. string)
        []u8, []const u8 => v8.String.initUtf8(isolate, val),

        // floats
        f32 => v8.Number.init(isolate, @floatCast(f32, val)),
        f64 => v8.Number.init(isolate, val),

        // integers signed
        i8, i16 => v8.Integer.initI32(isolate, @intCast(i32, val)),
        i32 => v8.Integer.initI32(isolate, val),
        i64Num => v8.Number.initBitCastedI64(isolate, val.get()),
        i64 => v8.BigInt.initI64(isolate, val),

        // integers unsigned
        u8, u16 => v8.Integer.initU32(isolate, @intCast(u32, val)),
        u32 => v8.Integer.initU32(isolate, val),
        u64Num => v8.Number.initBitCastedU64(isolate, val.get()),
        u64 => v8.BigInt.initU64(isolate, val),

        // bool
        bool => v8.Boolean.init(isolate, val),

        else => return error.NativeTypeUnhandled,
    };

    return v8.getValue(js_val);
}

/// Convert a JS value to a Native value
/// allocator is only used if the JS value is a string.
pub fn jsToNative(
    alloc: std.mem.Allocator,
    comptime T_refl: refl.Struct,
    comptime zig_T: refl.Type,
    js_val: v8.Value,
    isolate: v8.Isolate,
    ctx: v8.Context,
) !zig_T.T {

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
            if (zig_T.is_opt) {
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

    // JS objects
    if (zig_T.nested_index) |index| {
        if (!js_val.isObject()) {
            return error.JSNotObject;
        }
        const js_obj = js_val.castTo(v8.Object);
        const nested_T = T_refl.nested[index];
        // using under_T to handle both mandatory and optional JS object
        var obj: zig_T.under_T = undefined;
        inline for (nested_T.fields) |field| {
            const key = v8.String.initUtf8(isolate, field.name.?);
            if (!js_obj.has(ctx, key.toValue())) {
                return error.JSWrongObject;
            }
            const field_js_val = try js_obj.getValue(ctx, key);
            const field_val = try jsToNative(alloc, T_refl, field, field_js_val, isolate, ctx);
            @field(obj, field.name.?) = field_val;
        }
        // here we could handle pointer to JS object
        // (by allocating a pointer, setting it's value to obj and returning it)
        // but for this kind of use case a complete type API is preferable
        // over an anonymous JS object
        return obj;
    }

    // JS values
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
            return try utils.valueToUtf8(alloc, js_val, isolate, ctx);
        },

        // floats
        f32, ?f32 => return try js_val.toF32(ctx),
        f64, ?f64 => return try js_val.toF64(ctx),

        // integers signed
        i8, ?i8, i16, ?i16 => {
            const v = try js_val.toI32(ctx);
            if (zig_T.is_opt) {
                return @intCast(zig_T.under_T, v);
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
            if (zig_T.is_opt) {
                return @intCast(zig_T.under_T, v);
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

        else => return error.JSTypeUnhandled,
    }
}
