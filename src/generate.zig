const std = @import("std");
const v8 = @import("v8");
const refl = @import("reflect.zig");

fn returnValue(comptime T: type, zig_res: T, js_res: v8.ReturnValue, isolate: v8.Isolate) !void {
    switch (T) {
        i32 => js_res.set(v8.Integer.initI32(isolate, zig_res)),
        else => return error.NativeTypeUnhandled,
    }
}

fn argValue(comptime T: type, comptime index: u32, comptime info_T: type, info: info_T, ctx: v8.Context) !T {
    const arg = info.getArg(index);
    switch (T) {
        i32 => return try arg.toI32(ctx),
        else => return error.JSTypeUnhandled,
    }
}

fn callWithArgs(comptime function: anytype, comptime params: []type, comptime res_T: type, comptime info_T: type, info: info_T, ctx: v8.Context) !res_T {
    // TODO: can we do that iterating on params ?
    switch (params.len) {
        0 => return @call(.{}, function, .{}),
        1 => {
            const arg1 = try argValue(params[0], 0, info_T, info, ctx);
            return @call(.{}, function, .{arg1});
        },
        2 => {
            const arg1 = try argValue(params[0], 0, info_T, info, ctx);
            const arg2 = try argValue(params[1], 1, info_T, info, ctx);
            return @call(.{}, function, .{ arg1, arg2 });
        },
        else => {
            @compileError("wrong arg nb to call obj_ptr");
        },
    }
}

fn callWithArgsSelf(comptime function: anytype, comptime self_T: type, self: self_T, comptime params: []type, comptime res_T: type, comptime info_T: type, info: info_T, ctx: v8.Context) !res_T {
    // TODO: can we do that iterating on params ?
    switch (params.len) {
        0 => return @call(.{}, function, .{self}),
        1 => {
            const arg1 = try argValue(params[0], 0, info_T, info, ctx);
            return @call(.{}, function, .{ self, arg1 });
        },
        2 => {
            const arg1 = try argValue(params[0], 0, info_T, info, ctx);
            const arg2 = try argValue(params[1], 1, info_T, info, ctx);
            return @call(.{}, function, .{ self, arg1, arg2 });
        },
        else => {
            @compileError("wrong arg nb to call obj_ptr");
        },
    }
}

fn generateGetter(comptime T: type, comptime func: refl.FuncReflected) type {
    return struct {
        fn getter(_: ?*const v8.Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.C) void {
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();

            // retrieve the zig object from it's javascript counterpart
            const external = info.getThis().getInternalField(0).castTo(v8.External);
            const zig_obj_ptr = @ptrCast(*T, external.get());

            // return to javascript the corresponding zig object method result
            const zig_getter = @field(T, func.name);
            const zig_res = @call(.{}, zig_getter, .{zig_obj_ptr.*});
            returnValue(func.return_type.?, zig_res, info.getReturnValue(), isolate) catch unreachable; // TODO: js native exception
        }
    };
}

fn generateMethod(comptime T: type, comptime func: refl.FuncReflected) type {
    return struct {
        fn method(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();
            const ctx = isolate.getCurrentContext();

            // retrieve the zig object from it's javascript counterpart
            const external = info.getThis().getInternalField(0).castTo(v8.External);
            const zig_obj_ptr = @ptrCast(*T, external.get());

            // return to javascript the corresponding zig object method result
            const zig_method = @field(T, func.name);
            const zig_res = callWithArgsSelf(zig_method, T, zig_obj_ptr.*, func.args, func.return_type.?, v8.FunctionCallbackInfo, info, ctx) catch unreachable; // TODO: js exception
            returnValue(func.return_type.?, zig_res, info.getReturnValue(), isolate) catch unreachable; // TODO: js native exception
        }
    };
}

// This function must be called comptime
pub fn generateAPI(comptime T: type, comptime struct_gen: refl.StructReflected) type {
    var t = struct {
        const Self = @This();

        pub fn load(isolate: v8.Isolate, globals: v8.ObjectTemplate) void {
            // create a v8 FunctionTemplate for the T constructor function,
            // with the corresponding zig callback,
            // and attach it to the global namespace
            var constructor_tpl = v8.FunctionTemplate.initCallback(isolate, Self.constructor);
            const constructor_key = v8.String.initUtf8(isolate, struct_gen.name);
            globals.set(constructor_key, constructor_tpl, v8.PropertyAttribute.None);

            // get the v8 ObjectTemplate attached to the constructor
            // and set 1 internal field to bind the counterpart zig object
            const object_tpl = constructor_tpl.getInstanceTemplate();
            object_tpl.setInternalFieldCount(1);

            // set getters for the v8 ObjectTemplate,
            // with the corresponding zig callbacks
            inline for (struct_gen.getters) |getter| {
                const func = generateGetter(T, getter);
                const key = v8.String.initUtf8(isolate, getter.js_name);
                object_tpl.setGetter(key, func.getter);
            }

            // create a v8 FunctinTemplate for each T methods,
            // with the corresponding zig callbacks,
            // and attach them to the object template
            inline for (struct_gen.methods) |method| {
                const func = generateMethod(T, method);
                var tpl = v8.FunctionTemplate.initCallback(isolate, func.method);
                const key = v8.String.initUtf8(isolate, method.js_name);
                object_tpl.set(key, tpl, v8.PropertyAttribute.None);
            }
        }

        fn constructor(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            const isolate = info.getIsolate();
            const ctx = isolate.getCurrentContext();

            // check func params length
            const params = struct_gen.constructor.args;
            if (info.length() != params.len) {
                std.log.debug("wrong params nb\n", .{});
                // TODO: js exception
                return;
            }

            // allocator, we need to put the zig object on the heap
            // otherwise on the stack it will be delete when the function returns
            // TODO: better way to handle that ? If not better allocator ?
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            const alloc = gpa.allocator();

            // create and allocate the zig object
            var obj_ptr = alloc.create(T) catch unreachable;
            obj_ptr.* = callWithArgs(T.constructor, params, T, v8.FunctionCallbackInfo, info, ctx) catch unreachable; // TODO: js exception

            // bind the zig object to it's javascript counterpart
            const external = v8.External.init(isolate, obj_ptr);
            const js_obj = info.getThis();
            js_obj.setInternalField(0, external);
        }
    };

    return t;
}
