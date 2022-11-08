const std = @import("std");
const v8 = @import("v8");

const Callback = @import("types.zig").Callback;

// NOTE: all the code in this file should be run comptime.

pub const Type = struct {
    T: type,
    name: ?[]u8, // only for function parameters

    optional_T: ?type, // child of a type which is optional

    fn reflect(comptime T: type, comptime name: ?[]u8) Type {

        // optional T
        var optional_T: ?type = null;
        const info = @typeInfo(T);
        if (info == .Optional) {
            optional_T = info.Optional.child;
        }

        return Type{
            .T = T,
            .name = name,
            .optional_T = optional_T,
        };
    }
};

const Args = struct {
    fn reflect(comptime self_T: ?type, comptime args: []Type) !type {
        var len = args.len;
        if (self_T != null) {
            len += 1;
        }
        var fields: [len]std.builtin.Type.StructField = undefined;
        if (self_T != null) {
            const name = try itoa(0);
            fields[0] = std.builtin.Type.StructField{
                .name = name,
                .field_type = self_T.?,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(self_T.?),
            };
        }
        inline for (args) |arg, i| {
            var x = i;
            if (self_T != null) {
                x += 1;
            }
            fields[x] = std.builtin.Type.StructField{
                .name = arg.name.?,
                .field_type = arg.T,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(arg.T),
            };
        }
        const decls: [0]std.builtin.Type.Declaration = undefined;
        const s = std.builtin.Type.Struct{
            .layout = std.builtin.Type.ContainerLayout.Auto,
            .fields = &fields,
            .decls = &decls,
            .is_tuple = true,
        };
        const t = std.builtin.Type{ .Struct = s };
        return @Type(t);
    }
};

const FuncKind = enum {
    ignore,
    constructor,
    getter,
    setter,
    method,

    fn reflect(comptime T: type, decl: std.builtin.Type.Declaration) FuncKind {
        // exclude private declarations
        if (!decl.is_pub) {
            return FuncKind.ignore;
        }

        // exclude declarations who are not functions
        if (@typeInfo(@TypeOf(@field(T, decl.name))) != .Fn) {
            return FuncKind.ignore;
        }

        // check method kind
        if (std.mem.eql(u8, "constructor", decl.name)) {
            return FuncKind.constructor;
        }
        if (std.mem.eql(u8, "get", decl.name[0..3])) {
            return FuncKind.getter;
        }
        if (std.mem.eql(u8, "set", decl.name[0..3])) {
            return FuncKind.setter;
        }
        return FuncKind.method;
    }
};

pub const Func = struct {
    js_name: []const u8,
    name: []const u8,

    args: []Type,
    args_T: type,
    first_optional_arg: ?usize,
    has_callback: bool,

    return_type: ?Type,

    setter_index: ?u8, // TODO: not ideal, is there a cleaner solution?

    fn reflect(comptime T: type, comptime kind: FuncKind, comptime name: []const u8, comptime struct_T: ?type) Func {

        // T should be a func
        const func = @typeInfo(T);
        if (func != .Fn) {
            @compileError("reflect error: type provided is not a struct");
        }

        // check args length
        var args = func.Fn.args;
        if (kind != .constructor and args.len == 0) {
            // TODO: handle "class methods"
            @compileError("getter/setter/methods should have at least 1 argument, self");
        }
        if (kind == .getter and args.len > 1) {
            @compileError("getter should have only 1 argument: self");
        }

        // self special case (only for methods)
        var args_start = 0;
        if (struct_T != null and args.len > 0) {
            if (kind != .constructor) {
                // ignore self arg
                args_start = 1;
            }
            if (kind == .setter and args[0].arg_type.? != *struct_T.?) {
                @compileError("setter first argument should be *self");
            } else if ((kind == .getter or kind == .method) and (args[0].arg_type.? != struct_T.?)) {
                @compileError("getter/method first argument should be self");
            }
        }

        // args type
        args = args[args_start..];
        var args_types: [args.len]Type = undefined;
        var has_callback = false;
        for (args) |arg, i| {
            if (arg.arg_type.? == void) {
                // TODO: there is a bug with void paramater => avoid for now
                @compileError("reflect error: void parameters are not allowed for now");
            }

            // arg name
            var x = i;
            if (kind != .constructor) {
                x += 1;
            }
            const arg_name = try itoa(x);

            args_types[i] = Type.reflect(arg.arg_type.?, arg_name);

            // ensure function has only 1 callback as argument
            // TODO: is this necessary?
            if (args_types[i].T == Callback) {
                if (has_callback) {
                    @compileError("reflect error: function has already 1 callback");
                }
                has_callback = true;
            }
        }

        // first optional arg
        var first_optional_arg: ?usize = null;
        var i = args_types.len;
        while (i > 0) {
            i -= 1;
            if (args_types[i].optional_T == null) {
                break;
            }
            first_optional_arg = i;
        }

        // return type
        var return_type: ?Type = null;
        if (func.Fn.return_type != null) {
            return_type = Type.reflect(func.Fn.return_type.?, null);
        }

        // generate javascript name
        var field_name: []const u8 = undefined;
        if (kind == .getter) {
            field_name = std.mem.trimLeft(u8, name, "get");
        } else if (kind == .setter) {
            field_name = std.mem.trimLeft(u8, name, "set");
        } else {
            field_name = name;
        }
        const js_name = jsName(field_name);

        // reflect func
        const args_slice = args_types[0..];
        var self_T: ?type = null;
        if (kind != .constructor) {
            self_T = struct_T;
        }
        const args_T = comptime try Args.reflect(self_T, args_slice);

        return Func{
            .js_name = js_name,
            .name = name,

            .args = args_slice,
            .args_T = args_T,
            .first_optional_arg = first_optional_arg,
            .has_callback = has_callback,

            .return_type = return_type,

            .setter_index = null,
        };
    }
};

pub const Struct = struct {
    // struct info
    name: []const u8,
    T: type,
    mem_layout: std.builtin.Type.ContainerLayout,

    // index on the types list
    index: usize,

    // proto info
    proto_index: ?usize = null,
    proto_name: ?[]const u8,

    // struct functions
    constructor: ?Func,

    getters: []Func,
    setters: []Func,
    methods: []Func,

    // TODO: is it necessary?
    alignment: u29,
    size: usize,

    pub fn is_mem_guarantied(comptime self: Struct) bool {
        comptime {
            return self.mem_layout != .Auto;
        }
    }

    fn lessThan(_: void, comptime a: Struct, comptime b: Struct) bool {
        // priority: first proto_index (asc) and then index (asc)
        if (a.proto_index == null and b.proto_index == null) {
            return a.index < b.index;
        }
        if (a.proto_index != null and b.proto_index != null) {
            return a.proto_index.? < b.proto_index.?;
        }
        return a.proto_index == null;
    }

    fn reflect(comptime T: type, comptime index: usize) *Struct {

        // T should be a struct
        const obj = @typeInfo(T);
        if (obj != .Struct) {
            @compileError("reflect error: type provided is not a struct");
        }

        // T should not be packed
        // as packed struct does not works well for now
        // with unknown memory fields, like slices
        // see: https://github.com/ziglang/zig/issues/2201
        // and https://github.com/ziglang/zig/issues/3133
        if (obj.Struct.layout == .Packed) {
            @compileError("reflect error: packed struct are not supported");
        }

        // struct name
        var it = std.mem.splitBackwards(u8, @typeName(T), ".");
        const struct_name = it.first();

        // protoype
        var proto_name: ?[]const u8 = null;
        if (@hasDecl(T, "prototype")) {
            const T_proto = @field(T, "prototype");
            // check struct has a 'proto' field
            if (!@hasField(T, "proto")) {
                @compileError("reflect error: struct declares a 'prototype' but does not have a 'proto' field");
            }
            // check the 'proto' field
            inline for (obj.Struct.fields) |field, i| {
                if (!std.mem.eql(u8, field.name, "proto")) {
                    continue;
                }
                // check the 'proto' field is not a pointer
                if (@typeInfo(field.field_type) == .Pointer) {
                    @compileError("reflect error: struct 'proto' field should not be a Pointer");
                }
                // check the 'proto' field type
                // is the same than the 'prototype' declaration
                if (*field.field_type != T_proto) {
                    @compileError("reflect error: struct 'proto' field type is different than 'prototype' declaration");
                }
                // for layout where fields memory order is guarantied,
                // check the 'proto' field is the first one
                if (obj.Struct.layout != .Auto and i != 0) {
                    @compileError("reflect error: struct 'proto' field should be the first one if memory layout is guarantied (packed or extern)");
                }
                break;
            }
            it = std.mem.splitBackwards(u8, @typeName(T_proto), ".");
            proto_name = it.first();
        }

        // retrieve the number of each function kind
        var getters_nb: u8 = 0;
        var setters_nb: u8 = 0;
        var methods_nb: u8 = 0;

        // iterate over struct declarations
        // struct fields are considerated private and ignored
        // first iteration to retrieve the number of each method kind
        inline for (obj.Struct.decls) |decl| {
            const kind = comptime FuncKind.reflect(T, decl);
            switch (kind) {
                .ignore => continue,
                .constructor => {},
                .getter => getters_nb += 1,
                .setter => setters_nb += 1,
                .method => methods_nb += 1,
            }
        }

        var constructor: ?Func = null;
        var getters: [getters_nb]Func = undefined;
        var setters: [setters_nb]Func = undefined;
        var methods: [methods_nb]Func = undefined;

        var getters_done: u8 = 0;
        var setters_done: u8 = 0;
        var methods_done: u8 = 0;

        // iterate over struct declarations
        // second iteration to generate funcs
        inline for (obj.Struct.decls) |decl| {

            // check declaration kind
            const kind = comptime FuncKind.reflect(T, decl);
            if (kind == .ignore) {
                continue;
            }
            const func = @TypeOf(@field(T, decl.name));
            const func_reflected = comptime Func.reflect(func, kind, decl.name, T);

            switch (kind) {
                .constructor => {
                    constructor = func_reflected;
                },
                .getter => {
                    getters[getters_done] = func_reflected;
                    getters_done += 1;
                },
                .setter => {
                    setters[setters_done] = func_reflected;
                    setters_done += 1;
                },
                .method => {
                    methods[methods_done] = func_reflected;
                    methods_done += 1;
                },
                else => unreachable,
            }
        }

        for (getters) |*getter| {
            var setter_index: ?u8 = null;
            for (setters) |setter, i| {
                if (std.mem.eql(u8, getter.js_name, setter.js_name)) {
                    setter_index = i;
                    break;
                }
            }
            if (setter_index != null) {
                getter.setter_index = setter_index;
            }
        }

        const ptr_info = @typeInfo(*T).Pointer;

        var s = Struct{
            // struct info
            .name = struct_name,
            .T = T,
            .mem_layout = obj.Struct.layout,

            // index in types list
            .index = index,

            // proto info
            .proto_name = proto_name,

            // struct functions
            .constructor = constructor,
            .getters = getters[0..],
            .setters = setters[0..],
            .methods = methods[0..],

            .alignment = ptr_info.alignment,
            .size = @sizeOf(ptr_info.child),
        };
        return &s;
    }
};

pub fn do(comptime types: anytype) []Struct {
    comptime {

        // check types provided
        const types_T = @TypeOf(types);
        const types_info = @typeInfo(types_T);
        if (types_info != .Struct or !types_info.Struct.is_tuple) {
            @compileError("reflect error: 'types' should be a tuple of types");
        }
        const types_fields = types_info.Struct.fields;

        // reflect each type
        var all_ptr: [types_fields.len]*Struct = undefined;
        // at this point we use pointers
        // to modify later the structs with prototype info
        inline for (types_fields) |field, i| {
            const T = @field(types, field.name);
            if (@TypeOf(T) != type) {
                @compileError("reflect error: 'types' should only include types");
            }
            all_ptr[i] = Struct.reflect(T, i);
        }

        // look for prototype chain
        inline for (all_ptr) |s| {
            if (s.proto_name == null) {
                // does not have a prototype
                continue;
            }
            // loop over all structs to find proto
            inline for (all_ptr) |proto| {
                if (!std.mem.eql(u8, proto.name, s.proto_name.?)) {
                    // name is not equal to prototype name
                    continue;
                }
                // is proto
                if (s.mem_layout != proto.mem_layout) {
                    @compileError("reflect error: struct and proto struct should have the same memory layout");
                }
                s.proto_index = proto.index;
                break;
            }
            if (s.proto_index == null) {
                @compileError("reflect error: could not find the prototype in list");
            }
        }

        // we do not return pointers: this function is comptime
        // and we don't want to return comptime pointers to runtime execution
        var all: [all_ptr.len]Struct = undefined;
        for (all_ptr) |s, i| {
            all[i] = s.*;
        }
        const all_slice = &all;

        // sort to follow prototype chain order
        // ie. parents will be listed before children
        std.sort.sort(Struct, all_slice, {}, Struct.lessThan);

        return all_slice;
    }
}

// Utils funcs
// -----------

fn jsName(comptime name: []const u8) []u8 {
    comptime {
        const first = std.ascii.toLower(name[0]);
        var js_name = name[0..].*;
        js_name[0] = first;
        return &js_name;
    }
}

fn itoa(comptime i: u8) ![]u8 {
    comptime {
        var buf: [1]u8 = undefined;
        return try std.fmt.bufPrint(buf[0..], "{d}", .{i});
    }
}
