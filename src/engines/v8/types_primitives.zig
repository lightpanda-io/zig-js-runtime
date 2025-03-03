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

const v8 = @import("v8");

const internal = @import("../../internal_api.zig");
const refl = internal.refl;

const public = @import("../../api.zig");
const i64Num = public.i64Num;
const u64Num = public.u64Num;

// Convert a Native value to a JS value
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
        // TODO: what about precision, ie. 1.82 (native) -> 1.8200000524520874 (js)
        f32 => v8.Number.init(isolate, @as(f32, @floatCast(val))),
        f64 => v8.Number.init(isolate, val),

        // integers signed
        i8, i16 => v8.Integer.initI32(isolate, @as(i32, @intCast(val))),
        i32 => v8.Integer.initI32(isolate, val),
        i64Num => v8.Number.initBitCastedI64(isolate, val.get()),
        i64 => v8.BigInt.initI64(isolate, val),

        // integers unsigned
        u8, u16 => v8.Integer.initU32(isolate, @as(u32, @intCast(val))),
        u32 => v8.Integer.initU32(isolate, val),
        u64Num => v8.Number.initBitCastedU64(isolate, val.get()),
        u64 => v8.BigInt.initU64(isolate, val),

        // bool
        bool => v8.Boolean.init(isolate, val),

        else => return error.NativeTypeUnhandled,
    };

    return v8.getValue(js_val);
}

// Convert a JS value to a Native value
// allocator is only used if the JS value is a string,
// in this case caller owns the memory
pub fn jsToNative(
    alloc: std.mem.Allocator,
    comptime T: type,
    js_val: v8.Value,
    isolate: v8.Isolate,
    ctx: v8.Context,
) !T {

    // JS Undefined value for an Native void
    // not sure if this case make any sense (a void argument)
    // but let's support it for completeness
    if (js_val.isUndefined()) {
        // distinct comptime condition, otherwise compile error
        comptime {
            if (T == void) {
                return {};
            }
        }
    }

    const info = @typeInfo(T);

    // JS Null or Undefined value
    if (js_val.isNull() or js_val.isUndefined()) {
        // if Native optional type return null
        if (comptime info == .Optional) {
            return null;
        }
        // Here we should normally return an error
        // ie. a JS Null/Undefined value has been used for a non-optional Native type.
        // But JS is liberal, you can pass null/undefined to:
        // - string (=> 'null' and 'undefined')
        // - bool (=> false),
        // - numeric types (null => 0 value, undefined => NaN)
        // TODO: return JS NaN for JS Undefined on int/float Native types.
    }

    // unwrap Optional
    if (info == .Optional) {
        return try jsToNative(alloc, info.Optional.child, js_val, isolate, ctx);
    }

    // JS values
    // JS is liberal, you can pass:
    // - numeric value as string arg
    // - string value as numeric arg
    // - null as 0 numeric arg
    // - null and undefined as string or bool arg
    // Therefore we do not check the type of the JS value (ie. IsString, IsBool, etc.)
    // instead we directly try to return the corresponding Native value.

    switch (T) {

        // list of bytes (including strings)
        []u8, []const u8 => {
            return try valueToUtf8(alloc, js_val, isolate, ctx);
        },

        // floats
        f32 => return js_val.toF32(ctx) catch return error.InvalidArgument,
        f64 => return js_val.toF64(ctx) catch return error.InvalidArgument,

        // integers signed
        i8, i16 => {
            const v = js_val.toI32(ctx) catch return error.InvalidArgument;
            return @as(T, @intCast(v));
        },
        i32 => return js_val.toI32(ctx) catch return error.InvalidArgument,
        i64Num => {
            const v = js_val.bitCastToI64(ctx) catch return error.InvalidArgument;
            return i64Num.init(v);
        },
        i64 => {
            if (js_val.isBigInt()) {
                const v = js_val.castTo(v8.BigInt);
                return v.getInt64();
            }
            return @intCast(js_val.toI32(ctx) catch return error.InvalidArgument);
        },

        // integers unsigned
        u8, u16 => {
            const v = js_val.toU32(ctx) catch return error.InvalidArgument;
            return @as(T, @intCast(v));
        },
        u32 => return js_val.toU32(ctx) catch return error.InvalidArgument,
        u64Num, ?u64Num => {
            const v = js_val.bitCastToU64(ctx) catch return error.InvalidArgument;
            return u64Num.init(v);
        },
        u64 => {
            if (js_val.isBigInt()) {
                const v = js_val.castTo(v8.BigInt);
                return v.getUint64();
            }
            return @intCast(js_val.toU32(ctx) catch return error.InvalidArgument);
        },

        // bool
        bool => return js_val.toBool(isolate),

        else => return error.JSTypeUnhandled,
    }
}

// Convert a JS value to a Native nested object
pub fn jsToObject(
    alloc: std.mem.Allocator,
    comptime nested_T: refl.StructNested,
    comptime T: type,
    js_val: v8.Value,
    isolate: v8.Isolate,
    ctx: v8.Context,
) !T {
    const info = @typeInfo(T);

    // JS Null or Undefined value
    if (js_val.isNull() or js_val.isUndefined()) {
        // if Native optional type return null
        if (comptime info == .Optional) {
            return null;
        }
    }

    // check it's a JS object
    if (!js_val.isObject()) {
        return error.JSNotObject;
    }

    // unwrap Optional
    if (comptime info == .Optional) {
        return try jsToObject(alloc, nested_T, info.Optional.child, js_val, isolate, ctx);
    }

    const js_obj = js_val.castTo(v8.Object);
    var obj: T = undefined;
    inline for (nested_T.fields, 0..) |field, i| {
        const name = field.name.?;
        const key = v8.String.initUtf8(isolate, name);
        if (js_obj.has(ctx, key.toValue())) {
            const field_js_val = try js_obj.getValue(ctx, key);
            const field_val = try jsToNative(alloc, field.T, field_js_val, isolate, ctx);
            @field(obj, name) = field_val;
        } else {
            if (comptime field.underOpt() != null) {
                @field(obj, name) = null;
            } else if (comptime !refl.hasDefaultValue(nested_T.T, i)) {
                return error.JSWrongObject;
            }
        }
    }
    // here we could handle pointer to JS object
    // (by allocating a pointer, setting it's value to obj and returning it)
    // but for this kind of use case a complete type API is preferable
    // over an anonymous JS object
    return obj;
}

pub fn valueToUtf8(
    alloc: std.mem.Allocator,
    value: v8.Value,
    isolate: v8.Isolate,
    ctx: v8.Context,
) ![]u8 {
    const str = try value.toString(ctx);
    const len = str.lenUtf8(isolate);
    const buf = try alloc.alloc(u8, len);
    _ = str.writeUtf8(isolate, buf);
    return buf;
}
