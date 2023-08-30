const std = @import("std");

const v8 = @import("v8");

const internal = @import("../../internal_api.zig");
const refs = internal.refs;
const refl = internal.refl;
const gen = internal.gen;
const utils = internal.utils;

const public = @import("../../api.zig");
const Loop = public.Loop;

const cbk = @import("callback.zig");
const nativeToJS = @import("types_primitives.zig").nativeToJS;
const jsToNative = @import("types_primitives.zig").jsToNative;

const TPL = @import("v8.zig").TPL;

// Utils functions
// ---------------

fn throwTypeError(msg: []const u8, js_res: v8.ReturnValue, isolate: v8.Isolate) void {
    const err = v8.String.initUtf8(isolate, msg);
    const exception = v8.Exception.initTypeError(err);
    js_res.set(isolate.throwException(exception));
}

const not_enough_args = "{s}.{s}: At least {d} argument required, but only {d} passed";

// checkArgsLen of the JS call
// Return true if JS call provides enough arguments than defined natively.
// JS call is allowed to provide more arguments, they will be ignored.
// If JS call provides less arguments, throw a TypeError and return false.
fn checkArgsLen(
    comptime name: []const u8,
    comptime func: refl.Func,
    info: v8.FunctionCallbackInfo,
    isolate: v8.Isolate,
) bool {

    // check mandatory args
    var func_args_len: usize = func.args.len;
    if (func.first_optional_arg) |args_mandatory| {
        func_args_len = args_mandatory;
    }
    func_args_len -= func.index_offset;

    // OK
    const js_args_len = info.length();
    if (js_args_len >= func_args_len) {
        // NOTE: using > to allow JS call to provide more arguments
        return true;
    }

    // throw a TypeError
    const args = .{
        name,
        func.js_name,
        func_args_len,
        js_args_len,
    };
    var buf: [100]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0..], not_enough_args, args) catch unreachable;
    throwTypeError(msg, info.getReturnValue(), isolate);
    return false;
}

fn getNativeArg(
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime arg_T: refl.Type,
    js_value: v8.Value,
) arg_T.T {
    var value: arg_T.T = undefined;

    // JS Null or Undefined value
    if (js_value.isNull() or js_value.isUndefined()) {
        comptime {
            // if Native optional type return null
            if (arg_T.under_opt != null) {
                return null;
            }
            // TODO: else return error "Argument x is not an object"
        }
    }

    // JS object
    const ptr = getNativeObject(
        T_refl,
        all_T,
        js_value.castTo(v8.Object),
    ) catch unreachable; // TODO: throw js exception
    if (arg_T.under_ptr != null) {
        value = ptr;
    } else {
        value = ptr.*;
    }
    return value;
}

// This function can only be used by function callbacks (ie. construcotr and methods)
// as it takes a v8.FunctionCallbackInfo (with a getArg method).
fn getArgs(
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime func: refl.Func,
    info: v8.FunctionCallbackInfo,
    isolate: v8.Isolate,
    ctx: v8.Context,
) func.args_T {
    var args: func.args_T = undefined;

    // iter on function expected arguments
    inline for (func.args) |arg, i| {
        var value: arg.T = undefined;

        if (arg.isNative()) {

            // native types
            const js_value = info.getArg(i - func.index_offset);
            value = getNativeArg(all_T[arg.T_refl_index.?], all_T, arg, js_value);
        } else {

            // builtin types
            // and nested types (ie. JS anonymous objects)
            value = switch (arg.T) {
                std.mem.Allocator => utils.allocator,
                *Loop => utils.loop,
                cbk.Func => cbk.Func.init(
                    utils.allocator,
                    func,
                    info,
                    isolate,
                ) catch unreachable,
                cbk.FuncSync => cbk.FuncSync.init(
                    utils.allocator,
                    func,
                    info,
                    isolate,
                ) catch unreachable,
                cbk.Arg => cbk.Arg{}, // stage1: we need type
                else => jsToNative(
                    utils.allocator,
                    T_refl,
                    arg,
                    info.getArg(i - func.index_offset),
                    isolate,
                    ctx,
                ) catch unreachable,
            };
        }

        // set argument
        @field(args, arg.name.?) = value;
    }

    return args;
}

pub fn setNativeObject(
    alloc: std.mem.Allocator,
    comptime T_refl: refl.Struct,
    comptime obj_T: refl.Type,
    obj: anytype,
    js_obj: v8.Object,
    isolate: v8.Isolate,
) !void {
    const T = obj_T.under_T();

    // assign and bind native obj to JS obj
    var obj_ptr: *T = undefined;

    if (@typeInfo(@TypeOf(obj)) == .Pointer) {

        // obj is a pointer of T
        // no need to create it in heap,
        // we assume it has been done already by the API
        // just assign pointer to native object
        obj_ptr = obj;
    } else {

        // obj is a value of T
        // create a pointer in heap
        // (otherwise on the stack it will be delete when the function returns),
        // and assign pointer's dereference value to native object
        obj_ptr = try alloc.create(T);
        obj_ptr.* = obj;
    }

    // if the object is an empty struct (ie. a kind of container)
    // no need to keep it's reference
    if (T_refl.isEmpty()) {
        return;
    }

    // bind the native object pointer to JS obj
    var ext: v8.External = undefined;
    if (comptime T_refl.is_mem_guarantied()) {
        // store directly the object pointer
        ext = v8.External.init(isolate, obj_ptr);
    } else {
        // use the refs mechanism
        var int_ptr = try alloc.create(usize);
        int_ptr.* = @ptrToInt(obj_ptr);
        ext = v8.External.init(isolate, int_ptr);
        try refs.addObject(alloc, int_ptr.*, T_refl.index);
    }
    js_obj.setInternalField(0, ext);
}

fn setReturnType(
    alloc: std.mem.Allocator,
    comptime all_T: []refl.Struct,
    comptime ret: refl.Type,
    res: anytype,
    ctx: v8.Context,
    isolate: v8.Isolate,
) !v8.Value {
    const val_T = if (ret.under_opt) |T| T else ret.T;
    var val: val_T = undefined;

    // Optional
    if (ret.under_opt != null) {
        if (res == null) {
            // if null just return JS null
            return isolate.initNull().toValue();
        } else {
            // otherwise replace with the underlying type
            val = res.?;
        }
    } else {
        val = res;
    }

    // Union type
    if (comptime ret.union_T) |union_types| {
        // retrieve the active field and setReturntype accordingly
        const activeTag = @tagName(std.meta.activeTag(val));
        // TODO: better algorythm?
        inline for (union_types) |tt| {
            if (std.mem.eql(u8, activeTag, tt.name.?)) {
                return setReturnType(
                    alloc,
                    all_T,
                    tt,
                    @field(val, tt.name.?),
                    ctx,
                    isolate,
                );
            }
        }
    }

    if (ret.nested_index) |nested_index| {

        // return is a user defined nested type

        // create a JS object
        // and call setReturnType on each object fields
        const js_obj = v8.Object.init(isolate);
        const nested = all_T[ret.T_refl_index.?].nested[nested_index];
        inline for (nested.fields) |field| {
            const name = field.name.?;
            const js_val = try setReturnType(
                alloc,
                all_T,
                field,
                @field(val, name),
                ctx,
                isolate,
            );
            const key = v8.String.initUtf8(isolate, name);
            if (!js_obj.setValue(ctx, key, js_val)) {
                return error.JSObjectSetValue;
            }
        }
        return js_obj.toValue();
    }

    if (ret.T_refl_index) |index| {

        // return is a user defined type

        // instantiate a JS object from template
        // and bind it to the native object
        const js_obj = gen.getTpl(index).tpl.getInstanceTemplate().initInstance(ctx);
        _ = setNativeObject(
            alloc,
            all_T[index],
            ret,
            val,
            js_obj,
            isolate,
        ) catch unreachable;
        return js_obj.toValue();
    }

    // return is a builtin type

    const js_val = nativeToJS(
        ret.under_T(),
        val,
        isolate,
    ) catch unreachable; // NOTE: should not happen has types have been checked at reflect
    return js_val;
}

fn getNativeObject(
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    js_obj: v8.Object,
) !*T_refl.Self() {
    const T = T_refl.Self();

    var obj_ptr: *T = undefined;
    if (comptime T_refl.isEmpty()) {
        // if the object is an empty struct (ie. kind of a container)
        // there is no reference from it's constructor, we can just re-create it
        obj_ptr.* = T{};
    } else {
        // retrieve the zig object from it's javascript counterpart
        const ext = js_obj.getInternalField(0).castTo(v8.External).get().?;
        if (comptime T_refl.is_mem_guarantied()) {
            // memory is fixed
            // ensure the pointer is aligned (no-op at runtime)
            // as External is a ?*anyopaque (ie. *void) with alignment 1
            const ptr = @alignCast(@alignOf(T_refl.Self()), ext);
            if (@hasDecl(T_refl.T, "protoCast")) {
                // T_refl provides a function to cast the pointer from high level Type
                obj_ptr = @call(.{}, @field(T_refl.T, "protoCast"), .{ptr});
            } else {
                // memory layout is fixed through prototype chain of T_refl
                // with the proto Type at the begining of the address of the high level Type
                // so we can safely use @ptrCast
                obj_ptr = @ptrCast(*T, ptr);
            }
        } else {
            // use the refs mechanism to retrieve from high level Type
            obj_ptr = try refs.getObject(T, all_T, ext);
        }
    }
    return obj_ptr;
}

// JS functions callbacks
// ----------------------

fn generateConstructor(
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime func_cstr: ?refl.Func,
) v8.FunctionCallback {
    return struct {
        fn constructor(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {

            // retrieve isolate and context
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();
            const ctx = isolate.getCurrentContext();

            // check illegal constructor
            if (func_cstr == null) {
                return throwTypeError("Illegal constructor", info.getReturnValue(), isolate);
            }
            const func = func_cstr.?;

            // check func params length
            if (!checkArgsLen(T_refl.name, func, info, isolate)) {
                return;
            }

            // prepare args
            const args = getArgs(T_refl, all_T, func, info, isolate, ctx);

            // call the native func
            const cstr_func = @field(T_refl.T, func.name);
            const obj = @call(.{}, cstr_func, args);

            // bind native object to JS new object
            setNativeObject(
                utils.allocator,
                T_refl,
                func.return_type,
                obj,
                info.getThis(),
                isolate,
            ) catch unreachable;
        }
    }.constructor;
}

fn generateGetter(
    comptime T_refl: refl.Struct,
    comptime func: refl.Func,
    comptime all_T: []refl.Struct,
) v8.AccessorNameGetterCallback {
    return struct {
        fn getter(
            _: ?*const v8.C_Name,
            raw_info: ?*const v8.C_PropertyCallbackInfo,
        ) callconv(.C) void {

            // retrieve isolate
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();

            // TODO: check func params length

            // retrieve the zig object
            const obj_ptr = getNativeObject(T_refl, all_T, info.getThis()) catch unreachable;
            var args: func.args_T = undefined;
            const self_T = @TypeOf(@field(args, "0"));
            if (self_T == T_refl.Self()) {
                @field(args, "0") = obj_ptr.*;
            } else if (self_T == *T_refl.Self()) {
                @field(args, "0") = obj_ptr;
            }

            // call the corresponding zig object method
            const getter_func = @field(T_refl.T, func.name);
            const res = @call(.{}, getter_func, args);

            // return to javascript the result
            const js_val = setReturnType(
                utils.allocator,
                all_T,
                func.return_type,
                res,
                isolate.getCurrentContext(),
                isolate,
            ) catch unreachable;
            info.getReturnValue().setValueHandle(js_val.handle);
        }
    }.getter;
}

fn generateSetter(
    comptime T_refl: refl.Struct,
    comptime func: refl.Func,
    comptime all_T: []refl.Struct,
) v8.AccessorNameSetterCallback {
    return struct {
        fn setter(
            _: ?*const v8.C_Name,
            raw_value: ?*const v8.C_Value,
            raw_info: ?*const v8.C_PropertyCallbackInfo,
        ) callconv(.C) void {

            // retrieve isolate
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();

            // TODO: check func params length

            // get the value set in javascript
            const js_value = v8.Value{ .handle = raw_value.? };
            const arg_T = func.args[0];
            var zig_value: arg_T.T = undefined;

            if (arg_T.isNative()) {

                // native type
                zig_value = getNativeArg(
                    all_T[arg_T.T_refl_index.?],
                    all_T,
                    arg_T,
                    js_value,
                );
            } else {

                // primitive type
                // and nested type (ie. JS anonymous object)
                zig_value = jsToNative(
                    utils.allocator,
                    T_refl,
                    arg_T,
                    js_value,
                    isolate,
                    isolate.getCurrentContext(),
                ) catch unreachable; // TODO: throw js exception
            }

            // retrieve the zig object
            const obj_ptr = getNativeObject(T_refl, all_T, info.getThis()) catch unreachable;

            // call the corresponding zig object method
            const setter_func = @field(T_refl.T, func.name);
            _ = @call(.{}, setter_func, .{ obj_ptr, zig_value }); // return should be void

            // return to javascript the provided value
            info.getReturnValue().setValueHandle(raw_value.?);
        }
    }.setter;
}

fn generateMethod(
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime func: refl.Func,
) v8.FunctionCallback {
    return struct {
        fn method(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {

            // retrieve isolate and context
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();
            const ctx = isolate.getCurrentContext();

            // check func params length
            if (!checkArgsLen(T_refl.name, func, info, isolate)) {
                return;
            }

            // prepare args
            var args = getArgs(T_refl, all_T, func, info, isolate, ctx);

            // retrieve the zig object
            const obj_ptr = getNativeObject(T_refl, all_T, info.getThis()) catch unreachable;
            const self_T = @TypeOf(@field(args, "0"));
            if (self_T == T_refl.Self()) {
                @field(args, "0") = obj_ptr.*;
            } else if (self_T == *T_refl.Self()) {
                @field(args, "0") = obj_ptr;
            }

            // call native func
            const method_func = @field(T_refl.T, func.name);
            const res = @call(.{}, method_func, args);

            // return to javascript the result
            const js_val = setReturnType(
                utils.allocator,
                all_T,
                func.return_type,
                res,
                ctx,
                isolate,
            ) catch unreachable;
            info.getReturnValue().setValueHandle(js_val.handle);

            // sync callback
            // for test purpose, does not have any sense in real case
            if (comptime func.callback_index != null) {
                // -1 because of self
                const js_func_index = func.callback_index.? - func.index_offset - 1;
                if (func.args[js_func_index].T == cbk.FuncSync) {
                    args[func.callback_index.? - func.index_offset].call(utils.allocator) catch unreachable;
                }
            }
        }
    }.method;
}

fn generateStringTag(comptime name: []const u8) v8.AccessorNameGetterCallback {
    return struct {
        fn stringTag(
            _: ?*const v8.C_Name,
            raw_info: ?*const v8.C_PropertyCallbackInfo,
        ) callconv(.C) void {
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const js_name = v8.String.initUtf8(info.getIsolate(), name);
            info.getReturnValue().set(js_name);
        }
    }.stringTag;
}

fn staticAttrsKeys(
    comptime T_refl: refl.Struct,
    keys: []v8.Name,
    isolate: v8.Isolate,
) void {
    if (T_refl.static_attrs_T == null) {
        return;
    }
    const attrs_T = T_refl.static_attrs_T.?;
    inline for (@typeInfo(attrs_T).Struct.fields) |field, i| {
        keys[i] = v8.String.initUtf8(isolate, field.name).toName();
    }
}

fn staticAttrsValues(
    comptime T_refl: refl.Struct,
    values: []v8.Value,
    isolate: v8.Isolate,
) void {
    if (T_refl.static_attrs_T == null) {
        return;
    }
    const attrs_T = T_refl.static_attrs_T.?;
    const attrs = comptime T_refl.staticAttrs(attrs_T);
    inline for (@typeInfo(attrs_T).Struct.fields) |field, i| {
        const value = comptime @field(attrs, field.name);
        values[i] = nativeToJS(@TypeOf(value), value, isolate) catch unreachable;
    }
}

fn setStaticAttrs(
    comptime T_refl: refl.Struct,
    template: anytype,
    keys: []v8.Name,
    values: []v8.Value,
) void {
    if (T_refl.static_attrs_T == null) {
        return;
    }
    const attrs_T = T_refl.static_attrs_T.?;
    inline for (@typeInfo(attrs_T).Struct.fields) |_, i| {
        template.set(keys[i], values[i], v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);
    }
}

pub const LoadFnType = (fn (v8.Isolate, v8.ObjectTemplate, ?TPL) anyerror!TPL);

pub fn loadFn(comptime T_refl: refl.Struct, comptime all_T: []refl.Struct) LoadFnType {
    return struct {

        // NOTE: the load function and it's callbacks constructor/getter/setter/method
        // are executed at runtime !

        pub fn load(
            isolate: v8.Isolate,
            globals: v8.ObjectTemplate,
            proto_tpl: ?TPL,
        ) !TPL {

            // create a v8 FunctionTemplate for the T constructor function,
            // with the corresponding zig callback,
            // and attach it to the global namespace
            const cstr_func = generateConstructor(T_refl, all_T, T_refl.constructor);
            const cstr_tpl = v8.FunctionTemplate.initCallback(isolate, cstr_func);
            const cstr_key = v8.String.initUtf8(isolate, T_refl.name).toName();
            globals.set(cstr_key, cstr_tpl, v8.PropertyAttribute.None);

            // static attributes keys and values
            comptime var static_nb: usize = undefined;
            if (T_refl.static_attrs_T) |attr_T| {
                static_nb = @typeInfo(attr_T).Struct.fields.len;
            } else {
                static_nb = 0;
            }
            var static_keys: [static_nb]v8.Name = undefined;
            var static_values: [static_nb]v8.Value = undefined;
            staticAttrsKeys(T_refl, &static_keys, isolate);
            staticAttrsValues(T_refl, &static_values, isolate);

            // set static attributes on the v8 FunctionTemplate
            setStaticAttrs(T_refl, cstr_tpl, &static_keys, &static_values);

            // set the optional prototype of the constructor
            if (comptime T_refl.proto_index != null) {
                if (proto_tpl == null) {
                    return error.NoPrototypeTemplateProvided;
                }
                if (T_refl.proto_index.? != proto_tpl.?.index) {
                    return error.WrongPrototypeTemplateProvided;
                }
                cstr_tpl.inherit(proto_tpl.?.tpl);
            }

            // NOTE: There is 2 different ObjectTemplate
            // attached to the FunctionTemplate of the constructor:
            // - The PrototypeTemplate which represents the template
            // of the protype of the constructor.
            // All getter/setter/methods must be set on it.
            // - The InstanceTemplate wich represents the template
            // of the instance created by the constructor.
            // This template holds the internal field count.

            // get the v8 InstanceTemplate attached to the constructor
            // and set 1 internal field to bind the counterpart zig object
            const obj_tpl = cstr_tpl.getInstanceTemplate();
            if (!T_refl.isEmpty()) {
                // if the object is an empty struct (ie. a kind of container)
                // no need to keep it's reference
                obj_tpl.setInternalFieldCount(1);
            }

            // get the v8 Prototypetemplate attached to the constructor
            // to set getter/setter/methods
            const prototype = cstr_tpl.getPrototypeTemplate();

            // set getters for the v8 ObjectTemplate,
            // with the corresponding zig callbacks
            inline for (T_refl.getters) |getter| {
                const getter_func = generateGetter(T_refl, getter, all_T);
                var key: v8.Name = undefined;
                if (getter.symbol) |symbol| {
                    key = switch (symbol) {
                        .string_tag => v8.Symbol.getToStringTag(isolate),
                        else => unreachable,
                    }.toName();
                } else {
                    key = v8.String.initUtf8(isolate, getter.js_name).toName();
                }
                if (getter.setter_index == null) {
                    prototype.setGetter(key, getter_func);
                } else {
                    const setter = T_refl.setters[getter.setter_index.?];
                    const setter_func = generateSetter(T_refl, setter, all_T);
                    prototype.setGetterAndSetter(key, getter_func, setter_func);
                }
            }

            // set static attributes on the v8 ObjectTemplate
            // so each instance will get them
            setStaticAttrs(T_refl, prototype, &static_keys, &static_values);

            // add string tag if not provided
            if (!T_refl.string_tag) {
                const key = v8.Symbol.getToStringTag(isolate).toName();
                prototype.setGetter(key, generateStringTag(T_refl.name));
            }

            // create a v8 FunctionTemplate for each T methods,
            // with the corresponding zig callbacks,
            // and attach them to the object template
            inline for (T_refl.methods) |method| {
                const func = generateMethod(T_refl, all_T, method);
                const func_tpl = v8.FunctionTemplate.initCallback(isolate, func);
                var key: v8.Name = undefined;
                if (method.symbol) |symbol| {
                    key = switch (symbol) {
                        .iterator => v8.Symbol.getIterator(isolate),
                        else => unreachable,
                    }.toName();
                } else {
                    key = v8.String.initUtf8(isolate, method.js_name).toName();
                }
                prototype.set(key, func_tpl, v8.PropertyAttribute.None);
            }

            // return the FunctionTemplate of the constructor
            return TPL{ .tpl = cstr_tpl, .index = T_refl.index };
        }
    }.load;
}