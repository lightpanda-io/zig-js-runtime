const std = @import("std");

const v8 = @import("v8");

const internal = @import("../../internal_api.zig");
const refs = internal.refs;
const refl = internal.refl;
const gen = internal.gen;
const NativeContext = internal.NativeContext;

const public = @import("../../api.zig");
const Loop = public.Loop;
const JSObject = public.JSObject;

const cbk = @import("callback.zig");
const nativeToJS = @import("types_primitives.zig").nativeToJS;
const jsToNative = @import("types_primitives.zig").jsToNative;
const jsToObject = @import("types_primitives.zig").jsToObject;

const TPL = @import("v8.zig").TPL;

// Utils functions
// ---------------

fn throwBasicError(
    msg: []const u8,
    js_res: v8.ReturnValue,
    isolate: v8.Isolate,
) void {
    const except_msg = v8.String.initUtf8(isolate, msg);
    const exception = v8.Exception.initError(except_msg);
    js_res.set(isolate.throwException(exception));
}

fn throwError(
    alloc: std.mem.Allocator,
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime func: refl.Func,
    err: anyerror,
    js_res: v8.ReturnValue,
    isolate: v8.Isolate,
) void {
    const ret = func.return_type;

    // Is the returned Type a custom Exception error?
    // conditions:
    // - the return type must be an ErrorUnion
    // - the API must define a custom Exception
    // - the ErrorSet of the return type must be an error of Exception
    const except = comptime T_refl.exception(all_T);
    if (comptime ret.errorSet() == null or except == null) {
        return throwBasicError(@errorName(err), js_res, isolate);
    }
    if (!ret.isErrorException(except.?, err)) {
        return throwBasicError(@errorName(err), js_res, isolate);
    }

    // create custom error instance
    // TODO: by now the compiler is not able to see that we have ensure that at runtime
    // the error will be part of the ErrorSet of the custom exception.
    // So we have to use anyerror type here for now
    // and let the API implementation do the cast
    const obj = except.?.T.init(alloc, err, func.js_name) catch unreachable; // TODO
    const ctx = isolate.getCurrentContext();
    const js_obj = gen.getTpl(except.?.index).tpl.getInstanceTemplate().initInstance(ctx);
    _ = setNativeObject(
        alloc,
        except.?,
        @TypeOf(obj),
        obj,
        js_obj,
        isolate,
    ) catch unreachable;

    // throw exeption
    js_res.set(isolate.throwException(js_obj));

    // TODO: v8 does not throw a stack trace as Exception is not a prototype of Error
    // There is no way to change this with the current v8 public API
}

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
    cbk_info: CallbackInfo,
    raw_value: ?*const v8.C_Value,
    isolate: v8.Isolate,
) bool {

    // check mandatory args
    var func_args_len: usize = func.args.len;
    if (func.first_optional_arg) |args_mandatory| {
        func_args_len = args_mandatory;
    }
    func_args_len -= func.index_offset;

    // OK
    const js_args_len = cbk_info.length(raw_value);
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
    throwTypeError(msg, cbk_info.getReturnValue(), isolate);
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
        // if Native optional type return null
        if (comptime arg_T.underOpt() != null) {
            return null;
        }
        // TODO: else return error "Argument x is not an object"
    }

    // JS object
    const ptr = getNativeObject(
        T_refl,
        all_T,
        js_value.castTo(v8.Object),
    ) catch unreachable; // TODO: throw js exception
    if (arg_T.underPtr() != null) {
        value = ptr;
    } else {
        value = ptr.*;
    }
    return value;
}

fn getArg(
    alloc: std.mem.Allocator,
    loop: *Loop,
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime arg: refl.Type,
    this: v8.Object,
    js_val: ?v8.Value,
    isolate: v8.Isolate,
    ctx: v8.Context,
) arg.T {
    var value: arg.T = undefined;

    if (arg.isNative()) {

        // native types
        value = getNativeArg(all_T[arg.T_refl_index.?], all_T, arg, js_val.?);
    } else if (arg.nested_index) |index| {

        // nested types (ie. JS anonymous objects)
        value = jsToObject(
            alloc,
            T_refl.nested[index],
            arg.T,
            js_val.?,
            isolate,
            ctx,
        ) catch unreachable;
    } else {

        // builtin and internal types
        value = switch (arg.T) {
            std.mem.Allocator => alloc,
            *Loop => loop,
            cbk.Func, cbk.FuncSync, cbk.Arg => unreachable,
            JSObject => JSObject{ .ctx = ctx, .js_obj = this },
            else => jsToNative(
                alloc,
                arg.T,
                js_val.?,
                isolate,
                ctx,
            ) catch unreachable,
        };
    }

    return value;
}

const CallbackInfo = union(enum) {
    func_cbk: v8.FunctionCallbackInfo,
    prop_cbk: v8.PropertyCallbackInfo,

    fn getIsolate(self: CallbackInfo) v8.Isolate {
        return switch (self) {
            .func_cbk => self.func_cbk.getIsolate(),
            .prop_cbk => self.prop_cbk.getIsolate(),
        };
    }

    fn length(self: CallbackInfo, raw_value: ?*const v8.C_Value) u32 {
        return switch (self) {
            .func_cbk => self.func_cbk.length(),
            .prop_cbk => if (raw_value == null) 0 else 1,
        };
    }

    fn getThis(self: CallbackInfo) v8.Object {
        return switch (self) {
            .func_cbk => self.func_cbk.getThis(),
            .prop_cbk => self.prop_cbk.getThis(),
        };
    }

    fn getData(self: CallbackInfo) v8.Value {
        return switch (self) {
            .func_cbk => self.func_cbk.getData(),
            .prop_cbk => self.prop_cbk.getData(),
        };
    }

    fn getArg(
        self: CallbackInfo,
        raw_value: ?*const v8.C_Value,
        index: usize,
        index_offset: usize,
    ) ?v8.Value {
        const i = @as(i8, @intCast(index)) - @as(i8, @intCast(index_offset));
        if (i < 0) return null;
        switch (self) {
            .func_cbk => return self.func_cbk.getArg(@as(u32, @intCast(i))),
            .prop_cbk => {
                if (raw_value) |val| {
                    return v8.Value{ .handle = val };
                } else return null;
            },
        }
    }

    fn getReturnValue(self: CallbackInfo) v8.ReturnValue {
        return switch (self) {
            .func_cbk => self.func_cbk.getReturnValue(),
            .prop_cbk => self.prop_cbk.getReturnValue(),
        };
    }
};

// This function takes either a v8.FunctionCallbackInfo
// or a v8.Propertycallbackinfo
// in case of a setter raw_value is also required
fn getArgs(
    alloc: std.mem.Allocator,
    loop: *Loop,
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime func: refl.Func,
    cbk_info: CallbackInfo,
    raw_value: ?*const v8.C_Value,
    isolate: v8.Isolate,
    ctx: v8.Context,
) func.args_T {
    var args: func.args_T = undefined;

    const js_args_nb = cbk_info.length(raw_value);

    // iter on function expected arguments
    inline for (func.args, 0..) |arg, i| {

        // do not set empty arg
        if (@sizeOf(arg.T) == 0) {
            continue;
        }

        comptime var arg_real: refl.Type = undefined;

        comptime {
            if (try refl.Type.variadic(arg.underT())) |arg_v| {
                arg_real = arg_v;
            } else {
                arg_real = arg;
            }
        }

        var value: arg.T = undefined;

        if (arg.T == arg_real.T) {

            // non-variadic arg
            value = switch (arg.T) {

                // special cases for callback arguments
                // TODO: because thoses functions requires a v8.FunctionCallbackInfo
                // they will not be available for generators with v8.PropertyCallbackInfo
                // (getters and setters)
                cbk.Func => cbk.Func.init(
                    alloc,
                    func,
                    cbk_info.func_cbk,
                    isolate,
                ) catch unreachable,
                cbk.FuncSync => cbk.FuncSync.init(
                    alloc,
                    func,
                    cbk_info.func_cbk,
                    isolate,
                ) catch unreachable,
                cbk.Arg => cbk.Arg{}, // stage1: we need type

                // normal cases
                else => blk: {
                    break :blk getArg(
                        alloc,
                        loop,
                        T_refl,
                        all_T,
                        arg_real,
                        cbk_info.getThis(),
                        cbk_info.getArg(raw_value, i, func.index_offset),
                        isolate,
                        ctx,
                    );
                },
            };
        } else {

            // variadic arg
            // take all trailing JS arg as variadic members
            const rest_nb = js_args_nb - i + func.index_offset;
            const slice = alloc.alloc(arg_real.T, rest_nb) catch unreachable;
            var iter: usize = 0;
            while (iter < rest_nb) {
                const slice_value = getArg(
                    alloc,
                    loop,
                    T_refl,
                    all_T,
                    arg_real,
                    cbk_info.getThis(),
                    cbk_info.getArg(raw_value, iter + i, func.index_offset),
                    isolate,
                    ctx,
                );
                slice[iter] = slice_value;
                iter += 1;
            }
            value = .{ .slice = slice };
        }

        // set argument
        @field(args, arg.name.?) = value;
    }

    return args;
}

fn freeArgs(alloc: std.mem.Allocator, comptime func: refl.Func, obj: anytype) !void {
    inline for (func.args) |arg_T| {

        // free char slices
        // the API functions will be responsible of copying the slice
        // in their implementations if they want to keep it afterwards
        if (arg_T.underT() == []u8 or arg_T.underT() == []const u8) {
            const val = @field(obj, arg_T.name.?);
            if (arg_T.underOpt() != null) {
                // free only if val is non-null
                if (val) |v| {
                    alloc.free(v);
                }
            } else {
                alloc.free(val);
            }
        }

        // free varidadic slices
        if (try refl.Type.variadic(arg_T.underT()) != null) {
            const val = @field(obj, arg_T.name.?).?;
            // NOTE: variadic are optional by design
            alloc.free(@field(val, "slice"));
        }
    }
}

pub fn setNativeObject(
    alloc: std.mem.Allocator,
    comptime T_refl: refl.Struct,
    comptime T: type,
    obj: anytype,
    js_obj: v8.Object,
    isolate: v8.Isolate,
) !*T {

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
        return obj_ptr;
    }

    // bind the native object pointer to JS obj
    var ext: v8.External = undefined;
    if (comptime T_refl.is_mem_guarantied()) {
        // store directly the object pointer
        ext = v8.External.init(isolate, obj_ptr);
    } else {
        // use the refs mechanism
        const int_ptr = try alloc.create(usize);
        int_ptr.* = @intFromPtr(obj_ptr);
        ext = v8.External.init(isolate, int_ptr);
        try refs.addObject(alloc, int_ptr.*, T_refl.index);
    }
    js_obj.setInternalField(0, ext);
    return obj_ptr;
}

fn setReturnType(
    alloc: std.mem.Allocator,
    comptime all_T: []refl.Struct,
    comptime ret: refl.Type,
    comptime func: refl.Func,
    res: anytype,
    js_res: v8.ReturnValue,
    ctx: v8.Context,
    isolate: v8.Isolate,
) !v8.Value {
    const info = @typeInfo(@TypeOf(res));

    // Optional
    if (info == .Optional) {
        if (res == null) {
            // if null just return JS null
            return isolate.initNull().toValue();
        }
        return setReturnType(alloc, all_T, ret, func, res.?, js_res, ctx, isolate);
    }

    // Union type
    if (comptime ret.union_T) |union_types| {
        // retrieve the active field and setReturntype accordingly
        const activeTag = @tagName(std.meta.activeTag(res));
        // TODO: better algorythm?
        inline for (union_types) |tt| {
            if (std.mem.eql(u8, activeTag, tt.name.?)) {
                return setReturnType(
                    alloc,
                    all_T,
                    tt,
                    func,
                    @field(res, tt.name.?),
                    js_res,
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
                func,
                @field(res, name),
                js_res,
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
        const obj_ptr = setNativeObject(
            alloc,
            all_T[index],
            ret.underT(),
            res,
            js_obj,
            isolate,
        ) catch unreachable;

        // call postAttach func
        const T_refl = all_T[index];
        if (comptime try refl.postAttachFunc(T_refl.T)) |piArgsT| {
            postAttach(
                alloc,
                T_refl,
                all_T,
                func,
                piArgsT,
                obj_ptr,
                js_obj,
                js_res,
                ctx,
                isolate,
            );
        }

        return js_obj.toValue();
    }

    // return is a builtin type

    const js_val = nativeToJS(
        ret.underT(),
        res,
        isolate,
    ) catch unreachable; // NOTE: should not happen has types have been checked at reflect
    return js_val;
}

fn postAttach(
    alloc: std.mem.Allocator,
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime func: refl.Func,
    comptime argsT: type,
    obj_ptr: anytype,
    js_obj: v8.Object,
    js_res: v8.ReturnValue,
    ctx: v8.Context,
    isolate: v8.Isolate,
) void {
    var args: argsT = undefined;
    @field(args, "0") = obj_ptr;
    @field(args, "1") = JSObject{ .ctx = ctx, .js_obj = js_obj };
    const f = @field(T_refl.T, "postAttach");
    const ret = comptime try refl.funcReturnType(@TypeOf(f));
    if (comptime refl.isErrorUnion(ret)) {
        _ = @call(.auto, f, args) catch |err| {
            return throwError(
                alloc,
                T_refl,
                all_T,
                func,
                err,
                js_res,
                isolate,
            );
        };
    } else {
        _ = @call(
            .auto,
            f,
            args,
        );
    }
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
            const ptr: *align(@alignOf(T_refl.Self())) anyopaque = @alignCast(ext);
            if (@hasDecl(T_refl.T, "protoCast")) {
                // T_refl provides a function to cast the pointer from high level Type
                obj_ptr = @call(.auto, @field(T_refl.T, "protoCast"), .{ptr});
            } else {
                // memory layout is fixed through prototype chain of T_refl
                // with the proto Type at the begining of the address of the high level Type
                // so we can safely use @ptrCast
                obj_ptr = @as(*T, @ptrCast(ptr));
            }
        } else {
            // use the refs mechanism to retrieve from high level Type
            obj_ptr = try refs.getObject(T, all_T, ext);
        }
    }
    return obj_ptr;
}

fn callFunc(
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime func: refl.Func,
    comptime func_kind: refl.FuncKind,
    cbk_info: CallbackInfo,
    raw_value: ?*const v8.C_Value,
) void {

    // retrieve isolate and context
    const isolate = cbk_info.getIsolate();
    const ctx = isolate.getCurrentContext();

    if (comptime func_kind == .constructor and !T_refl.has_constructor) {
        return throwTypeError("Illegal constructor", cbk_info.getReturnValue(), isolate);
    }

    // check func params length
    if (!checkArgsLen(T_refl.name, func, cbk_info, raw_value, isolate)) {
        return;
    }

    // retrieve native context
    const nat_ctx_data = cbk_info.getData().castTo(v8.BigInt).getUint64();
    const nat_ctx_num = @as(usize, @intCast(nat_ctx_data));
    const nat_ctx = @as(*NativeContext, @ptrFromInt(nat_ctx_num));

    // prepare args
    var args = getArgs(
        nat_ctx.alloc,
        nat_ctx.loop,
        T_refl,
        all_T,
        func,
        cbk_info,
        raw_value,
        isolate,
        ctx,
    );

    // free memory if required
    defer freeArgs(nat_ctx.alloc, func, args) catch unreachable;

    // retrieve the zig object
    if (comptime func_kind != .constructor and !T_refl.isEmpty()) {
        const obj_ptr = getNativeObject(T_refl, all_T, cbk_info.getThis()) catch unreachable;
        const self_T = @TypeOf(@field(args, "0"));
        if (self_T == T_refl.Self()) {
            @field(args, "0") = obj_ptr.*;
        } else if (self_T == *T_refl.Self()) {
            @field(args, "0") = obj_ptr;
        }
    }

    // call native func
    const function = @field(T_refl.T, func.name);
    const res_T = func.return_type.underErr() orelse func.return_type.T;
    var res: res_T = undefined;
    if (comptime @typeInfo(func.return_type.T) == .ErrorUnion) {
        res = @call(.auto, function, args) catch |err| {
            // TODO: how to handle internal errors vs user errors
            return throwError(
                nat_ctx.alloc,
                T_refl,
                all_T,
                func,
                err,
                cbk_info.getReturnValue(),
                isolate,
            );
        };
    } else {
        res = @call(.auto, function, args);
    }

    if (comptime func_kind == .constructor) {

        // bind native object to JS object this
        _ = setNativeObject(
            nat_ctx.alloc,
            T_refl,
            func.return_type.underT(),
            res,
            cbk_info.getThis(),
            isolate,
        ) catch unreachable; // TODO: internal errors

        // call postAttach func
        if (comptime try refl.postAttachFunc(T_refl.T)) |piArgsT| {
            postAttach(
                nat_ctx.alloc,
                T_refl,
                all_T,
                func,
                piArgsT,
                &res,
                cbk_info.getThis(),
                cbk_info.getReturnValue(),
                ctx,
                isolate,
            );
        }
    } else {

        // return to javascript the result
        const js_val = setReturnType(
            nat_ctx.alloc,
            all_T,
            func.return_type,
            func,
            res,
            cbk_info.getReturnValue(),
            ctx,
            isolate,
        ) catch unreachable; // TODO: internal errors
        cbk_info.getReturnValue().setValueHandle(js_val.handle);
    }

    // sync callback
    // for test purpose, does not have any sense in real case
    if (comptime func.callback_index != null) {
        // -1 because of self
        const js_func_index = func.callback_index.? - func.index_offset - 1;
        if (func.args[js_func_index].T == cbk.FuncSync) {
            args[func.callback_index.? - func.index_offset].call(nat_ctx.alloc) catch unreachable;
        }
    }
}

// JS functions callbacks
// ----------------------

fn generateConstructor(
    comptime T_refl: refl.Struct,
    comptime all_T: []refl.Struct,
    comptime func: refl.Func,
) v8.FunctionCallback {
    return struct {
        fn constructor(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {

            // callFunc
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            callFunc(
                T_refl,
                all_T,
                func,
                .constructor,
                CallbackInfo{ .func_cbk = info },
                null,
            );
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

            // callFunc
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            callFunc(
                T_refl,
                all_T,
                func,
                .getter,
                CallbackInfo{ .prop_cbk = info },
                null,
            );
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

            // callFunc
            const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
            callFunc(
                T_refl,
                all_T,
                func,
                .setter,
                CallbackInfo{ .prop_cbk = info },
                raw_value,
            );
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

            // callFunc
            const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
            callFunc(
                T_refl,
                all_T,
                func,
                .method,
                CallbackInfo{ .func_cbk = info },
                null,
            );
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
    inline for (@typeInfo(attrs_T).Struct.fields, 0..) |field, i| {
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
    inline for (@typeInfo(attrs_T).Struct.fields, 0..) |field, i| {
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
    inline for (@typeInfo(attrs_T).Struct.fields, 0..) |_, i| {
        template.set(keys[i], values[i], v8.PropertyAttribute.ReadOnly + v8.PropertyAttribute.DontDelete);
    }
}

pub const LoadFnType = (fn (*NativeContext, v8.Isolate, v8.ObjectTemplate, ?TPL) anyerror!TPL);

pub fn loadFn(comptime T_refl: refl.Struct, comptime all_T: []refl.Struct) LoadFnType {
    return struct {

        // NOTE: the load function and it's callbacks constructor/getter/setter/method
        // are executed at runtime !

        const LoadError = error{
            NoPrototypeTemplateProvided,
            WrongPrototypeTemplateProvided,
        };

        pub fn load(
            nat_ctx: *NativeContext,
            isolate: v8.Isolate,
            globals: v8.ObjectTemplate,
            proto_tpl: ?TPL,
        ) LoadError!TPL {

            // native context
            const nat_ctx_num = @as(u64, @intCast(@intFromPtr(nat_ctx)));
            const nat_ctx_data = isolate.initBigIntU64(nat_ctx_num);

            // create a v8 FunctionTemplate for the T constructor function,
            // with the corresponding zig callback,
            // and attach it to the global namespace
            const cstr_func = generateConstructor(T_refl, all_T, T_refl.constructor);
            const cstr_tpl = v8.FunctionTemplate.initCallbackData(isolate, cstr_func, nat_ctx_data);
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
                    return LoadError.NoPrototypeTemplateProvided;
                }
                if (T_refl.proto_index.? != proto_tpl.?.index) {
                    return LoadError.WrongPrototypeTemplateProvided;
                }
                // at instance level, inherit from proto template
                // ie. an instance of the Child function has all properties
                // on Parent's instance template
                // ie. <Child>.prototype.__proto__ === <Parent>.prototype
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
                    prototype.setGetterData(key, getter_func, nat_ctx_data);
                } else {
                    const setter = T_refl.setters[getter.setter_index.?];
                    const setter_func = generateSetter(T_refl, setter, all_T);
                    prototype.setGetterAndSetterData(key, getter_func, setter_func, nat_ctx_data);
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
                const func_tpl = v8.FunctionTemplate.initCallbackData(isolate, func, nat_ctx_data);
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
