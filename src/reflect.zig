const std = @import("std");
const sort = @import("block.zig");
const builtin = @import("builtin");

const public = @import("api.zig");
const Variadic = public.Variadic;
const Loop = public.Loop;
const Callback = public.Callback;
const CallbackSync = public.CallbackSync;
const CallbackArg = public.CallbackArg;

const i64Num = public.i64Num;
const u64Num = public.u64Num;

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
};

const internal_types = [_]type{
    std.mem.Allocator,
    Loop,
    Callback,
    CallbackSync,
    CallbackArg,
};

// Type describes the reflect information of an individual value, either:
// - an input parameter of a function
// - or a return value of a function
pub const Type = struct {
    T: type, // could be pointer or concrete
    name: ?[]const u8, // not available for return type

    // is this a custom struct (native or nested)?
    T_refl_index: ?usize = null,
    nested_index: ?usize = null, // T_refl_index is mandatory in this case

    union_T: ?[]Type,

    pub inline fn isNative(comptime self: Type) bool {
        comptime {
            return self.T_refl_index != null and self.nested_index == null;
        }
    }

    pub fn isErrorException(comptime self: Type, comptime exception: Struct, err: anytype) bool {
        const errSet = self.errorSet().?;
        const exceptSet = @field(exception.T, "ErrorSet");

        // check if the ErrorSet of the return type is the same than the exception
        if (comptime exceptSet == errSet) return true;

        // check if the error returned is part of the exception
        // (ie. the ErrorSet of the return type is a superset of the exception)
        const errName = @errorName(err);
        for (@typeInfo(exceptSet).ErrorSet.?) |e| {
            if (std.mem.eql(u8, errName, e.name)) {
                return true;
            }
        }
        return false;
    }

    // If the Type is an ErrorUnion, returns it's ErrorSet
    pub fn errorSet(comptime self: Type) ?type {
        std.debug.assert(@inComptime());
        if (@typeInfo(self.T) != .ErrorUnion) {
            return null;
        }
        return @typeInfo(self.T).ErrorUnion.error_set;
    }

    // NOTE: underlying types
    // ----------------------
    // The logic with underlying types is that a concrete Zig type
    // can be encapsulated by several layers of syntax, sometimes additionaly:
    // - an error union -> !T
    // - an optional type -> ?T
    // - a pointer -> *T
    // And of course those can add themselves, eg. !?*T
    // We need to get information about:
    // - the original type, ie. the complete one
    // - the underlying type, ie. the concrete one
    // - and all the successive stages

    // !Type
    fn _underErr(comptime T: type) ?type {
        const info = @typeInfo(T);
        if (info != .ErrorUnion) {
            return null;
        }
        return info.ErrorUnion.payload;
    }
    pub inline fn underErr(comptime self: Type) ?type {
        std.debug.assert(@inComptime());
        return Type._underErr(self.T);
    }

    // !?Type (from underErr)
    // ?Type
    fn _underOpt(comptime T: type) ?type {
        const TT = Type._underErr(T) orelse T;
        const info = @typeInfo(TT);
        if (info != .Optional) {
            return null;
        }
        return info.Optional.child;
    }
    pub inline fn underOpt(comptime self: Type) ?type {
        std.debug.assert(@inComptime());
        return Type._underOpt(self.T);
    }

    // !?*Type, ?*Type (from underOpt)
    // !*Type (from underErr)
    // *Type
    fn _underPtr(comptime T: type) ?type {
        var TT: type = undefined;
        if (Type._underOpt(T)) |t| {
            TT = t;
        } else if (Type._underErr(T)) |t| {
            TT = t;
        } else {
            TT = T;
        }
        const info = @typeInfo(TT);
        if (info == .Pointer and info.Pointer.size != .Slice) {
            // NOTE: slice are pointers but we handle them as single value
            return info.Pointer.child;
        }
        return null;
    }
    pub inline fn underPtr(comptime self: Type) ?type {
        std.debug.assert(@inComptime());
        return Type._underPtr(self.T);
    }

    // !?*Type, ?*Type, !*Type, *Type (from underPtr)
    // !?Type, ?Type (from underOpt)
    // !Type (from underErr)
    // Type
    fn _underT(comptime T: type) type {
        if (Type._underPtr(T)) |TT| return TT;
        if (Type._underOpt(T)) |TT| return TT;
        if (Type._underErr(T)) |TT| return TT;
        return T;
    }
    pub inline fn underT(comptime self: Type) type {
        std.debug.assert(@inComptime());
        return Type._underT(self.T);
    }

    // find if T is a VariadicType
    // and returns the type of the slice members
    fn _variadic(comptime T: type) ?type {
        std.debug.assert(@inComptime());
        const info = @typeInfo(T);

        // it's a struct
        if (info != .Struct) {
            return null;
        }

        // with only 1 field
        if (info.Struct.fields.len != 1) {
            return null;
        }

        // which is called "slice"
        const slice_field = info.Struct.fields[0];
        if (!std.mem.eql(u8, slice_field.name, "slice")) {
            return null;
        }

        // and it's a slice
        const slice_info = @typeInfo(slice_field.type);
        if (slice_info == .Pointer and slice_info.Pointer.size == .Slice) {
            return slice_info.Pointer.child;
        }

        return null;
    }

    fn _is_variadic(comptime T: type) bool {
        return Type._variadic(T) != null;
    }

    // find if T is a VariadicType
    // and returns it as a reflect.Type
    pub fn variadic(comptime T: type) !?Type {
        std.debug.assert(@inComptime());

        const tt = Type._variadic(T) orelse return null;

        // avoid infinite calls
        if (Type._is_variadic(tt)) return error.TypeVariadicNested;

        return try Type.reflect(tt, null);
    }

    // check that user-defined types have been provided as an API
    fn lookup(comptime self: *Type, comptime structs: []Struct) Error!void {

        // lookup unecessary
        for (builtin_types) |builtin_T| {
            if (builtin_T == self.underT()) {
                return;
            }
        }
        for (internal_types) |internal_T| {
            if (internal_T == self.underT()) {
                return;
            }
        }

        // if union, lookup each possible type
        if (self.union_T) |union_types| {
            inline for (union_types) |*tt| {
                try tt.lookup(structs);
            }
            return;
        }

        // if variadic, lookup the concrete type
        var variadic_type = try Type.variadic(self.underT());
        if (variadic_type) |*tt| {
            return tt.lookup(structs);
        }

        // check under_T in all structs (and nested structs)
        inline for (structs) |s| {
            if (self.underT() == s.T or self.underT() == s.Self()) {
                self.T_refl_index = s.index;
                break;
            }
            inline for (s.nested, 0..) |nested, i| {
                if (self.underT() == nested.T) {
                    if (self.underPtr() != null) {
                        const msg = "pointer on nested struct is not allowed, choose a type struct for this use case";
                        fmtErr(msg.len, msg, self.T);
                        return error.TypeNestedPtr;
                    }
                    self.T_refl_index = s.index;
                    self.nested_index = i;
                    break;
                }
            }
            if (self.nested_index != null) {
                break;
            }
        }

        if (self.T_refl_index == null and self.nested_index == null) {
            const msg = "lookup should be either builtin or defined";
            fmtErr(msg.len, msg, self.T);
            return error.TypeLookup;
        }
    }

    fn reflectUnion(comptime T: type, comptime info: std.builtin.Type) Error![]Type {
        if (info.Union.tag_type == null) {
            const msg = "union should be a tagged";
            fmtErr(msg.len, msg, T);
            return error.TypeTaggedUnion;
        }
        var union_types: [info.Union.fields.len]Type = undefined;
        inline for (info.Union.fields, 0..) |field, i| {
            union_types[i] = try Type.reflect(field.type, field.name);
        }
        return &union_types;
    }

    fn reflect(comptime T: type, comptime name: ?[]const u8) Error!Type {
        const info = @typeInfo(Type._underT(T));

        // union T
        var union_T: ?[]Type = null;
        if (info == .Union) {
            union_T = try reflectUnion(T, info);
        }

        // variadic types must be optional
        if (Type._underOpt(T) == null) {
            const under = Type._underT(T);
            if (Type._is_variadic(under)) {
                return error.TypeVariadicNotOptional;
            }
        }

        var t = Type{
            .T = T,
            .name = name,
            .union_T = union_T,
        };
        return t;
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
                .type = self_T.?,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(self_T.?),
            };
        }
        inline for (args, 0..) |arg, i| {
            var x = i;
            if (self_T != null) {
                x += 1;
            }
            fields[x] = std.builtin.Type.StructField{
                .name = arg.name.?,
                .type = arg.T,
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

const Symbol = enum {
    iterator,
    string_tag,

    fn reflect(comptime name: []const u8) ?Symbol {
        if (std.mem.eql(u8, name, "_symbol_iterator")) {
            return Symbol.iterator;
        } else if (std.mem.eql(u8, name, "get_symbol_toStringTag")) {
            return Symbol.string_tag;
        }
        return null;
    }
};

const FuncKind = enum {
    ignore,
    constructor,
    getter,
    setter,
    method,

    fn reflect(comptime T: type, decl: std.builtin.Type.Declaration) FuncKind {
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

    // symbol
    symbol: ?Symbol,

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

        // check self is present
        var args = func.Fn.params;
        if (kind != .constructor and args.len == 0) {
            // TODO: handle "class methods"
            const msg = "getter/setter/methods should have at least 1 argument, self";
            fmtErr(msg.len, msg, T);
            return error.FuncNoSelf;
        }

        // self special case (only for methods)
        var args_start = 0;
        var self_T: ?type = null;
        if (struct_T != null and args.len > 0) {
            if (kind != .constructor) {
                // ignore self arg
                args_start = 1;
                self_T = args[0].type.?;
            }
            if (kind == .setter and self_T.? != *struct_T.?) {
                const msg = "setter first argument should be *self";
                fmtErr(msg.len, msg, T);
                return error.FuncSetterFirstArgNotSelfPtr;
            } else if (kind == .method or kind == .getter) {
                if (self_T.? != struct_T.? and self_T.? != *struct_T.?) {
                    const msg = "getter/method first argument should be self or *self";
                    fmtErr(msg.len, msg, T);
                    return error.FuncGetterMethodFirstArgNotSelfOrSelfPtr;
                }
            }
        }

        // args type
        args = args[args_start..];
        var args_types: [args.len]Type = undefined;
        var index_offset: usize = 0;
        var callback_index: ?usize = null;
        var args_callback_nb = 0;
        for (args, 0..) |arg, i| {
            if (arg.type.? == void) {
                // TODO: there is a bug with void paramater => avoid for now
                const msg = "func void parameters are not allowed for now";
                fmtErr(msg.len, msg, T);
                return error.FuncVoidArg;
            }

            // arg name
            var x = i;
            if (kind != .constructor) {
                x += 1;
            }
            const arg_name = try itoa(x);

            args_types[i] = try Type.reflect(arg.type.?, arg_name);

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
            if (args_types[i].T == Callback or args_types[i].T == CallbackSync) {
                if (callback_index != null) {
                    const msg = "func has already 1 callback";
                    fmtErr(msg.len, msg, T);
                    return error.FuncMultiCbk;
                }
                callback_index = x;
            }
            if (args_types[i].T == CallbackArg) {
                args_callback_nb += 1;
            }

            // variadic
            // ensure only 1 variadic argument
            // and that it's the last one
            if (Type._is_variadic(args_types[i].underT()) and i < (args.len - 1)) {
                return error.FuncVariadicNotLastOne;
            }

            // error union prohibited for args
            if (args_types[i].underErr() != null) {
                return error.FuncErrorUnionArg;
            }
        }

        // check getter and setter internal argument is an allocator
        if (kind == .getter or kind == .setter) {
            if (index_offset == 1) {
                if (args[0].type.? != std.mem.Allocator) {
                    const msg = "getter/setter non-internal argument should be an allocator";
                    fmtErr(msg.len, msg, T);
                    return error.FuncGetterSetterNotAllocator;
                }
            }
        }

        const js_args_nb = args.len - index_offset;

        // check getter has no js arg
        if (kind == .getter and js_args_nb > 0) {
            const msg = "getter should have only 1 JS argument: self";
            fmtErr(msg.len, msg, T);
            return error.FuncGetterMultiArg;
        }

        // check setter has at least one js arg
        if (kind == .setter and js_args_nb == 0) {
            const msg = "setter should have 1 JS argument";
            fmtErr(msg.len, msg, T);
            return error.FuncSetterNoArg;
        }

        // first optional arg
        var first_optional_arg: ?usize = null;
        var i = args_types.len;
        while (i > 0) {
            i -= 1;
            if (args_types[i].underOpt() == null) {
                break;
            }
            first_optional_arg = i;
        }

        // generate javascript name
        var field_name: []const u8 = undefined;
        if (kind == .getter or kind == .setter) {
            field_name = name[4..name.len]; // remove get_ and set_
        } else if (kind == .method) {
            field_name = name[1..name.len]; // remove _
        } else {
            field_name = name;
        }
        const js_name = jsName(field_name);

        // reflect args
        const args_slice = args_types[0..];
        const args_T = comptime Args.reflect(self_T, args_slice);

        // reflect return type
        const return_type = try Type.reflect(func.Fn.return_type.?, null);
        if (Type._is_variadic(return_type.underT())) return error.FuncReturnTypeVariadic;

        return Func{
            .js_name = js_name,
            .name = name,

            // func signature
            .args = args_slice,
            .args_T = args_T,
            .first_optional_arg = first_optional_arg,

            .index_offset = index_offset,

            .return_type = return_type,

            // func callback
            .callback_index = callback_index,
            .args_callback_nb = args_callback_nb,

            // symbol
            .symbol = Symbol.reflect(name),

            .setter_index = null,
        };
    }
};

pub const StructNested = struct {
    T: type,
    fields: []Type,

    fn isNested(comptime T: type, comptime decl: std.builtin.Type.Declaration) bool {
        // special keywords
        // TODO: and "prototype"?
        if (std.mem.eql(u8, decl.name, "Self")) {
            return false;
        } else if (std.mem.eql(u8, decl.name, "mem_guarantied")) {
            return false;
        }

        // exclude declarations who are not types
        const decl_type = @field(T, decl.name);
        if (@TypeOf(decl_type) != type) {
            return false;
        }

        // exclude types who are not structs
        if (@typeInfo(decl_type) != .Struct) {
            return false;
        }

        return true;
    }

    fn reflect(comptime T: type) StructNested {
        const info = @typeInfo(T);

        var fields: [info.Struct.fields.len]Type = undefined;
        inline for (info.Struct.fields, 0..) |field, i| {
            fields[i] = try Type.reflect(field.type, field.name);
        }
        return .{ .T = T, .fields = &fields };
    }
};

pub const Struct = struct {
    // struct info
    name: []const u8,
    js_name: []const u8,
    string_tag: bool,
    T: type,
    self_T: ?type,
    value: Type,
    mem_guarantied: bool,

    // index on the types list
    index: usize,

    // proto info
    proto_index: ?usize = null,
    proto_T: ?type,

    // static attributes
    static_attrs_T: ?type,

    // struct functions
    has_constructor: bool,
    constructor: Func,

    getters: []Func,
    setters: []Func,
    methods: []Func,

    // nested types
    nested: []StructNested,

    pub fn Self(comptime self: Struct) type {
        comptime {
            if (self.self_T) |T| {
                return T;
            }
            return self.T;
        }
    }

    pub fn is_mem_guarantied(comptime self: Struct) bool {
        comptime {
            if (self.mem_guarantied) {
                return true;
            }
            return self.hasProtoCast();
        }
    }

    pub fn hasProtoCast(comptime self: Struct) bool {
        // TODO: we should check the entire proto chain
        comptime {
            if (self.proto_T) |T| {
                if (@hasDecl(T, "protoCast")) {
                    return true;
                }
            } else if (@hasDecl(self.T, "protoCast")) {
                return true;
            }
            return false;
        }
    }

    pub inline fn isEmpty(comptime self: Struct) bool {
        if (@typeInfo(self.Self()) == .Opaque) {
            return false;
        }
        return @sizeOf(self.Self()) == 0;
    }

    fn lookupTypes(comptime self: *Struct, comptime structs: []Struct) Error!void {
        if (self.has_constructor) {
            try self.constructor.lookupTypes(structs);
        }
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
            if (a.proto_T.? == b.T) {
                // NOTE: By definition, if we compare:
                // - A which has a proto B
                // - And B itself
                // => A is after B as it requires B
                return false;
            }
            return a.proto_index.? < b.proto_index.?;
        }
        return a.proto_index == null;
    }

    fn AttrT(comptime T: type, comptime decl: std.builtin.Type.Declaration) ?type {
        // exclude declarations not starting with _
        if (decl.name[0] != '_') {
            return null;
        }
        // exclude declarations of wrong type
        const attr_T = @TypeOf(@field(T, decl.name));
        const attr_info = @typeInfo(attr_T);
        if (attr_info == .Fn) { // functions
            return null;
        }
        for (builtin_types) |builtin_T| {
            if (builtin_T == attr_T) {
                return attr_T;
            }
        }
        // string literal
        if (isStringLiteral(attr_T)) {
            return []const u8;
        }
        const value = @field(T, decl.name);
        // comptime_int
        if (attr_T == comptime_int) {
            if (value > 0) {
                if (value <= 255) {
                    return u8;
                } else if (value <= 65_535) {
                    return u16;
                } else if (value <= 4_294_967_295) {
                    return u32;
                } else {
                    return u64;
                }
            } else {
                if (value >= -128) {
                    return i8;
                } else if (value >= -32_768) {
                    return i16;
                } else if (value >= -2_147_483_648) {
                    return i32;
                } else {
                    return i64;
                }
            }
        }
        // TODO: comptime_float
        @compileLog(attr_T);
        @compileError("static attribute type not handled");
    }

    fn reflectAttrs(comptime T: type) ?type {
        const decls = @typeInfo(T).Struct.decls;

        // first pass for attrs nb
        var attrs_nb = 0;
        for (decls) |decl| {
            if (AttrT(T, decl) == null) {
                continue;
            }
            attrs_nb += 1;
        }
        if (attrs_nb == 0) {
            return null;
        }

        // second pass to build attrs type
        var fields: [attrs_nb]std.builtin.Type.StructField = undefined;
        var attrs_done = 0;
        for (decls) |decl| {
            const attr_T = AttrT(T, decl);
            if (attr_T == null) {
                continue;
            }
            fields[attrs_done] = std.builtin.Type.StructField{
                .name = decl.name[1..decl.name.len], // remove _
                .type = attr_T.?,
                .default_value = null,
                .is_comptime = false, // TODO: should be true here?
                .alignment = if (@sizeOf(attr_T.?) > 0) @alignOf(attr_T.?) else 0,
            };
            attrs_done += 1;
        }
        return @Type(.{
            .Struct = .{
                .layout = .Auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    }

    pub fn staticAttrs(comptime self: Struct, comptime attrs_T: type) attrs_T {
        var attrs: attrs_T = undefined;
        var done = 0;
        for (@typeInfo(self.T).Struct.decls) |decl| {
            const attr_T = AttrT(self.T, decl);
            if (attr_T == null) {
                continue;
            }
            const name = decl.name[1..decl.name.len]; // remove _
            const value = @as(attr_T.?, @field(self.T, decl.name));
            @field(attrs, name) = value;
            done += 1;
        }
        return attrs;
    }

    // Is the T a well-formed exception?
    fn _checkException(comptime T: type, isErr: bool) Error!void {

        // check ErrorSet
        if (!@hasDecl(T, "ErrorSet")) {
            return error.StructExceptionWithoutErrorSet;
        }
        const errSet = @field(T, "ErrorSet");
        if (@typeInfo(errSet) != .ErrorSet) {
            return error.StructExceptionWrongErrorSet;
        }

        // check interface methods
        const err = error.StructExceptionWrongInterface;
        if (!isDecl(
            T,
            "init",
            fn (_: std.mem.Allocator, _: errSet, _: []const u8) anyerror!T,
            isErr,
        )) return err;
        if (!isDecl(T, "get_name", fn (_: T) []const u8, isErr)) return err;
        if (!isDecl(T, "get_message", fn (_: T) []const u8, isErr)) return err;
    }

    // Is the API an exception?
    pub fn isException(comptime self: Struct) bool {
        std.debug.assert(@inComptime());
        // it's an exception if the check does not return an error
        Struct._checkException(self.T, false) catch return false;
        return true;
    }

    // Does the T has an exception?
    fn _hasException(comptime T: type) Error!?type {
        if (!@hasDecl(T, "Exception")) {
            return null;
        }
        const exceptT = @field(T, "Exception");
        try Struct._checkException(exceptT, true);
        return exceptT;
    }

    // Retrieve the optional Exception of the API,
    // including from prototype chain
    pub fn exception(comptime self: Struct, comptime all: []Struct) ?Struct {
        std.debug.assert(@inComptime());

        // errors have already been checked at lookup stage
        if (Struct._hasException(self.T) catch unreachable) |T| {
            for (all) |s| {
                if (s.T == T) return s;
            }
        }

        // to avoid verbose declaration we allow Exception to be declared
        // on the prototype chain
        if (self.proto_index) |idx| {
            return all[idx].exception(all);
        }

        return null;
    }

    fn reflectProto(comptime T: type, comptime real_T: type) Error!?type {

        // check the 'protoype' declaration
        if (!@hasDecl(T, "prototype")) {
            return null;
        }

        var proto_T: ?type = null;

        // check the 'protoype' declaration is a pointer
        const proto_info = @typeInfo(@field(T, "prototype"));
        if (proto_info != .Pointer) {
            const msg = "struct 'prototype' declared must be a Pointer";
            fmtErr(msg.len, msg, T);
            return error.StructPrototypeNotPointer;
        }
        proto_T = proto_info.Pointer.child;

        if (@hasDecl(T, "mem_guarantied")) {
            return proto_T;
        }

        var proto_res: type = undefined;

        if (@hasField(real_T, "proto")) {

            // check the 'proto' field
            inline for (@typeInfo(real_T).Struct.fields, 0..) |field, i| {
                if (!std.mem.eql(u8, field.name, "proto")) {
                    continue;
                }

                // check the 'proto' field is not a pointer
                if (@typeInfo(field.type) == .Pointer) {
                    const msg = "struct {s} 'proto' field should not be a Pointer";
                    fmtErr(msg.len, msg, T);
                    return error.StructProtoPointer;
                }

                // for layout where fields memory order is guarantied,
                // check the 'proto' field is the first one
                if (@typeInfo(T).Struct.layout != .Auto) {
                    if (i != 0) {
                        const msg = "'proto' field should be the first one if memory layout is guarantied (extern)";
                        fmtErr(msg.len, msg, T);
                        return error.StructProtoLayout;
                    }
                }

                proto_res = field.type;
                break;
            }
        } else if (@hasDecl(proto_T.?, "protoCast")) {

            // check that 'protoCast' is a compatible function
            const proto_func = @typeInfo(@TypeOf(@field(proto_T.?, "protoCast")));
            if (proto_func != .Fn) {
                return error.StructProtoCastNotFunction;
            } else {
                const proto_args = proto_func.Fn.params;
                if (proto_args.len != 1) {
                    return error.StructProtoCastWrongFunction;
                }
                if (!proto_args[0].is_generic) {
                    // should be anytype
                    // as the prototype has no idea which one of his 'children'
                    // is going to call protoCast()
                    return error.StructProtoCastWrongFunction;
                }
            }
            const ret_T = proto_func.Fn.return_type.?;

            // can be a pointer or a value
            const ret_T_info = @typeInfo(ret_T);
            if (ret_T_info == .Pointer) {
                proto_res = ret_T_info.Pointer.child;
            } else {
                proto_res = ret_T;
            }
        } else {
            const msg = "struct declares a 'prototype' but does not have a 'proto' field neither prototype has 'protoCast' function";
            fmtErr(msg.len, msg, T);
            return error.StructWithoutProto;
        }

        // check the 'proto' result is the same type than the 'prototype' declaration
        var compare_T: type = undefined;
        if (@hasDecl(proto_T.?, "Self")) {
            compare_T = @field(proto_T.?, "Self");
        } else {
            compare_T = proto_T.?;
        }
        if (proto_res != compare_T) {
            const msg = "struct 'proto' field is different than 'prototype' declaration";
            fmtErr(msg.len, msg, T);
            return error.StructProtoDifferent;
        }
        return proto_T;
    }

    fn reflect(comptime T: type, comptime index: usize) Error!Struct {

        // T should be a struct
        const obj = @typeInfo(T);
        if (obj != .Struct) {
            const msg = "type is not a struct";
            fmtErr(msg.len, msg, T);
            return error.StructNotStruct;
        }

        // T should not be packed
        // as packed struct does not works well for now
        // with unknown memory fields, like slices
        // see: https://github.com/ziglang/zig/issues/2201
        // and https://github.com/ziglang/zig/issues/3133
        if (obj.Struct.layout == .Packed) {
            const msg = "type packed struct are not supported";
            fmtErr(msg.len, msg, T);
            return error.StructPacked;
        }

        // self type
        var self_T: ?type = null;
        var real_T: type = undefined;
        if (@hasDecl(T, "Self")) {
            self_T = @field(T, "Self");
            real_T = self_T.?;
            if (@typeInfo(real_T) == .Pointer) {
                const msg = "type Self type should not be a pointer";
                fmtErr(msg.len, msg, T);
                return error.StructSelfPointer;
            }
        } else {
            real_T = T;
        }
        if (@typeInfo(real_T) != .Struct and @typeInfo(real_T) != .Opaque) {
            const msg = "type is not a struct or opaque";
            fmtErr(msg.len, msg, T);
            return error.StructNotStruct;
        }

        // struct name
        const struct_name = shortName(T);

        // protoype
        const proto_T = try Struct.reflectProto(T, real_T);
        var mem_guarantied: bool = undefined;
        if (@hasDecl(T, "mem_guarantied")) {
            mem_guarantied = true;
        } else {
            mem_guarantied = @typeInfo(T).Struct.layout != .Auto;
        }

        // nested types
        var nested_nb: usize = 0;
        // first iteration to retrieve the number of nested structs
        inline for (obj.Struct.decls) |decl| {
            if (StructNested.isNested(T, decl)) {
                nested_nb += 1;
            }
        }
        var nested: [nested_nb]StructNested = undefined;
        if (nested_nb > 0) {
            var nested_done: usize = 0;
            inline for (obj.Struct.decls) |decl| {
                if (StructNested.isNested(T, decl)) {
                    const decl_type = @field(T, decl.name);
                    nested[nested_done] = StructNested.reflect(decl_type);
                    nested_done += 1;
                }
            }
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

        var constructor: Func = undefined;
        var has_constructor = false;
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
            const func_reflected = comptime try Func.reflect(func, kind, decl.name, real_T);

            switch (kind) {
                .constructor => {
                    constructor = func_reflected;
                    has_constructor = true;
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

        for (&getters) |*getter| {
            var setter_index: ?u8 = null;
            for (setters, 0..) |setter, i| {
                if (std.mem.eql(u8, getter.js_name, setter.js_name)) {
                    setter_index = i;
                    break;
                }
            }
            if (setter_index != null) {
                getter.setter_index = setter_index;
            }
        }

        // string tag
        var string_tag: bool = false;
        for (getters) |getter| {
            if (getter.symbol) |symbol| {
                if (symbol == .string_tag) {
                    string_tag = true;
                    break;
                }
            }
        }

        return Struct{
            // struct info
            .name = struct_name,
            .js_name = jsName(struct_name),
            .string_tag = string_tag,
            .T = T,
            .self_T = self_T,
            .value = try Type.reflect(real_T, null),
            .static_attrs_T = Struct.reflectAttrs(T),
            .mem_guarantied = mem_guarantied,

            // index in types list
            .index = index,

            // proto info
            .proto_T = proto_T,

            // struct functions
            .has_constructor = has_constructor,
            .constructor = constructor,
            .getters = getters[0..],
            .setters = setters[0..],
            .methods = methods[0..],

            // nested types
            .nested = nested[0..],
        };
    }
};

fn lookupPrototype(comptime all: []Struct) Error!void {
    inline for (all, 0..) |*s, index| {
        s.index = index;
        if (s.proto_T == null) {
            // does not have a prototype
            continue;
        }
        // loop over all structs to find proto
        inline for (all, 0..) |proto, proto_index| {
            if (proto.T != s.proto_T.?) {
                // type is not equal to prototype type
                continue;
            }
            // is proto
            if (s.mem_guarantied != proto.mem_guarantied) {
                // compiler error, should not happen
                // TODO: check mem_guarantied
                @panic("struct and proto struct should have the same memory layout");
            }
            s.proto_index = proto_index;
            break;
        }
        if (s.proto_index == null) {
            const msg = "struct lookup search of protototype failed";
            fmtErr(msg.len, msg, s.T);
            return error.StructLookup;
        }
    }
}

fn lookupDuplicates(comptime all: []Struct) Error!void {
    std.debug.assert(@inComptime());
    for (all, 0..) |s, i| {
        for (all[i + 1 ..]) |other_s| {

            // not only checking types but Self types
            // otherwise different Struct could refer to the same Self type
            // creating bugs in Type lookup (ie. Type.T_refl_index)
            if (s.Self() == other_s.Self()) {
                const msg = "duplicate of type (or self type) for " ++ @typeName(s.T) ++ " and " ++ @typeName(other_s.T);
                fmtErr(msg.len, msg, s.Self());
                return error.StructDuplicateType;
            }

            // in JS name the path of the type is removed, therefore duplicates are possibles
            if (std.mem.eql(u8, s.js_name, other_s.js_name)) {
                const msg = "duplicate of JS name for " ++ @typeName(s.T) ++ " and " ++ @typeName(other_s.T);

                fmtErr(msg.len, msg, s.Self());
                return error.StructDuplicateName;
            }
        }
    }
}

fn lookupException(comptime all: []Struct) Error!void {
    outer: for (all) |s| {
        if (try Struct._hasException(s.T)) |T| {
            for (all) |st| {
                if (st.T == T) {
                    continue :outer;
                }
            }
            return error.StructExceptionDoesNotExist;
        }
    }
}

pub fn do(comptime types: anytype) Error![]Struct {
    comptime {

        // check types provided
        const types_T = @TypeOf(types);
        const types_info = @typeInfo(types_T);
        if (types_info != .Struct or !types_info.Struct.is_tuple) {
            const msg = "arg 'types' should be a tuple of types";
            fmtErr(msg.len, msg, types_T);
            return error.TypesNotTuple;
        }
        const types_fields = types_info.Struct.fields;

        // reflect each type
        var all: [types_fields.len]Struct = undefined;
        inline for (types_fields, 0..) |field, i| {
            const T = @field(types, field.name);
            all[i] = try Struct.reflect(T, i);
        }

        // look for duplicates (on types and js names)
        try lookupDuplicates(&all);

        // look for prototype chain
        // first pass to allow sort
        try lookupPrototype(&all);

        // sort to follow prototype chain order
        // ie. parents will be listed before children
        sort.block(Struct, &all, {}, Struct.lessThan);

        // look for prototype chain
        // second pass, as sort as modified the index reference
        try lookupPrototype(&all);

        // look for exception
        try lookupException(&all);

        // look Types for corresponding Struct
        inline for (&all) |*s| {
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
        for (name, 0..) |char, i| {
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

fn isStringLiteral(comptime T: type) bool {
    // string literals are const pointers to null-terminated arrays of u8
    if (@typeInfo(T) != .Pointer) {
        return false;
    }
    const elem = std.meta.Elem(T);
    if (elem != u8) {
        return false;
    }
    if (std.meta.sentinel(T)) |sentinel| {
        if (sentinel == 0) {
            return true;
        }
    }
    return false;
}

fn isDecl(comptime T: type, comptime name: []const u8, comptime Decl: type, comptime isErr: bool) bool {
    if (!@hasDecl(T, name)) {
        if (isErr) {
            const msg = @typeName(T) ++ ": no '" ++ name ++ "' declaration";
            fmtErr(comptime msg.len, msg, T);
        }
        return false;
    }
    const typeOK = @TypeOf(@field(T, name)) == Decl;
    if (!typeOK and isErr) {
        const msg = @typeName(T) ++ ": '" ++ name ++ "' wrong type";
        fmtErr(comptime msg.len, msg, T);
    }
    return typeOK;
}

fn fmtErr(comptime n: usize, comptime msg: *const [n:0]u8, comptime T: type) void {
    if (!builtin.is_test) {
        @compileLog(msg, T);
    }
}

// Tests
// -----

const Error = error{
    TypesNotTuple,

    // struct errors
    StructNotStruct,
    StructPacked,
    StructSelfPointer,
    StructPrototypeNotPointer,
    StructWithoutProto,
    StructProtoPointer,
    StructProtoCastNotFunction,
    StructProtoCastWrongFunction,
    StructProtoDifferent,
    StructProtoLayout,
    StructLookup,
    StructDuplicateType,
    StructDuplicateName,
    StructExceptionWithoutErrorSet,
    StructExceptionWrongErrorSet,
    StructExceptionWrongInterface,
    StructExceptionDoesNotExist,

    // func errors
    FuncNoSelf,
    FuncGetterSetterNotAllocator,
    FuncGetterMultiArg,
    FuncSetterFirstArgNotSelfPtr,
    FuncSetterNoArg,
    FuncGetterMethodFirstArgNotSelfOrSelfPtr,
    FuncVoidArg,
    FuncMultiCbk,
    FuncVariadicNotLastOne,
    FuncReturnTypeVariadic,
    FuncErrorUnionArg,

    // type errors
    TypeTaggedUnion,
    TypeNestedPtr,
    TypeVariadicNested, // TODO: test
    TypeVariadicNotOptional,
    TypeLookup,
};

// ensure reflection fails with an error from Error set
fn ensureErr(arg: anytype, err: Error) !void {
    if (@call(.auto, do, .{arg})) |_| {
        // no error, so it's an error :)
        @compileLog("no error", @errorName(err));
        return error.Reflect;
    } else |e| {
        if (e != err) {
            // wrong error type, it's an error
            @compileLog("wrong error, expected, got", @errorName(err), @errorName(e));
            return error.Reflect;
        }
        // expected error, OK
    }
}

// structs tests
const TestBase = struct {};
const TestStructPacked = packed struct {};
const TestStructSelfPointer = struct {
    pub const Self = *TestBase;
};
const TestStructPrototypeNotPointer = struct {
    pub const prototype = TestBase;
};
const TestStructWithoutProto = struct {
    pub const prototype = *TestBase;
};
const TestBaseProtoCastNotFunction = struct {
    pub const protoCast = "not a function";
};
const TestStructProtoCastNotFunction = struct {
    pub const prototype = *TestBaseProtoCastNotFunction;
};
const TestBaseProtoCastWrongFunction = struct {
    pub fn protoCast(_: TestBaseProtoCastWrongFunction) TestBaseProtoCastWrongFunction {
        return .{};
    }
};
const TestStructProtoCastWrongFunction = struct {
    pub const prototype = *TestBaseProtoCastWrongFunction;
};
const TestBaseProtoCastDifferent = struct {
    // should be TestBaseProtoCastDifferent or *TestBaseProtoCastDifferent
    pub fn protoCast(_: anytype) bool {
        return true;
    }
};
const TestStructProtoCastDifferent = struct {
    pub const prototype = *TestBaseProtoCastDifferent;
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
const TestStructDuplicateTypeA = struct {};
const TestStructDuplicateTypeB = struct {
    pub const Self = TestStructDuplicateTypeA;
};
const MyExceptionWithoutErrorSet = struct {};
const TestStructExceptionWithoutErrorSet = struct {
    pub const Exception = MyExceptionWithoutErrorSet;
};
const MyExceptionWrongErrorSet = struct {
    pub const ErrorSet = bool;
};
const TestStructExceptionWrongErrorSet = struct {
    pub const Exception = MyExceptionWrongErrorSet;
};
const MyExceptionWrong = struct {
    pub const ErrorSet = error{
        MyException,
    };
};
const TestStructExceptionWrongInterface = struct {
    pub const Exception = MyExceptionWrong;
};
const MyException = struct {
    pub const ErrorSet = error{
        MyException,
    };
    pub fn init(_: std.mem.Allocator, _: ErrorSet) anyerror!MyException {
        return .{};
    }
    pub fn get_name(_: MyException) []const u8 {
        return "";
    }
    pub fn get_message(_: MyException) []const u8 {
        return "";
    }
    pub fn _toString(_: MyException) []const u8 {
        return "";
    }
};
const TestStructExceptionDoesNotExist = struct {
    pub const Exception = MyException;
};

// funcs tests
const TestFuncNoSelf = struct {
    pub fn _example() void {}
};
const TestFuncGetterMultiArg = struct {
    pub fn get_example(_: TestFuncGetterMultiArg, _: bool) void {}
};
const TestFuncGetterSetterNotAllocator = struct {
    pub fn get_example(_: TestFuncGetterSetterNotAllocator, _: *Loop) bool {
        return true;
    }
};
const TestFuncSetterFirstArgNotSelfPtr = struct {
    pub fn set_example(_: TestFuncSetterFirstArgNotSelfPtr) void {}
};
const TestFuncSetterNoArg = struct {
    pub fn set_example(_: *TestFuncSetterNoArg) void {}
};
const TestFuncGetterMethodFirstArgNotSelfOrSelfPtr = struct {
    pub fn _example(_: bool) void {}
};
const TestFuncVoidArg = struct {
    pub fn _example(_: TestFuncVoidArg, _: void) void {}
};
const TestFuncMultiCbk = struct {
    pub fn _example(_: TestFuncMultiCbk, _: Callback, _: Callback) void {}
};
const VariadicBool = Variadic(bool);
const TestFuncVariadicNotLastOne = struct {
    pub fn _example(_: TestFuncVariadicNotLastOne, _: ?VariadicBool, _: bool) void {}
};
const TestFuncReturnTypeVariadic = struct {
    pub fn _example(_: TestFuncReturnTypeVariadic) ?VariadicBool {}
};
const TestFuncErrorUnionArg = struct {
    pub fn _example(_: TestFuncErrorUnionArg, _: anyerror!void) void {}
};

// types tests
const TestTaggedUnion = union {
    a: bool,
    b: bool,
};
const TestTypeTaggedUnion = struct {
    pub fn _example(_: TestTypeTaggedUnion, _: TestTaggedUnion) void {}
};
const TestTypeNestedPtr = struct {
    pub const TestTypeNestedBase = struct {};
    pub fn _example(_: TestTypeNestedPtr, _: *TestTypeNestedBase) void {}
};
const TestTypeVariadicNotOptional = struct {
    pub fn _example(_: TestTypeVariadicNotOptional, _: VariadicBool) void {}
};
const TestType = struct {};
const TestTypeLookup = struct {
    pub fn _example(_: TestTypeLookup, _: TestType) void {}
};

pub fn tests() !void {
    std.debug.assert(@inComptime());
    @setEvalBranchQuota(10000);

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
        .{TestStructSelfPointer},
        error.StructSelfPointer,
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
        .{TestStructProtoCastNotFunction},
        error.StructProtoCastNotFunction,
    );
    try ensureErr(
        .{TestStructProtoCastWrongFunction},
        error.StructProtoCastWrongFunction,
    );
    try ensureErr(
        .{TestStructProtoCastDifferent},
        error.StructProtoDifferent,
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
    try ensureErr(
        .{ TestStructDuplicateTypeA, TestStructDuplicateTypeB },
        error.StructDuplicateType,
    );
    try ensureErr(
        .{TestStructExceptionWithoutErrorSet},
        error.StructExceptionWithoutErrorSet,
    );
    try ensureErr(
        .{TestStructExceptionWrongErrorSet},
        error.StructExceptionWrongErrorSet,
    );
    try ensureErr(
        .{ TestStructExceptionWrongInterface, MyExceptionWrong },
        error.StructExceptionWrongInterface,
    );
    try ensureErr(
        .{TestStructExceptionDoesNotExist},
        error.StructExceptionDoesNotExist,
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
        .{TestFuncGetterSetterNotAllocator},
        error.FuncGetterSetterNotAllocator,
    );
    try ensureErr(
        .{TestFuncSetterFirstArgNotSelfPtr},
        error.FuncSetterFirstArgNotSelfPtr,
    );
    try ensureErr(
        .{TestFuncSetterNoArg},
        error.FuncSetterNoArg,
    );
    try ensureErr(
        .{TestFuncGetterMethodFirstArgNotSelfOrSelfPtr},
        error.FuncGetterMethodFirstArgNotSelfOrSelfPtr,
    );
    try ensureErr(
        .{TestFuncVoidArg},
        error.FuncVoidArg,
    );
    try ensureErr(
        .{TestFuncMultiCbk},
        error.FuncMultiCbk,
    );
    try ensureErr(
        .{TestFuncVariadicNotLastOne},
        error.FuncVariadicNotLastOne,
    );
    try ensureErr(
        .{TestFuncReturnTypeVariadic},
        error.FuncReturnTypeVariadic,
    );
    try ensureErr(
        .{TestFuncErrorUnionArg},
        error.FuncErrorUnionArg,
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
        .{TestTypeNestedPtr},
        error.TypeNestedPtr,
    );
    try ensureErr(
        .{TestTypeVariadicNotOptional},
        error.TypeVariadicNotOptional,
    );
    try ensureErr(
        .{TestTypeLookup},
        error.TypeLookup,
    );
}
