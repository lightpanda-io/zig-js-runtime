const std = @import("std");
const v8 = @import("v8");

const utils = @import("utils.zig");
const Store = @import("store.zig");
const refs = @import("refs.zig");
const refl = @import("reflect.zig");

const nativeToJS = @import("types_primitives.zig").nativeToJS;
const jsToNative = @import("types_primitives.zig").jsToNative;

fn throwTypeError(msg: []const u8, js_res: v8.ReturnValue, isolate: v8.Isolate) void {
    const err = v8.String.initUtf8(isolate, msg);
    const exception = v8.Exception.initTypeError(err);
    js_res.set(isolate.throwException(exception));
}

const not_enough_args = "{s}.{s}: At least {d} argument required, but only {d} passed";

fn getArgs(alloc: std.mem.Allocator, comptime self_null: bool, self: anytype, comptime params: []refl.Type, comptime args_T: type, info: v8.FunctionCallbackInfo, isolate: v8.Isolate, ctx: v8.Context) !args_T {
    var args: args_T = undefined;
    if (!self_null) {
        @field(args, "0") = self;
    }
    inline for (params) |param, i| {
        const value = try jsToNative(alloc, param, info.getArg(i), isolate, ctx);
        @field(args, param.name.?) = value;
    }
    return args;
}

fn generateConstructor(comptime T_refl: refl.Struct, comptime func: ?refl.Func) v8.FunctionCallback {
    const cbk = struct {
        fn constructor(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
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
            // TODO: optional argument shoudl allow a missing value
            const js_params_len = info.length();
            if (js_params_len < func.?.args.len) {
                const args = .{
                    T_refl.name,
                    func.?.js_name,
                    func.?.args.len,
                    js_params_len,
                };
                const msg = std.fmt.allocPrint(utils.allocator, not_enough_args, args) catch unreachable;
                if (Store.default != null) {
                    Store.default.?.addString(msg) catch unreachable;
                }
                return throwTypeError(msg, info.getReturnValue(), isolate);
            }

            // create and allocate the zig object
            // NOTE: we need to put the zig object on the heap
            // otherwise on the stack it will be delete when the function returns
            const T = T_refl.T;
            var obj_ptr = utils.allocator.create(T) catch unreachable;
            const args = getArgs(utils.allocator, true, {}, func.?.args, func.?.args_T, info, isolate, ctx) catch unreachable;
            obj_ptr.* = @call(.{}, T.constructor, args);
            if (Store.default != null) {
                Store.default.?.addObject(obj_ptr, T_refl.size, T_refl.alignment) catch unreachable; // TODO: internal exception
            }

            // bind the zig object to it's javascript counterpart
            var ext: v8.External = undefined;
            if (comptime T_refl.is_mem_guarantied()) {
                ext = v8.External.init(isolate, obj_ptr);
            } else {
                var int_ptr = utils.allocator.create(usize) catch unreachable;
                int_ptr.* = @ptrToInt(obj_ptr);
                if (Store.default != null) {
                    Store.default.?.addObject(int_ptr, @sizeOf(usize), @alignOf(usize)) catch unreachable;
                }
                ext = v8.External.init(isolate, int_ptr);
                refs.addObject(utils.allocator, int_ptr.*, T_refl.index) catch unreachable;
            }
            const js_obj = info.getThis();
            js_obj.setInternalField(0, ext);
        }
    };
    return cbk.constructor;
}

fn generateGetter(comptime T_refl: refl.Struct, comptime func: refl.Func, comptime all_T: []refl.Struct) v8.AccessorNameGetterCallback {
    const cbk = struct {
        fn getter(_: ?*const v8.Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.C) void {
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();

            // TODO: check func params length

            // retrieve the zig object from it's javascript counterpart
            const T = T_refl.T;
            const ext = info.getThis().getInternalField(0).castTo(v8.External);
            var obj_ptr: *T = undefined;
            if (comptime T_refl.is_mem_guarantied()) {
                obj_ptr = @ptrCast(*T, ext.get().?);
            } else {
                obj_ptr = refs.getObject(T, all_T, ext.get().?) catch unreachable;
            }

            // call the corresponding zig object method
            const getter_func = @field(T, func.name);
            const res = @call(.{}, getter_func, .{obj_ptr.*});

            // return to javascript the result
            nativeToJS(func.return_type.?, res, info.getReturnValue(), isolate) catch unreachable; // TODO: js native exception
        }
    };
    return cbk.getter;
}

fn generateSetter(comptime T_refl: refl.Struct, comptime func: refl.Func, comptime all_T: []refl.Struct) v8.AccessorNameSetterCallback {
    const cbk = struct {
        // TODO: why can we use v8.Name but not v8.Value (v8.C_Value)?
        fn setter(_: ?*const v8.Name, raw_value: ?*const v8.C_Value, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.C) void {
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();

            // TODO: check func params length

            // get the value set in javascript
            const js_value = v8.Value{ .handle = raw_value.? };
            const zig_value = jsToNative(utils.allocator, func.args[0], js_value, isolate, isolate.getCurrentContext()) catch unreachable; // TODO: throw js exception

            // retrieve the zig object from it's javascript counterpart
            const T = T_refl.T;
            const ext = info.getThis().getInternalField(0).castTo(v8.External);
            var obj_ptr: *T = undefined;
            if (comptime T_refl.is_mem_guarantied()) {
                obj_ptr = @ptrCast(*T, ext.get().?);
            } else {
                obj_ptr = refs.getObject(T, all_T, ext.get().?) catch unreachable;
            }

            // call the corresponding zig object method
            const setter_func = @field(T, func.name);
            _ = @call(.{}, setter_func, .{ obj_ptr, zig_value }); // return should be void

            // return to javascript the provided value
            info.getReturnValue().setValueHandle(raw_value.?);
        }
    };
    return cbk.setter;
}

fn generateMethod(comptime T_refl: refl.Struct, comptime func: refl.Func, comptime all_T: []refl.Struct) v8.FunctionCallback {
    const cbk = struct {
        fn method(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();
            const ctx = isolate.getCurrentContext();

            // check func params length
            // if JS provide more arguments than defined natively, just ignore them
            // but if JS provide less argument, throw a TypeError
            // TODO: optional argument should allow a missing value
            const js_params_len = info.length();
            if (js_params_len < func.args.len) {
                const msg = std.fmt.allocPrint(utils.allocator, not_enough_args, .{ T_refl.name, func.js_name, func.args.len, js_params_len }) catch unreachable;
                return throwTypeError(msg, info.getReturnValue(), isolate);
            }

            // retrieve the zig object from it's javascript counterpart
            const T = T_refl.T;
            const ext = info.getThis().getInternalField(0).castTo(v8.External);
            var obj_ptr: *T = undefined;
            if (comptime T_refl.is_mem_guarantied()) {
                obj_ptr = @ptrCast(*T, ext.get().?);
            } else {
                obj_ptr = refs.getObject(T, all_T, ext.get().?) catch unreachable;
            }

            // call the corresponding zig object method
            const method_func = @field(T, func.name);
            const args = getArgs(utils.allocator, false, obj_ptr.*, func.args, func.args_T, info, isolate, ctx) catch unreachable;
            const res = @call(.{}, method_func, args);

            // return to javascript the result
            nativeToJS(func.return_type.?, res, info.getReturnValue(), isolate) catch unreachable; // TODO: js native exception
        }
    };
    return cbk.method;
}

const ProtoTpl = struct {
    tpl: v8.FunctionTemplate,
    index: usize,
};

const LoadFunc = (fn (v8.Isolate, v8.ObjectTemplate, ?ProtoTpl) anyerror!ProtoTpl);

fn do(comptime T_refl: refl.Struct, comptime all_T: []refl.Struct) LoadFunc {
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
            obj_tpl.setInternalFieldCount(1);

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
    proto_tpl_index: ?usize = null,
    load: LoadFunc,
};

pub fn compile(comptime types: anytype) []API {
    comptime {

        // call types reflection
        const all_T = refl.do(types);

        var apis: [all_T.len]API = undefined;
        inline for (all_T) |T_refl, i| {
            const loader = do(T_refl, all_T);

            if (T_refl.proto_index == null) {
                // no prototype
                apis[i] = API{ .load = loader };
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
            apis[i] = API{ .proto_tpl_index = proto_tpl_index, .load = loader };
        }

        return &apis;
    }
}

pub fn load(isolate: v8.Isolate, globals: v8.ObjectTemplate, comptime apis: []API) !void {
    var tpls: [apis.len]ProtoTpl = undefined;
    inline for (apis) |api, i| {
        if (api.proto_tpl_index == null) {
            tpls[i] = try api.load(isolate, globals, null);
        } else {
            const proto_tpl = tpls[api.proto_tpl_index.?]; // safe because apis are ordered from parent to child
            tpls[i] = try api.load(isolate, globals, proto_tpl);
        }
    }
}
