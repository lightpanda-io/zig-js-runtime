const std = @import("std");
const v8 = @import("v8");

const utils = @import("utils.zig");
const Store = @import("store.zig");
const refs = @import("refs.zig");
const refl = @import("reflect.zig");
const Loop = @import("loop.zig").SingleThreaded;

const cbk = @import("callback.zig");

const nativeToJS = @import("types_primitives.zig").nativeToJS;
const jsToNative = @import("types_primitives.zig").jsToNative;

fn throwTypeError(msg: []const u8, js_res: v8.ReturnValue, isolate: v8.Isolate) void {
    const err = v8.String.initUtf8(isolate, msg);
    const exception = v8.Exception.initTypeError(err);
    js_res.set(isolate.throwException(exception));
}

const not_enough_args = "{s}.{s}: At least {d} argument required, but only {d} passed";

pub fn setNativeObject(
    alloc: std.mem.Allocator,
    comptime T_refl: refl.Struct,
    js_obj: v8.Object,
    isolate: v8.Isolate,
) !*T_refl.T {
    const T = T_refl.T;

    // create and allocate the zig object
    // we need to put it on the heap
    // otherwise on the stack it will be delete when the function returns
    var obj_ptr = try alloc.create(T);

    // if the object is an empty struct (ie. a kind of container)
    // no need to keep it's reference
    if (T_refl.size == 0) {
        return obj_ptr;
    }

    if (Store.default != null) {
        try Store.default.?.addObject(obj_ptr, T_refl.size, T_refl.alignment);
    }

    // bind the zig object to it's javascript counterpart
    var ext: v8.External = undefined;
    if (comptime T_refl.is_mem_guarantied()) {
        ext = v8.External.init(isolate, obj_ptr);
    } else {
        var int_ptr = try alloc.create(usize);
        int_ptr.* = @ptrToInt(obj_ptr);
        if (Store.default != null) {
            try Store.default.?.addObject(int_ptr, @sizeOf(usize), @alignOf(usize));
        }
        ext = v8.External.init(isolate, int_ptr);
        try refs.addObject(alloc, int_ptr.*, T_refl.index);
    }
    js_obj.setInternalField(0, ext);
    return obj_ptr;
}

fn getNativeObject(comptime T_refl: refl.Struct, comptime all_T: []refl.Struct, js_obj: v8.Object) !*T_refl.T {
    const T = T_refl.T;
    var obj_ptr: *T = undefined;
    if (T_refl.size == 0) {
        // if the object is an empty struct (ie. kind of a container)
        // there is no reference from it's constructor, we can just re-create it
        obj_ptr.* = T{};
    } else {
        // retrieve the zig object from it's javascript counterpart
        const ext = js_obj.getInternalField(0).castTo(v8.External);
        if (comptime T_refl.is_mem_guarantied()) {
            obj_ptr = @ptrCast(*T, ext.get().?);
        } else {
            obj_ptr = try refs.getObject(T, all_T, ext.get().?);
        }
    }
    return obj_ptr;
}

fn generateConstructor(comptime T_refl: refl.Struct, comptime func: ?refl.Func) v8.FunctionCallback {
    const zig_cbk = struct {
        fn constructor(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {

            // retrieve isolate and context
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();
            const ctx = isolate.getCurrentContext();

            // check illegal constructor
            if (func == null) {
                return throwTypeError("Illegal constructor", info.getReturnValue(), isolate);
            }

            // check func params length
            // if JS provide more arguments than defined natively, just ignore them
            // but if JS provide less argument, throw a TypeError
            var func_args_required: usize = func.?.args.len;
            if (func.?.first_optional_arg != null) {
                func_args_required = func.?.first_optional_arg.?;
            }
            const js_params_len = info.length();
            if (js_params_len < func_args_required) {
                const args = .{
                    T_refl.name,
                    func.?.js_name,
                    func_args_required,
                    js_params_len,
                };
                var buf: [100]u8 = undefined;
                const msg = std.fmt.bufPrint(buf[0..], not_enough_args, args) catch unreachable;
                return throwTypeError(msg, info.getReturnValue(), isolate);
            }

            // set the zig object and call it's constructor
            const obj_ptr = setNativeObject(utils.allocator, T_refl, info.getThis(), isolate) catch unreachable;
            var args: func.?.args_T = undefined;
            inline for (func.?.args) |arg, i| {
                const value = jsToNative(
                    utils.allocator,
                    arg,
                    info.getArg(i - func.?.index_offset),
                    isolate,
                    ctx,
                ) catch unreachable;
                @field(args, arg.name.?) = value;
            }
            obj_ptr.* = @call(.{}, T_refl.T.constructor, args);
        }
    };
    return zig_cbk.constructor;
}

fn generateGetter(comptime T_refl: refl.Struct, comptime func: refl.Func, comptime all_T: []refl.Struct) v8.AccessorNameGetterCallback {
    const zig_cbk = struct {
        fn getter(_: ?*const v8.Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.C) void {

            // retrieve isolate
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();

            // TODO: check func params length

            // retrieve the zig object
            const obj_ptr = getNativeObject(T_refl, all_T, info.getThis()) catch unreachable;

            // call the corresponding zig object method
            const getter_func = @field(T_refl.T, func.name);
            const res = @call(.{}, getter_func, .{obj_ptr.*});

            // return to javascript the result
            nativeToJS(func.return_type.?, res, info.getReturnValue(), isolate) catch unreachable; // TODO: js native exception
        }
    };
    return zig_cbk.getter;
}

fn generateSetter(comptime T_refl: refl.Struct, comptime func: refl.Func, comptime all_T: []refl.Struct) v8.AccessorNameSetterCallback {
    const zig_cbk = struct {
        // TODO: why can we use v8.Name but not v8.Value (v8.C_Value)?
        fn setter(_: ?*const v8.Name, raw_value: ?*const v8.C_Value, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.C) void {

            // retrieve isolate
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();

            // TODO: check func params length

            // get the value set in javascript
            const js_value = v8.Value{ .handle = raw_value.? };
            const zig_value = jsToNative(utils.allocator, func.args[0], js_value, isolate, isolate.getCurrentContext()) catch unreachable; // TODO: throw js exception

            // retrieve the zig object
            const obj_ptr = getNativeObject(T_refl, all_T, info.getThis()) catch unreachable;

            // call the corresponding zig object method
            const setter_func = @field(T_refl.T, func.name);
            _ = @call(.{}, setter_func, .{ obj_ptr, zig_value }); // return should be void

            // return to javascript the provided value
            info.getReturnValue().setValueHandle(raw_value.?);
        }
    };
    return zig_cbk.setter;
}

fn generateMethod(comptime T_refl: refl.Struct, comptime func: refl.Func, comptime all_T: []refl.Struct) v8.FunctionCallback {
    const zig_cbk = struct {
        fn method(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {

            // retrieve isolate and context
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();
            const ctx = isolate.getCurrentContext();

            // check func params length
            // if JS provide more arguments than defined natively, just ignore them
            // but if JS provide less argument, throw a TypeError
            var func_args_required: usize = func.args.len;
            if (func.first_optional_arg != null) {
                func_args_required = func.first_optional_arg.?;
            }
            func_args_required -= func.index_offset;
            const js_params_len = info.length();
            if (js_params_len < func_args_required) {
                const args = .{
                    T_refl.name,
                    func.js_name,
                    func_args_required,
                    js_params_len,
                };
                var buf: [100]u8 = undefined;
                const msg = std.fmt.bufPrint(buf[0..], not_enough_args, args) catch unreachable;
                return throwTypeError(msg, info.getReturnValue(), isolate);
            }

            // retrieve the zig object
            const obj_ptr = getNativeObject(T_refl, all_T, info.getThis()) catch unreachable;

            // prepare call to the corresponding zig object method
            const method_func = @field(T_refl.T, func.name);

            // call the func
            var args: func.args_T = undefined;
            @field(args, "0") = obj_ptr.*;
            inline for (func.args) |arg, i| {
                const value = switch (arg.T) {
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
                        arg,
                        info.getArg(i - func.index_offset),
                        isolate,
                        ctx,
                    ) catch unreachable,
                };
                @field(args, arg.name.?) = value;
            }
            const res = @call(.{}, method_func, args);

            // return to javascript the result
            nativeToJS(
                func.return_type.?,
                res,
                info.getReturnValue(),
                isolate,
            ) catch unreachable; // TODO: js native exception

            // sync callback
            // for test purpose, does not have any sense in real case
            if (comptime func.callback_index != null) {
                // -1 because of self
                const js_func_index = func.callback_index.? - func.index_offset - 1;
                if (func.args[js_func_index].T == cbk.FuncSync) {
                    args[func.callback_index.? - func.index_offset].call(utils.allocator);
                }
            }
        }
    };
    return zig_cbk.method;
}

pub const ProtoTpl = struct {
    tpl: v8.FunctionTemplate,
    index: usize,
};

const LoadFunc = (fn (v8.Isolate, v8.ObjectTemplate, ?ProtoTpl) anyerror!ProtoTpl);

fn loadFunc(comptime T_refl: refl.Struct, comptime all_T: []refl.Struct) LoadFunc {
    const s = struct {

        // NOTE: the load function and it's callbacks constructor/getter/setter/method
        // are executed at runtime !

        pub fn load(isolate: v8.Isolate, globals: v8.ObjectTemplate, proto_tpl: ?ProtoTpl) !ProtoTpl {
            // create a v8 FunctionTemplate for the T constructor function,
            // with the corresponding zig callback,
            // and attach it to the global namespace
            const cstr_func = generateConstructor(T_refl, T_refl.constructor);
            const cstr_tpl = v8.FunctionTemplate.initCallback(isolate, cstr_func);
            const cstr_key = v8.String.initUtf8(isolate, T_refl.name);
            globals.set(cstr_key, cstr_tpl, v8.PropertyAttribute.None);

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
            // - The Prototypetemplate which represents the template
            // of the protype of the constructor.
            // All getter/setter/methods must be set on it.
            // - The InstanceTemplate wich represents the template
            // of the instance created by the constructor.
            // This template holds the internal field count.

            // get the v8 InstanceTemplate attached to the constructor
            // and set 1 internal field to bind the counterpart zig object
            const obj_tpl = cstr_tpl.getInstanceTemplate();
            if (T_refl.size != 0) {
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
                const key = v8.String.initUtf8(isolate, getter.js_name);
                if (getter.setter_index == null) {
                    prototype.setGetter(key, getter_func);
                } else {
                    const setter = T_refl.setters[getter.setter_index.?];
                    const setter_func = generateSetter(T_refl, setter, all_T);
                    prototype.setGetterAndSetter(key, getter_func, setter_func);
                }
            }

            // create a v8 FunctinTemplate for each T methods,
            // with the corresponding zig callbacks,
            // and attach them to the object template
            inline for (T_refl.methods) |method| {
                const func = generateMethod(T_refl, method, all_T);
                const func_tpl = v8.FunctionTemplate.initCallback(isolate, func);
                const key = v8.String.initUtf8(isolate, method.js_name);
                prototype.set(key, func_tpl, v8.PropertyAttribute.None);
            }

            // return the FunctionTemplate of the constructor
            return ProtoTpl{ .tpl = cstr_tpl, .index = T_refl.index };
        }
    };
    return s.load;
}

pub const API = struct {
    T_refl: refl.Struct,
    proto_tpl_index: ?usize = null,
    load: LoadFunc,
};

pub fn compile(comptime types: anytype) []API {
    comptime {

        // call types reflection
        const all_T = refl.do(types);

        var apis: [all_T.len]API = undefined;
        inline for (all_T) |T_refl, i| {
            const loader = loadFunc(T_refl, all_T);

            if (T_refl.proto_index == null) {
                // no prototype
                apis[i] = API{
                    .T_refl = T_refl,
                    .load = loader,
                };
                continue;
            }

            // set the index of the prototype
            var proto_tpl_index: ?usize = null;
            inline for (all_T) |proto_refl, proto_i| {
                if (proto_refl.index != T_refl.proto_index.?) {
                    // not the right proto
                    continue;
                }
                proto_tpl_index = proto_i;
                break;
            }
            if (proto_tpl_index == null) {
                @compileError("generate error: could not find the prototype in list");
            }
            apis[i] = API{
                .T_refl = T_refl,
                .proto_tpl_index = proto_tpl_index,
                .load = loader,
            };
        }

        return &apis;
    }
}

pub fn load(
    isolate: v8.Isolate,
    globals: v8.ObjectTemplate,
    comptime apis: []API,
    tpls: []ProtoTpl,
) !void {
    inline for (apis) |api, i| {
        if (api.proto_tpl_index == null) {
            tpls[i] = try api.load(isolate, globals, null);
        } else {
            const proto_tpl = tpls[api.proto_tpl_index.?]; // safe because apis are ordered from parent to child
            tpls[i] = try api.load(isolate, globals, proto_tpl);
        }
    }
}
