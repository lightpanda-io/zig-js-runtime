const std = @import("std");
const builtin = @import("builtin");

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
    Loop,
    cbk.Func,
    cbk.FuncSync,
    cbk.Arg,
};

pub const Type = struct {
    T: type, // could be pointer or concrete
    name: ?[]const u8, // not available for return type

    under_T: type,
    is_opt: bool,
    is_ptr: bool,

    // is this type a builtin or a custom struct?
    // those fields are mutually exclusing
    // ie. if is_bultin => T_refl_index is not null
    // and if T_refl_index == null => is_builtin is true
    is_builtin: bool,
    T_refl_index: ?usize = null,

    union_T: ?[]Type,

    fn lookup(comptime self: *Type, comptime structs: []Struct) Error!void {

        // if builtin, lookup is not necessary
        if (self.is_builtin) {
            return;
        }

        // if union, lookup each possible type
        if (self.union_T) |union_types| {
            inline for (union_types) |*tt| {
                try tt.lookup(structs);
            }
            return;
        }

        // check under_T in all structs (and nested structs)
        inline for (structs) |s| {
            if (self.under_T == s.T) {
                self.T_refl_index = s.index;
            }
        }

        if (!self.is_builtin and self.T_refl_index == null) {
            fmtErr("type {s} lookup should be either builtin or defined", .{@typeName(self.T)});
            return error.TypeLookup;
        }
    }

    fn reflect(comptime T: type, comptime name: ?[]const u8) Error!Type {
        const info = @typeInfo(T);

        // union T
        var union_T: ?[]Type = null;
        if (info == .Union) {
            if (info.Union.tag_type == null) {
                fmtErr("type {s} union should be a tagged", .{@typeName(T)});
                return error.TypeTaggedUnion;
            }
            var union_types: [info.Union.fields.len]Type = undefined;
            inline for (info.Union.fields) |field, i| {
                union_types[i] = try Type.reflect(field.field_type, field.name);
            }
            union_T = &union_types;
        }

        // underlying T
        // NOTE: the following cases are handled:
        // - T is a value (under_T = T, is_opt false, is_ptr false)
        // - T is a pointer (under_T = T child, is_opt false, is_ptr true)
        // - T is an optional value (under_T = T child, is_opt true, is_ptr false)
        // - T is an optional pointer (under T = T child child, is_opt true, is_ptr false)
        var under_T: type = undefined;
        var is_opt = false;
        var is_ptr = false;
        if (info == .Optional) {
            is_opt = true;
            const child_info = @typeInfo(info.Optional.child);
            if (child_info == .Pointer) {
                is_ptr = true;
                under_T = child_info.Pointer.child;
            } else {
                under_T = info.Optional.child;
            }
        } else if (info == .Pointer) {
            is_ptr = true;
            under_T = info.Pointer.child;
        } else {
            under_T = T;
        }

        // builtin
        var is_builtin = false;
        for (builtin_types) |builtin_T| {
            if (builtin_T == under_T) {
                is_builtin = true;
                break;
            }
        }

        return Type{
            .T = T,
            .name = name,
            .under_T = under_T,
            .is_opt = is_opt,
            .is_ptr = is_ptr,
            .is_builtin = is_builtin,
            .union_T = union_T,
        };
    }
};

const Args = struct {
    fn reflect(comptime self_T: ?type, comptime args: []Type) type {
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

    fn lookupTypes(comptime self: *Func, comptime structs: []Struct) Error!void {
        inline for (self.args) |*arg| {
            try arg.lookup(structs);
        }
        try self.return_type.lookup(structs);
    }

    fn reflect(
        comptime T: type,
        comptime kind: FuncKind,
        comptime name: []const u8,
        comptime struct_T: ?type,
    ) Error!Func {

        // T should be a func
        const func = @typeInfo(T);
        if (func != .Fn) {
            // should not happen as Funckind.reflect has been called before
            @panic("func is not a function");
        }

        // check args length
        var args = func.Fn.args;
        if (kind != .constructor and args.len == 0) {
            // TODO: handle "class methods"
            fmtErr("getter/setter/methods {s} should have at least 1 argument, self", .{@typeName(T)});
            return error.FuncNoSelf;
        }
        if (kind == .getter and args.len > 1) {
            fmtErr("getter {s} should have only 1 argument: self", .{@typeName(T)});
            return error.FuncGetterMultiArg;
        }

        // self special case (only for methods)
        var args_start = 0;
        var self_T: ?type = null;
        if (struct_T != null and args.len > 0) {
            if (kind != .constructor) {
                // ignore self arg
                args_start = 1;
                self_T = args[0].arg_type.?;
            }
            if (kind == .setter and self_T.? != *struct_T.?) {
                fmtErr("setter {s} first argument should be *self", .{@typeName(T)});
                return error.FuncSetterFirstArgNotSelfPtr;
            } else if ((kind == .getter) and (self_T.? != struct_T.?)) {
                fmtErr("getter {s} first argument should be self", .{@typeName(T)});
                return error.FuncGetterFirstArgNotSelf;
            } else if ((kind == .method)) {
                if (self_T.? != struct_T.? and self_T.? != *struct_T.?) {
                    fmtErr("method {s} first argument should be self or *self", .{@typeName(T)});
                    return error.FuncMethodFirstArgNotSelfOrSelfPtr;
                }
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
                fmtErr("func {s} void parameters are not allowed for now", .{@typeName(T)});
                return error.FuncVoidArg;
            }

            // arg name
            var x = i;
            if (kind != .constructor) {
                x += 1;
            }
            const arg_name = try itoa(x);

            args_types[i] = try Type.reflect(arg.arg_type.?, arg_name);

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
                    fmtErr("func {s} has already 1 callback", .{@typeName(T)});
                    return error.FuncMultiCbk;
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
            if (!args_types[i].is_opt) {
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
        const args_T = comptime Args.reflect(self_T, args_slice);

        return Func{
            .js_name = js_name,
            .name = name,

            // func signature
            .args = args_slice,
            .args_T = args_T,
            .first_optional_arg = first_optional_arg,

            .index_offset = index_offset,

            .return_type = try Type.reflect(func.Fn.return_type.?, null),

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

    fn lookupTypes(comptime self: *Struct, comptime structs: []Struct) Error!void {
        // TODO: necessary also for constructor?
        inline for (self.getters) |*getter| {
            try getter.lookupTypes(structs);
        }
        inline for (self.setters) |*setter| {
            try setter.lookupTypes(structs);
        }
        inline for (self.methods) |*method| {
            try method.lookupTypes(structs);
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

    fn reflect(comptime T: type, comptime index: usize) Error!Struct {

        // T should be a struct
        const obj = @typeInfo(T);
        if (obj != .Struct) {
            fmtErr("type {s} is not a struct", .{@typeName(T)});
            return error.StructNotStruct;
        }

        // T should not be packed
        // as packed struct does not works well for now
        // with unknown memory fields, like slices
        // see: https://github.com/ziglang/zig/issues/2201
        // and https://github.com/ziglang/zig/issues/3133
        if (obj.Struct.layout == .Packed) {
            fmtErr("type {s} packed struct are not supported", .{@typeName(T)});
            return error.StructPacked;
        }

        // struct name
        const struct_name = shortName(T);

        // protoype
        var proto_T: ?type = null;
        if (@hasDecl(T, "prototype")) {
            var T_proto = @field(T, "prototype");

            // check the 'protoype' declaration is a pointer
            const T_proto_info = @typeInfo(T_proto);
            if (T_proto_info != .Pointer) {
                fmtErr("struct {s} 'prototype' declared must be a Pointer", .{@typeName(T)});
                return error.StructPrototypeNotPointer;
            }
            T_proto = T_proto_info.Pointer.child;

            // check struct has a 'proto' field
            if (!@hasField(T, "proto")) {
                fmtErr("struct {s} declares a 'prototype' but does not have a 'proto' field", .{@typeName(T)});
                return error.StructWithoutProto;
            }

            // check the 'proto' field
            inline for (obj.Struct.fields) |field, i| {
                if (!std.mem.eql(u8, field.name, "proto")) {
                    continue;
                }

                // check the 'proto' field is not a pointer
                if (@typeInfo(field.field_type) == .Pointer) {
                    fmtErr("struct {s} 'proto' field should not be a Pointer", .{@typeName(T)});
                    return error.StructProtoPointer;
                }

                // check the 'proto' field is the same type
                // than the concrete type of the 'prototype' declaration
                if (field.field_type != T_proto) {
                    fmtErr("struct {s} 'proto' field is different than 'prototype' declaration", .{@typeName(T)});
                    return error.StructProtoDifferent;
                }

                // for layout where fields memory order is guarantied,
                // check the 'proto' field is the first one
                if (obj.Struct.layout != .Auto and i != 0) {
                    fmtErr("struct {s} 'proto' field should be the first one if memory layout is guarantied (extern)", .{@typeName(T)});
                    return error.StructProtoLayout;
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
            const func_reflected = comptime try Func.reflect(func, kind, decl.name, T);

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

fn lookupPrototype(comptime all: []Struct) Error!void {
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
                // compiler error, should not happen
                @panic("struct and proto struct should have the same memory layout");
            }
            s.proto_index = proto_index;
            break;
        }
        if (s.proto_index == null) {
            fmtErr("struct {s} lookup search of protototype failed", .{@typeName(s.T)});
            return error.StructLookup;
        }
    }
}

pub fn do(comptime types: anytype) Error![]Struct {
    comptime {

        // check types provided
        const types_T = @TypeOf(types);
        const types_info = @typeInfo(types_T);
        if (types_info != .Struct or !types_info.Struct.is_tuple) {
            fmtErr("arg 'types' should be a tuple of types", .{});
            return error.TypesNotTuple;
        }
        const types_fields = types_info.Struct.fields;

        // reflect each type
        var all: [types_fields.len]Struct = undefined;
        inline for (types_fields) |field, i| {
            const T = @field(types, field.name);
            all[i] = try Struct.reflect(T, i);
        }

        // TODO: ensure no duplicates on Struct.name

        // look for prototype chain
        // first pass to allow sort
        try lookupPrototype(&all);

        // sort to follow prototype chain order
        // ie. parents will be listed before children
        std.sort.sort(Struct, &all, {}, Struct.lessThan);

        // look for prototype chain
        // second pass, as sort as modified the index reference
        try lookupPrototype(&all);

        // look Types for corresponding Struct
        inline for (all) |*s| {
            try s.lookupTypes(&all);
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

fn fmtErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        var buf_msg: [200]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf_msg, fmt, args);
        std.debug.print("reflect error: {s}\n", .{msg});
    }
}

// Tests
// -----

const Error = error{
    TypesNotTuple,

    // struct errors
    StructNotStruct,
    StructPacked,
    StructPrototypeNotPointer,
    StructWithoutProto,
    StructProtoPointer,
    StructProtoDifferent,
    StructProtoLayout,
    StructLookup,

    // func errors
    FuncNoSelf,
    FuncGetterMultiArg,
    FuncSetterFirstArgNotSelfPtr,
    FuncGetterFirstArgNotSelf,
    FuncMethodFirstArgNotSelfOrSelfPtr,
    FuncVoidArg,
    FuncMultiCbk,

    // type errors
    TypeTaggedUnion,
    TypeLookup,
};

// ensure reflection fails with an error from Error set
fn ensureErr(arg: anytype, err: Error) !void {
    if (@call(.{}, do, .{arg})) |_| {
        std.debug.print("reflect error: {any}\n", .{arg});
        return error.Reflect;
    } else |e| {
        if (e != err) {
            return error.Reflect;
        }
        std.debug.print("reflect ok: {s}\n", .{@errorName(e)});
    }
}

// structs tests
const TestBase = struct {};
const TestStructPacked = packed struct {};
const TestStructPrototypeNotPointer = struct {
    pub const prototype = TestBase;
};
const TestStructWithoutProto = struct {
    pub const prototype = *TestBase;
};
const TestStructProtoPointer = struct {
    proto: *TestBase,
    pub const prototype = *TestBase;
};
const TestStructProtoDifferent = struct {
    proto: TestStructPacked,
    pub const prototype = *TestBase;
};
const TestBaseExtern = extern struct {};
const TestStructProtoLayout = extern struct {
    val: bool,
    proto: TestBaseExtern,
    pub const prototype = *TestBaseExtern;
};
const TestStructLookup = struct {
    proto: TestBase,
    pub const prototype = *TestBase;
};

// funcs tests
const TestFuncNoSelf = struct {
    pub fn _example() void {}
};
const TestFuncGetterMultiArg = struct {
    pub fn get_example(_: TestFuncGetterMultiArg, _: anytype) void {}
};
const TestFuncSetterFirstArgNotSelfPtr = struct {
    pub fn set_example(_: TestFuncSetterFirstArgNotSelfPtr) void {}
};
const TestFuncGetterFirstArgNotSelf = struct {
    pub fn get_example(_: *TestFuncGetterFirstArgNotSelf) void {}
};
const TestFuncMethodFirstArgNotSelfOrSelfPtr = struct {
    pub fn _example(_: bool) void {}
};
const TestFuncVoidArg = struct {
    pub fn _example(_: TestFuncVoidArg, _: void) void {}
};
const TestFuncMultiCbk = struct {
    pub fn _example(_: TestFuncMultiCbk, _: cbk.Func, _: cbk.Func) void {}
};

// types tests
const TestTaggedUnion = union {
    a: bool,
    b: bool,
};
const TestTypeTaggedUnion = struct {
    pub fn _example(_: TestTypeTaggedUnion, _: TestTaggedUnion) void {}
};
const TestType = struct {};
const TestTypeLookup = struct {
    pub fn _example(_: TestTypeLookup, _: TestType) void {}
};

pub fn tests() !void {

    // arg 'types' should be a tuple of types
    try ensureErr(TestBase, error.TypesNotTuple);

    // each type should be a struct
    try ensureErr(.{@TypeOf(0)}, error.StructNotStruct);

    // struct checks
    try ensureErr(
        .{TestStructPacked},
        error.StructPacked,
    );
    try ensureErr(
        .{TestStructPrototypeNotPointer},
        error.StructPrototypeNotPointer,
    );
    try ensureErr(
        .{TestStructWithoutProto},
        error.StructWithoutProto,
    );
    try ensureErr(
        .{TestStructProtoPointer},
        error.StructProtoPointer,
    );
    try ensureErr(
        .{TestStructProtoDifferent},
        error.StructProtoDifferent,
    );
    try ensureErr(
        .{TestStructProtoLayout},
        error.StructProtoLayout,
    );

    // funcs checks
    try ensureErr(
        .{TestFuncNoSelf},
        error.FuncNoSelf,
    );
    try ensureErr(
        .{TestFuncGetterMultiArg},
        error.FuncGetterMultiArg,
    );
    try ensureErr(
        .{TestFuncSetterFirstArgNotSelfPtr},
        error.FuncSetterFirstArgNotSelfPtr,
    );
    try ensureErr(
        .{TestFuncGetterFirstArgNotSelf},
        error.FuncGetterFirstArgNotSelf,
    );
    try ensureErr(
        .{TestFuncMethodFirstArgNotSelfOrSelfPtr},
        error.FuncMethodFirstArgNotSelfOrSelfPtr,
    );
    try ensureErr(
        .{TestFuncVoidArg},
        error.FuncVoidArg,
    );
    try ensureErr(
        .{TestFuncMultiCbk},
        error.FuncMultiCbk,
    );

    // types checks
    try ensureErr(
        .{TestTypeTaggedUnion},
        error.TypeTaggedUnion,
    );

    // lookups checks
    try ensureErr(
        .{TestStructLookup},
        error.StructLookup,
    );
    try ensureErr(
        .{TestTypeLookup},
        error.TypeLookup,
    );
}
