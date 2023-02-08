const std = @import("std");
const v8 = @import("v8");

const Loop = @import("loop.zig").SingleThreaded;
const cbk = @import("callback.zig");

const i64Num = @import("types.zig").i64Num;
const u64Num = @import("types.zig").u64Num;

// NOTE: all the code in this file should be run comptime.

const builtin_types = [_]type{
    void,
    []u8,
    []const u8,
    f32,
    f64,
    i8,
    i16,
    i32,
    i64,
    i64Num,
    u8,
    u16,
    u32,
    u64,
    u64Num,
    bool,

    // internal types
    std.mem.Allocator,
    *Loop,
    cbk.Func,
    cbk.FuncSync,
    cbk.Arg,
};

pub const Type = struct {
    T: type, // could be pointer or concrete
    name: ?[]const u8, // only for function parameters or union member

    // is this type a builtin or a custom struct?
    // those fields are mutually exclusing
    // ie. if is_bultin => T_refl_index is not null
    // and if T_refl_index == null => is_builtin is true
    is_builtin: bool,
    T_refl_index: ?usize = null,

    optional_T: ?type, // child of an optional type
    union_T: ?[]Type,

    fn lookup(comptime self: *Type, comptime structs: []Struct) void {
        if (self.is_builtin) {
            return;
        }

        // if union, lookup each possible type
        if (self.union_T) |union_types| {
            inline for (union_types) |*tt| {
                tt.lookup(structs);
            }
            return;
        }

        // underlying T
        var T = self.T;
        if (self.optional_T) |optional_T| {
            T = optional_T;
        }

        inline for (structs) |s| {
            if (T == s.T or T == *s.T) {
                self.T_refl_index = s.index;
            }
        }

        if (!self.is_builtin and self.T_refl_index == null) {
            @compileError("reflect error: Type should be either builtin or defined");
        }
    }

    fn reflect(comptime T: type, comptime name: ?[]const u8) Type {
        const info = @typeInfo(T);

        // optional T
        var optional_T: ?type = null;
        if (info == .Optional) {
            optional_T = info.Optional.child;
        }

        // union T
        var union_T: ?[]Type = null;
        if (info == .Union) {
            if (info.Union.tag_type == null) {
                @compileError("reflect error: Union type should be a tagged union");
            }
            var union_types: [info.Union.fields.len]Type = undefined;
            inline for (info.Union.fields) |field, i| {
                union_types[i] = Type.reflect(field.field_type, field.name);
            }
            union_T = &union_types;
        }

        // underlying T
        var underlying_T = T;
        if (optional_T) |child| {
            underlying_T = child;
        }

        // builtin
        var is_builtin = false;
        for (builtin_types) |builtin_T| {
            if (builtin_T == underlying_T) {
                is_builtin = true;
                break;
            }
        }

        return Type{
            .T = T,
            .name = name,
            .is_builtin = is_builtin,
            .optional_T = optional_T,
            .union_T = union_T,
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
        if (std.mem.eql(u8, "_", decl.name[0..1])) {
            return FuncKind.method;
        }
        // exclude declaration less than 6 char
        // ie. non-special getter/setter names
        if (decl.name.len < 4) {
            return FuncKind.ignore;
        }
        if (std.mem.eql(u8, "get_", decl.name[0..4])) {
            return FuncKind.getter;
        }
        if (std.mem.eql(u8, "set_", decl.name[0..4])) {
            return FuncKind.setter;
        }
        return FuncKind.ignore;
    }
};

pub const Func = struct {
    js_name: []const u8,
    name: []const u8,

    // func signature
    args: []Type,
    args_T: type,
    first_optional_arg: ?usize,

    index_offset: usize,

    return_type: Type,

    // async
    callback_index: ?usize,
    args_callback_nb: usize,

    setter_index: ?u8, // TODO: not ideal, is there a cleaner solution?

    fn lookupTypes(comptime self: *Func, comptime structs: []Struct) void {
        inline for (self.args) |*arg| {
            arg.lookup(structs);
        }
        self.return_type.lookup(structs);
    }

    fn reflect(
        comptime T: type,
        comptime kind: FuncKind,
        comptime name: []const u8,
        comptime struct_T: ?type,
    ) Func {

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
        var index_offset: usize = 0;
        var callback_index: ?usize = null;
        var args_callback_nb = 0;
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

            // allocator
            if (args_types[i].T == std.mem.Allocator) {
                index_offset += 1;
            }

            // loop
            if (args_types[i].T == *Loop) {
                index_offset += 1;
            }

            // callback
            // ensure function has only 1 callback as argument
            // TODO: is this necessary?
            if (args_types[i].T == cbk.Func or args_types[i].T == cbk.FuncSync) {
                if (callback_index != null) {
                    @compileError("reflect error: function has already 1 callback");
                }
                callback_index = x;
            }
            if (args_types[i].T == cbk.Arg) {
                args_callback_nb += 1;
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

        // generate javascript name
        var field_name: []const u8 = undefined;
        if (kind == .getter) {
            field_name = std.mem.trimLeft(u8, name, "get_");
        } else if (kind == .setter) {
            field_name = std.mem.trimLeft(u8, name, "set_");
        } else if (kind == .method) {
            field_name = std.mem.trimLeft(u8, name, "_");
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

            // func signature
            .args = args_slice,
            .args_T = args_T,
            .first_optional_arg = first_optional_arg,

            .index_offset = index_offset,

            .return_type = Type.reflect(func.Fn.return_type.?, null),

            // func callback
            .callback_index = callback_index,
            .args_callback_nb = args_callback_nb,

            .setter_index = null,
        };
    }
};

pub const Struct = struct {
    // struct info
    name: []const u8,
    js_name: []const u8,
    T: type,
    mem_layout: std.builtin.Type.ContainerLayout,

    // index on the types list
    index: usize,

    // proto info
    proto_index: ?usize = null,
    proto_T: ?type,

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

    fn lookupTypes(comptime self: *Struct, comptime structs: []Struct) void {
        // TODO: necessary also for constructor?
        inline for (self.getters) |*getter| {
            getter.lookupTypes(structs);
        }
        inline for (self.setters) |*setter| {
            setter.lookupTypes(structs);
        }
        inline for (self.methods) |*method| {
            method.lookupTypes(structs);
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

    fn reflect(comptime T: type, comptime index: usize) Struct {

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
        const struct_name = shortName(T);

        // protoype
        var proto_T: ?type = null;
        if (@hasDecl(T, "prototype")) {
            var T_proto = @field(T, "prototype");
            // check struct has a 'proto' field
            if (!@hasField(T, "proto")) {
                @compileError("reflect error: struct declares a 'prototype' but does not have a 'proto' field");
            }
            // check the 'protoype' declaration is a pointer
            const T_proto_info = @typeInfo(T_proto);
            if (T_proto_info != .Pointer) {
                @compileError("reflect error: struct 'prototype' declared must be a Pointer");
            }
            T_proto = T_proto_info.Pointer.child;
            // check the 'proto' field
            inline for (obj.Struct.fields) |field, i| {
                if (!std.mem.eql(u8, field.name, "proto")) {
                    continue;
                }
                // check the 'proto' field is not a pointer
                if (@typeInfo(field.field_type) == .Pointer) {
                    @compileError("reflect error: struct 'proto' field should not be a Pointer");
                }
                // check the 'proto' field is the same type
                // than the concrete type of the 'prototype' declaration
                if (field.field_type != T_proto) {
                    @compileError("reflect error: struct 'proto' field type is different than 'prototype' declaration");
                }
                // for layout where fields memory order is guarantied,
                // check the 'proto' field is the first one
                if (obj.Struct.layout != .Auto and i != 0) {
                    @compileError("reflect error: struct 'proto' field should be the first one if memory layout is guarantied (packed or extern)");
                }
                break;
            }
            proto_T = T_proto;
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

        return Struct{
            // struct info
            .name = struct_name,
            .js_name = jsName(struct_name),
            .T = T,
            .mem_layout = obj.Struct.layout,

            // index in types list
            .index = index,

            // proto info
            .proto_T = proto_T,

            // struct functions
            .constructor = constructor,
            .getters = getters[0..],
            .setters = setters[0..],
            .methods = methods[0..],

            .alignment = ptr_info.alignment,
            .size = @sizeOf(ptr_info.child),
        };
    }
};

fn lookupPrototype(comptime all: []Struct) void {
    inline for (all) |*s, index| {
        s.index = index;
        if (s.proto_T == null) {
            // does not have a prototype
            continue;
        }
        // loop over all structs to find proto
        inline for (all) |proto, proto_index| {
            if (proto.T != s.proto_T.?) {
                // type is not equal to prototype type
                continue;
            }
            // is proto
            if (s.mem_layout != proto.mem_layout) {
                @compileError("reflect error: struct and proto struct should have the same memory layout");
            }
            s.proto_index = proto_index;
            break;
        }
        if (s.proto_index == null) {
            @compileError("reflect error: could not find the prototype in list");
        }
    }
}

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
        var all: [types_fields.len]Struct = undefined;
        inline for (types_fields) |field, i| {
            const T = @field(types, field.name);
            if (@TypeOf(T) != type) {
                @compileError("reflect error: 'types' should only include types");
            }
            all[i] = Struct.reflect(T, i);
        }

        // look for prototype chain
        // first pass to allow sort
        lookupPrototype(&all);

        // sort to follow prototype chain order
        // ie. parents will be listed before children
        std.sort.sort(Struct, &all, {}, Struct.lessThan);

        // look for prototype chain
        // second pass, as sort as modified the index reference
        lookupPrototype(&all);

        // look Types for corresponding Struct
        inline for (all) |*s| {
            s.lookupTypes(&all);
        }

        return &all;
    }
}

// Utils funcs
// -----------

fn jsName(comptime name: []const u8) []u8 {
    comptime {
        var js_name: [name.len]u8 = undefined;
        js_name[0] = std.ascii.toLower(name[0]);
        for (name) |char, i| {
            if (i == 0) {
                continue;
            }
            js_name[i] = char;
        }
        return &js_name;
    }
}

fn shortName(comptime T: type) []const u8 {
    var it = std.mem.splitBackwards(u8, @typeName(T), ".");
    return it.first();
}

fn itoa(comptime i: u8) ![]u8 {
    comptime {
        var buf: [1]u8 = undefined;
        return try std.fmt.bufPrint(buf[0..], "{d}", .{i});
    }
}
