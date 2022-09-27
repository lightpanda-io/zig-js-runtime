const std = @import("std");
const v8 = @import("v8");

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

pub const FuncReflected = struct {
    js_name: []const u8,
    name: []const u8,
    args: []type,
    return_type: ?type,

    setter_index: ?u8, // TODO: not ideal, is there a cleaner solution?
};

pub const StructReflected = struct {
    name: []const u8,

    constructor: ?FuncReflected,

    getters: []FuncReflected,
    setters: []FuncReflected,
    methods: []FuncReflected,

    alignment: u29,
    size: usize,
};

// This function must be called comptime
pub fn Struct(comptime T: type) StructReflected {

    // T should be a struct
    const obj = @typeInfo(T);
    if (obj != .Struct) {
        @compileError("type provided is not a struct");
    }

    // struct name
    var it = std.mem.splitBackwards(u8, @typeName(T), ".");
    const struct_name = it.first();

    // retrieve the number of each function kind
    var getters_nb: i8 = 0;
    var setters_nb: i8 = 0;
    var methods_nb: i8 = 0;

    // iterate over struct declarations
    // struct fields are considerated private and ignored
    // first iteration to retrieve the number of each function kind
    inline for (obj.Struct.decls) |decl| {
        const kind = comptime checkFuncKind(T, decl);
        switch (kind) {
            .ignore => continue,
            .constructor => {},
            .getter => getters_nb += 1,
            .setter => setters_nb += 1,
            .method => methods_nb += 1,
        }
    }

    var constructor: ?FuncReflected = null;
    var getters: [getters_nb]FuncReflected = undefined;
    var setters: [setters_nb]FuncReflected = undefined;
    var methods: [methods_nb]FuncReflected = undefined;

    var getters_done: i8 = 0;
    var setters_done: i8 = 0;
    var methods_done: i8 = 0;

    // iterate over struct declarations
    // second iteration to generate funcs
    inline for (obj.Struct.decls) |decl| {

        // check declaration kind
        const kind = comptime checkFuncKind(T, decl);
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
        var args_types: [args.len]type = undefined;
        for (args) |arg, i| {
            args_types[i] = arg.arg_type.?;
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
        const func_reflected = FuncReflected{
            .js_name = js_name,
            .name = decl.name,
            .args = args_types[0..],
            .return_type = func.Fn.return_type,
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
    return StructReflected{
        .name = struct_name,
        .constructor = constructor,
        .getters = getters[0..],
        .setters = setters[0..],
        .methods = methods[0..],
        .alignment = ptr_info.alignment,
        .size = @sizeOf(ptr_info.child),
    };
}

fn jsName(comptime name: []const u8) []u8 {
    const first = std.ascii.toLower(name[0]);
    var js_name = name[0..].*;
    js_name[0] = first;
    return &js_name;
}
