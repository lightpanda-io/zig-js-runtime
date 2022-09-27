const std = @import("std");
const v8 = @import("v8");
const utils = @import("utils.zig");
const Store = @import("store.zig");
const refl = @import("reflect.zig");

fn returnValue(comptime T: type, zig_res: T, js_res: v8.ReturnValue, isolate: v8.Isolate) !void {
    switch (T) {
        []u8 => js_res.set(v8.String.initUtf8(isolate, zig_res)),
        u32 => js_res.set(v8.Integer.initU32(isolate, zig_res)),
        else => return error.NativeTypeUnhandled,
    }
}

fn throwTypeError(msg: []const u8, js_res: v8.ReturnValue, isolate: v8.Isolate) void {
    const err = v8.String.initUtf8(isolate, msg);
    const exception = v8.Exception.initTypeError(err);
    js_res.set(isolate.throwException(exception));
}

fn jsToNative(_: std.mem.Allocator, comptime T: type, value: v8.Value, isolate: v8.Isolate, ctx: v8.Context) !T {
    switch (T) {
        []u8 => {
            const buf = utils.valueToUtf8(utils.allocator, value, isolate, ctx);
            try Store.default.addString(buf);
            return buf;
        },
        u32 => return try value.toU32(ctx),
        else => return error.JSTypeUnhandled,
    }
}

fn callWithArgs(alloc: std.mem.Allocator, comptime function: anytype, comptime params: []type, comptime res_T: type, comptime info_T: type, info: info_T, isolate: v8.Isolate, ctx: v8.Context) !res_T {
    // TODO: can we do that iterating on params ?
    switch (params.len) {
        0 => return @call(.{}, function, .{}),
        1 => {
            const arg1 = try jsToNative(alloc, params[0], info.getArg(0), isolate, ctx);
            return @call(.{}, function, .{arg1});
        },
        2 => {
            const arg1 = try jsToNative(alloc, params[0], info.getArg(0), isolate, ctx);
            const arg2 = try jsToNative(alloc, params[1], info.getArg(1), isolate, ctx);
            return @call(.{}, function, .{ arg1, arg2 });
        },
        3 => {
            const arg1 = try jsToNative(alloc, params[0], info.getArg(0), isolate, ctx);
            const arg2 = try jsToNative(alloc, params[1], info.getArg(1), isolate, ctx);
            const arg3 = try jsToNative(alloc, params[2], info.getArg(2), isolate, ctx);
            return @call(.{}, function, .{ arg1, arg2, arg3 });
        },
        else => {
            @compileError("wrong arg nb to call obj_ptr");
        },
    }
}

fn callWithArgsSelf(alloc: std.mem.Allocator, comptime function: anytype, comptime self_T: type, self: self_T, comptime params: []type, comptime res_T: type, comptime info_T: type, info: info_T, isolate: v8.Isolate, ctx: v8.Context) !res_T {
    // TODO: can we do that iterating on params ?
    switch (params.len) {
        0 => return @call(.{}, function, .{self}),
        1 => {
            const arg1 = try jsToNative(alloc, params[0], info.getArg(0), isolate, ctx);
            return @call(.{}, function, .{ self, arg1 });
        },
        2 => {
            const arg1 = try jsToNative(alloc, params[0], info.getArg(0), isolate, ctx);
            const arg2 = try jsToNative(alloc, params[1], info.getArg(1), isolate, ctx);
            return @call(.{}, function, .{ self, arg1, arg2 });
        },
        3 => {
            const arg1 = try jsToNative(alloc, params[0], info.getArg(0), isolate, ctx);
            const arg2 = try jsToNative(alloc, params[1], info.getArg(1), isolate, ctx);
            const arg3 = try jsToNative(alloc, params[2], info.getArg(2), isolate, ctx);
            return @call(.{}, function, .{ self, arg1, arg2, arg3 });
        },
        else => {
            @compileError("wrong arg nb to call obj_ptr");
        },
    }
}

fn generateConstructor(comptime T: type, comptime obj: refl.StructReflected, comptime func: ?refl.FuncReflected) v8.FunctionCallback {
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
            const js_params_len = info.length();
            if (js_params_len != func.?.args.len) {
                const msg = std.fmt.allocPrint(utils.allocator, "{s}.{s}: At least {d} argument required, but only {d} passed", .{ obj.name, func.?.js_name, func.?.args.len, js_params_len }) catch unreachable;
                Store.default.addString(msg) catch unreachable;
                return throwTypeError(msg, info.getReturnValue(), isolate);
            }

            // create and allocate the zig object
            // NOTE: we need to put the zig object on the heap
            // otherwise on the stack it will be delete when the function returns
            var zig_obj_ptr = utils.allocator.create(T) catch unreachable;
            zig_obj_ptr.* = callWithArgs(utils.allocator, T.constructor, func.?.args, T, v8.FunctionCallbackInfo, info, isolate, ctx) catch unreachable; // TODO: js exception
            Store.default.addObject(zig_obj_ptr, obj.size, obj.alignment) catch unreachable; // TODO: internal exception

            // bind the zig object to it's javascript counterpart
            const external = v8.External.init(isolate, zig_obj_ptr);
            const js_obj = info.getThis();
            js_obj.setInternalField(0, external);
        }
    };
    return cbk.constructor;
}

fn generateGetter(comptime T: type, comptime func: refl.FuncReflected) v8.AccessorNameGetterCallback {
    const cbk = struct {
        fn getter(_: ?*const v8.Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.C) void {
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();

            // TODO: check func params length

            // retrieve the zig object from it's javascript counterpart
            const external = info.getThis().getInternalField(0).castTo(v8.External);
            const zig_obj_ptr = @ptrCast(*T, external.get());

            // call the corresponding zig object method
            const zig_getter = @field(T, func.name);
            const zig_res = @call(.{}, zig_getter, .{zig_obj_ptr.*});

            // return to javascript the result
            returnValue(func.return_type.?, zig_res, info.getReturnValue(), isolate) catch unreachable; // TODO: js native exception
        }
    };
    return cbk.getter;
}

fn generateSetter(comptime T: type, comptime func: refl.FuncReflected) v8.AccessorNameSetterCallback {
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
            const external = info.getThis().getInternalField(0).castTo(v8.External);
            const zig_obj_ptr = @ptrCast(*T, external.get());

            // call the corresponding zig object method
            const zig_setter = @field(T, func.name);
            _ = @call(.{}, zig_setter, .{ zig_obj_ptr, zig_value }); // return should be void

            // return to javascript the provided value
            info.getReturnValue().setValueHandle(raw_value.?);
        }
    };
    return cbk.setter;
}

fn generateMethod(comptime T: type, comptime obj: refl.StructReflected, comptime func: refl.FuncReflected) v8.FunctionCallback {
    const cbk = struct {
        fn method(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();
            const ctx = isolate.getCurrentContext();

            // check func params length
            const js_params_len = info.length();
            if (js_params_len != func.args.len) {
                const msg = std.fmt.allocPrint(utils.allocator, "{s}.{s}: At least {d} argument required, but only {d} passed", .{ obj.name, func.js_name, func.args.len, js_params_len }) catch unreachable;
                throwTypeError(msg, info.getReturnValue(), isolate);
                return;
            }

            // retrieve the zig object from it's javascript counterpart
            const external = info.getThis().getInternalField(0).castTo(v8.External);
            const zig_obj_ptr = @ptrCast(*T, external.get());

            // call the corresponding zig object method
            const zig_method = @field(T, func.name);
            const zig_res = callWithArgsSelf(utils.allocator, zig_method, T, zig_obj_ptr.*, func.args, func.return_type.?, v8.FunctionCallbackInfo, info, isolate, ctx) catch unreachable; // TODO: js exception

            // return to javascript the result
            returnValue(func.return_type.?, zig_res, info.getReturnValue(), isolate) catch unreachable; // TODO: js native exception
        }
    };
    return cbk.method;
}

pub fn API(comptime T: type, comptime obj: refl.StructReflected) type {
    return struct {
        pub fn load(isolate: v8.Isolate, globals: v8.ObjectTemplate) void {

            // create a v8 FunctionTemplate for the T constructor function,
            // with the corresponding zig callback,
            // and attach it to the global namespace
            const cstr_func = generateConstructor(T, obj, obj.constructor);
            const cstr_tpl = v8.FunctionTemplate.initCallback(isolate, cstr_func);
            const cstr_key = v8.String.initUtf8(isolate, obj.name);
            globals.set(cstr_key, cstr_tpl, v8.PropertyAttribute.None);

            // get the v8 ObjectTemplate attached to the constructor
            // and set 1 internal field to bind the counterpart zig object
            const object_tpl = cstr_tpl.getInstanceTemplate();
            object_tpl.setInternalFieldCount(1);

            // set getters for the v8 ObjectTemplate,
            // with the corresponding zig callbacks
            inline for (obj.getters) |getter| {
                const getter_func = generateGetter(T, getter);
                const key = v8.String.initUtf8(isolate, getter.js_name);
                if (getter.setter_index == null) {
                    object_tpl.setGetter(key, getter_func);
                } else {
                    const setter = obj.setters[getter.setter_index.?];
                    const setter_func = generateSetter(T, setter);
                    object_tpl.setGetterAndSetter(key, getter_func, setter_func);
                }
            }

            // create a v8 FunctinTemplate for each T methods,
            // with the corresponding zig callbacks,
            // and attach them to the object template
            inline for (obj.methods) |method| {
                const func = generateMethod(T, obj, method);
                const tpl = v8.FunctionTemplate.initCallback(isolate, func);
                const key = v8.String.initUtf8(isolate, method.js_name);
                object_tpl.set(key, tpl, v8.PropertyAttribute.None);
            }
        }
    };
}
