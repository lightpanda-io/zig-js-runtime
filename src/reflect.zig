const std = @import("std");
const v8 = @import("v8");

// NOTE: all the code in this file should be run comptime.

pub const Type = struct {
    T: type,
    is_optional: bool,
};

fn isOptional(comptime T: type) bool {
    return (@typeInfo(T) == .Optional);
}

const FuncKind = enum {
    ignore,
    constructor,
    getter,
    setter,
    method,
};

fn checkFuncKind(comptime T: type, decl: std.builtin.Type.Declaration) FuncKind {
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

pub const Func = struct {
    js_name: []const u8,
    name: []const u8,
    args: []Type,
    return_type: ?Type,

    setter_index: ?u8, // TODO: not ideal, is there a cleaner solution?
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
};

pub fn doAll(comptime types: anytype) []Struct {
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
            all_ptr[i] = doOne(T, i);
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

fn doOne(comptime T: type, comptime index: usize) *Struct {

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
    // first iteration to retrieve the number of each function kind
    inline for (obj.Struct.decls) |decl| {
        const kind = checkFuncKind(T, decl);
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
        const kind = checkFuncKind(T, decl);
        if (kind == .ignore) {
            continue;
        }
        const func = @typeInfo(@TypeOf(@field(T, decl.name)));

        // check args length
        var args = func.Fn.args;
        if (kind != .constructor and args.len == 0) {
            // TODO: handle "class methods"
            @compileError("getter/setter/methods should have at least 1 argument, self");
        }
        if (kind == .getter and args.len > 1) {
            @compileError("getter should have only 1 argument: self");
        }

        // check self special case
        var args_start = 0;
        if (args.len > 0) {
            if (kind != .constructor) {
                // ignore self arg
                args_start = 1;
            }
            if (kind == .setter and args[0].arg_type.? != *T) {
                @compileError("setter first argument should be *self");
            } else if ((kind == .getter or kind == .method) and (args[0].arg_type.? != T)) {
                @compileError("getter/method first argument should be self");
            }
        }

        // check args type
        args = args[args_start..];
        var args_types: [args.len]Type = undefined;
        for (args) |arg, i| {
            args_types[i] = Type{ .T = arg.arg_type.?, .is_optional = isOptional(arg.arg_type.?) };
        }

        // return type
        var return_type: ?Type = null;
        if (func.Fn.return_type != null) {
            return_type = Type{ .T = func.Fn.return_type.?, .is_optional = isOptional(func.Fn.return_type.?) };
        }

        // generate javascript name for field/method
        var field_name: []const u8 = undefined;
        if (kind == .getter) {
            field_name = std.mem.trimLeft(u8, decl.name, "get");
        } else if (kind == .setter) {
            field_name = std.mem.trimLeft(u8, decl.name, "set");
        } else {
            field_name = decl.name;
        }
        const js_name = jsName(field_name);

        // reflect func
        const func_reflected = Func{
            .js_name = js_name,
            .name = decl.name,
            .args = args_types[0..],
            .return_type = return_type,
            .setter_index = null,
        };
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

fn jsName(comptime name: []const u8) []u8 {
    const first = std.ascii.toLower(name[0]);
    var js_name = name[0..].*;
    js_name[0] = first;
    return &js_name;
}
