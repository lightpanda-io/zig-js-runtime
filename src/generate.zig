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

const internal = @import("internal_api.zig");
const refl = internal.refl;
const NativeContext = internal.NativeContext;

const API = @import("private_api.zig").API;
const loadFn = @import("private_api.zig").loadFn;

// Compile and loading mechanism
// -----------------------------

// NOTE:
// The mechanism is based on 2 steps
// 1. The compile step at comptime will produce a list of APIs
// At this step we:
// - reflect the native types to obtain type information (T_refl)
// - generate a loading function containing corresponding JS callbacks functions
// (constructor, getters, setters, methods)
// 2. The loading step at runtime will produce a list of TPLs
// At this step we call the loading function into the runtime v8 (Isolate and globals),
// generating corresponding V8 functions and objects templates.

// reflect the user-defined types to obtain type information (T_refl)
// This function must be called at comptime by the root file of the project
// and stored in a constant named `Types`
pub fn reflect(comptime types: anytype) []refl.Struct {
    std.debug.assert(@inComptime());

    // call types reflection
    return refl.do(types) catch unreachable;
}

// Import user-defined types
pub const Types: []refl.Struct = @import("root").Types;

// retrieved the reflected type of a user-defined native type
pub fn getType(comptime T: type) refl.Struct {
    std.debug.assert(@inComptime());
    for (Types) |t| {
        if (T == t.Self() or T == *t.Self()) {
            return t;
        }
    }
    @compileError("NativeTypeNotHandled: " ++ @typeName(T));
}

// generate APIs from reflected types
// which can be later loaded in JS.
fn generate(comptime types: []refl.Struct) []API {
    std.debug.assert(@inComptime());

    var apis: [types.len]API = undefined;
    inline for (types, 0..) |T_refl, i| {
        const loader = loadFn(T_refl);
        apis[i] = API{ .T_refl = T_refl, .load = loader };
    }
    return &apis;
}

// Load user-defined native types into a JS sandbox
// This function is called at runtime.
pub fn load(
    nat_ctx: *NativeContext,
    js_sandbox: anytype,
    js_globals: anytype,
    comptime js_T: type,
    js_types: []js_T,
) !void {
    const apis = comptime generate(Types);

    inline for (Types, 0..) |T_refl, i| {
        if (T_refl.proto_index == null) {
            js_types[i] = try apis[i].load(nat_ctx, js_sandbox, js_globals, null);
        } else {
            const proto = js_types[T_refl.proto_index.?]; // safe because apis are ordered from parent to child
            js_types[i] = try apis[i].load(nat_ctx, js_sandbox, js_globals, proto);
        }
    }
}

// meta-programing

fn itoa(comptime i: u8) []const u8 {
    var len: usize = undefined;
    if (i < 10) {
        len = 1;
    } else if (i < 100) {
        len = 2;
    } else {
        @compileError("too much members");
    }
    var buf: [len]u8 = undefined;
    return std.fmt.bufPrint(buf[0..], "{d}", .{i}) catch unreachable;
}

// retrieve the number of elements in a tuple
fn tupleNb(comptime tuple: anytype) usize {
    var nb = 0;
    for (@typeInfo(@TypeOf(tuple)).Struct.fields) |member| {
        const member_info = @typeInfo(member.type);
        if (member_info != .Struct or (member_info == .Struct and !member_info.Struct.is_tuple)) {
            @compileError("GenerateMemberNotTypeOrTuple");
        }
        for (member_info.Struct.fields) |field| {
            if (field.type != type) {
                @compileError("GenerateMemberTupleChildNotType");
            }
        }
        nb += member_info.Struct.fields.len;
    }
    return nb;
}

fn tupleTypes(comptime nb: usize, comptime tuple: anytype) [nb]type {
    var types: [nb]type = undefined;
    var i = 0;
    for (@typeInfo(@TypeOf(tuple)).Struct.fields) |member| {
        const T = @field(tuple, member.name);
        const info = @typeInfo(@TypeOf(T));
        for (info.Struct.fields) |field| {
            types[i] = @field(T, field.name);
            i += 1;
        }
    }
    return types;
}

fn MergeTupleT(comptime value: anytype) type {
    const fields_nb = tupleNb(value);
    var fields: [fields_nb]std.builtin.Type.StructField = undefined;
    var i = 0;
    while (i < fields_nb) {
        fields[i] = .{
            // StructField.name expect a null terminated string.
            // concatenate the `[]const u8` string with an empty string
            // literal (`name ++ ""`) to explicitly coerce it to `[:0]const
            // u8`.
            .name = itoa(i) ++ "",
            .type = type,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(type),
        };
        i += 1;
    }
    const decls: [0]std.builtin.Type.Declaration = undefined;
    const info = std.builtin.Type.Struct{
        .layout = .auto,
        .fields = &fields,
        .decls = &decls,
        .is_tuple = true,
    };
    return @Type(std.builtin.Type{ .Struct = info });
}

pub fn MergeTuple(comptime value: anytype) MergeTupleT(value) {
    var t: MergeTupleT(value) = undefined;

    const fields_nb = tupleNb(value);
    const fields_types = tupleTypes(fields_nb, value);

    for (fields_types, 0..) |T, i| {
        const name = itoa(i);
        @field(t, name) = T;
    }
    return t;
}
