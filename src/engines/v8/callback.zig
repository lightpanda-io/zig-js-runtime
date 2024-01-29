const std = @import("std");

const v8 = @import("v8"); // TODO: remove

const internal = @import("../../internal_api.zig");
const refl = internal.refl;
const gen = internal.gen;
const NativeContext = internal.NativeContext;

const JSObjectID = @import("v8.zig").JSObjectID;
const setNativeType = @import("generate.zig").setNativeType;

// TODO: Make this JS engine agnostic
// by providing a common interface

pub const Arg = struct {
    // TODO: it's required to have a non-empty struct
    // otherwise LLVM emits a warning
    // "stack frame size (x) exceeds limit (y)"
    // foo: bool = false,
};

// TODO: set the correct "this" on Func object
// see https://developer.mozilla.org/en-US/docs/Web/API/setTimeout#the_this_problem
// should we use:
// - the context globals?
// - null?
// - the calling function (info.getThis)?

pub const FuncSync = struct {
    js_func: v8.Function,
    js_args: []v8.Value,
    isolate: v8.Isolate,

    pub fn init(
        alloc: std.mem.Allocator,
        comptime func: refl.Func,
        info: v8.FunctionCallbackInfo,
        isolate: v8.Isolate,
    ) !FuncSync {

        // retrieve callback arguments indexes
        // TODO: Should we do that at reflection?
        comptime var js_args_indexes: [func.args_callback_nb]usize = undefined;
        comptime var x: usize = 0;
        inline for (func.args, 0..) |arg, i| {
            if (arg.T == Arg) {
                js_args_indexes[x] = i;
                x += 1;
            }
        }

        // retrieve callback arguments
        // var js_args: [func.args_callback_nb]v8.Value = undefined;
        var js_args = try alloc.alloc(v8.Value, func.args_callback_nb);
        for (js_args_indexes, 0..) |index, i| {
            js_args[i] = info.getArg(@as(u32, @intCast(index - func.index_offset)));
        }

        // retrieve callback function
        const js_func_index = func.callback_index.? - func.index_offset - 1; // -1 because of self
        const js_func_val = info.getArg(js_func_index);
        if (!js_func_val.isFunction()) {
            return error.JSWrongType;
        }
        const js_func = js_func_val.castTo(v8.Function);

        return FuncSync{
            .js_func = js_func,
            .js_args = js_args,
            .isolate = isolate,
        };
    }

    pub fn call(self: FuncSync, alloc: std.mem.Allocator) anyerror!void {

        // retrieve context
        // NOTE: match the Func.call implementation
        const ctx = self.isolate.getCurrentContext();

        // retrieve JS this from persistent handle
        // TODO: see correct "this" comment above
        const this = ctx.getGlobal();

        // execute function
        _ = self.js_func.call(ctx, this, self.js_args);

        // free heap
        alloc.free(self.js_args);
    }
};

const PersistentFunction = v8.Persistent(v8.Function);
const PersistentValue = v8.Persistent(v8.Value);

pub const Func = struct {
    _id: JSObjectID,

    // NOTE: we use persistent handles here
    // to ensure the references are not garbage collected
    // at the end of the JS calling function execution.
    js_func_pers: PersistentFunction,

    // TODO: as we know this information at comptime
    // we could change this to a generics function with JS args len as param
    // avoiding the need to allocate/free js_args_pers
    js_args_pers: []PersistentValue,

    nat_ctx: *NativeContext,
    isolate: v8.Isolate,

    pub fn init(
        alloc: std.mem.Allocator,
        nat_ctx: *NativeContext,
        comptime func: refl.Func,
        info: v8.FunctionCallbackInfo,
        isolate: v8.Isolate,
    ) !Func {

        // retrieve callback function
        const js_func_index = func.callback_index.? - func.index_offset - 1; // -1 because of self
        const js_func_val = info.getArg(js_func_index);
        if (!js_func_val.isFunction()) {
            return error.JSWrongType;
        }
        const js_func = js_func_val.castTo(v8.Function);
        const js_func_pers = PersistentFunction.init(isolate, js_func);

        // NOTE: we need to store the JS callback arguments on the heap
        // as the call method will be executed in another stack frame,
        // once the asynchronous operation will be fetched back from the kernel.
        var js_args_pers = try alloc.alloc(PersistentValue, func.args_callback_nb);

        // retrieve callback arguments indexes
        if (comptime func.args_callback_nb > 0) {

            // TODO: Should we do that at reflection?
            comptime var js_args_indexes: [func.args_callback_nb]usize = undefined;
            comptime {
                var x: usize = 0;
                for (func.args, 0..) |arg, i| {
                    if (arg.T == Arg) {
                        js_args_indexes[x] = i;
                        x += 1;
                    }
                }
            }

            // retrieve callback arguments
            for (js_args_indexes, 0..) |index, i| {
                const js_arg = info.getArg(@as(u32, @intCast(index - func.index_offset)));
                const js_arg_pers = PersistentValue.init(isolate, js_arg);
                js_args_pers[i] = js_arg_pers;
            }
        }

        return Func{
            ._id = JSObjectID.set(js_func_val.castTo(v8.Object)),
            .js_func_pers = js_func_pers,
            .js_args_pers = js_args_pers,
            .nat_ctx = nat_ctx,
            .isolate = isolate,
        };
    }

    pub fn deinit(self: Func, alloc: std.mem.Allocator) void {

        // cleanup persistent references in v8
        var js_func_pers = self.js_func_pers; // TODO: why do we need var here?
        js_func_pers.deinit();

        for (self.js_args_pers) |arg| {
            var arg_pers = arg; // TODO: why do we need var here?
            arg_pers.deinit();
        }

        // free heap
        alloc.free(self.js_args_pers);
    }

    pub fn id(self: Func) usize {
        return self._id.get();
    }

    pub fn call(
        self: Func,
        nat_args: anytype,
    ) anyerror!void {

        // ensure Native args and JS args are not both provided
        const info = @typeInfo(@TypeOf(nat_args));
        if (comptime info != .Null) {
            // TODO: could be a compile error if we use generics for JS args
            std.debug.assert(self.js_args_pers.len == 0);
        }

        // retrieve context
        // TODO: should we instead store the original context in the Func object?
        // in this case we need to have a permanent handle (Global ?) on it.
        const js_ctx = self.isolate.getCurrentContext();

        // retrieve JS function from persistent handle
        const js_func = self.js_func_pers.castToFunction();

        // retrieve arguments
        var args = try self.nat_ctx.alloc.alloc(v8.Value, self.js_args_pers.len);
        defer self.nat_ctx.alloc.free(args);
        if (comptime info == .Struct) {

            // - Native arguments provided on function call
            std.debug.assert(info.Struct.is_tuple);
            args = try self.nat_ctx.alloc.alloc(v8.Value, info.Struct.fields.len);
            comptime var i = 0;
            inline while (i < info.Struct.fields.len) {
                comptime var ret: refl.Type = undefined;
                comptime {
                    ret = try refl.Type.reflect(info.Struct.fields[i].type, null);
                    try ret.lookup(gen.Types);
                }
                args[i] = try setNativeType(
                    self.nat_ctx.alloc,
                    self.nat_ctx,
                    ret,
                    @field(nat_args, try refl.itoa(i)),
                    js_ctx,
                    self.isolate,
                );
                i += 1;
            }
        } else if (self.js_args_pers.len > 0) {

            // - JS arguments set previously
            for (self.js_args_pers, 0..) |arg, i| {
                args[i] = arg.toValue();
            }
        }
        // else -> no arguments

        // retrieve JS "this" from persistent handle
        // TODO: see correct "this" comment above
        const this = js_ctx.getGlobal();

        // execute function
        const result = js_func.call(js_ctx, this, args);
        if (result == null) {
            return error.JSCallback;
        }
    }
};
