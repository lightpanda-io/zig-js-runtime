const std = @import("std");

const v8 = @import("v8"); // TODO: remove

const refl = @import("../../internal_api.zig").refl;

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
        inline for (func.args) |arg, i| {
            if (arg.T == Arg) {
                js_args_indexes[x] = i;
                x += 1;
            }
        }

        // retrieve callback arguments
        // var js_args: [func.args_callback_nb]v8.Value = undefined;
        var js_args = try alloc.alloc(v8.Value, func.args_callback_nb);
        for (js_args_indexes) |index, i| {
            js_args[i] = info.getArg(@intCast(u32, index - func.index_offset));
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

    // NOTE: we use persistent handles here
    // to ensure the references are not garbage collected
    // at the end of the JS calling function execution.
    js_func_pers: *PersistentFunction,
    js_args_pers: []PersistentValue,

    isolate: v8.Isolate,

    pub fn init(
        // NOTE: we need to store the JS callback arguments on the heap
        // as the call method will be executed in another stack frame,
        // once the asynchronous operation will be fetched back from the kernel.
        alloc: std.mem.Allocator,
        comptime func: refl.Func,
        info: v8.FunctionCallbackInfo,
        isolate: v8.Isolate,
    ) !Func {

        // retrieve callback arguments indexes
        // TODO: Should we do that at reflection?
        comptime var js_args_indexes: [func.args_callback_nb]usize = undefined;
        comptime var x: usize = 0;
        inline for (func.args) |arg, i| {
            if (arg.T == Arg) {
                js_args_indexes[x] = i;
                x += 1;
            }
        }

        // retrieve callback arguments
        var js_args_pers = try alloc.alloc(PersistentValue, func.args_callback_nb);
        for (js_args_indexes) |index, i| {
            const js_arg = info.getArg(@intCast(u32, index - func.index_offset));
            const js_arg_pers = PersistentValue.init(isolate, js_arg);
            js_args_pers[i] = js_arg_pers;
        }

        // retrieve callback function
        const js_func_index = func.callback_index.? - func.index_offset - 1; // -1 because of self
        const js_func_val = info.getArg(js_func_index);
        if (!js_func_val.isFunction()) {
            return error.JSWrongType;
        }
        const js_func = js_func_val.castTo(v8.Function);

        // const js_func_pers = PersistentFunction.init(isolate, js_func);
        var js_func_pers = try alloc.create(PersistentFunction);
        js_func_pers.* = PersistentFunction.init(isolate, js_func);

        return Func{
            .js_func_pers = js_func_pers,
            .js_args_pers = js_args_pers,
            .isolate = isolate,
        };
    }

    fn deinit(self: Func, alloc: std.mem.Allocator) void {
        // cleanup persistent references in v8
        var js_func_pers = self.js_func_pers; // TODO: why do we need var here?
        js_func_pers.deinit();

        for (self.js_args_pers) |arg| {
            var arg_pers = arg; // TODO: why do we need var here?
            arg_pers.deinit();
        }

        // free heap
        alloc.free(self.js_args_pers);
        alloc.destroy(self.js_func_pers);
    }

    pub fn call(self: Func, alloc: std.mem.Allocator) anyerror!void {
        defer self.deinit(alloc);

        // retrieve context
        // TODO: should we instead store the original context in the Func object?
        // in this case we need to have a permanent handle (Global ?) on it.
        const ctx = self.isolate.getCurrentContext();

        // retrieve JS function from persistent handle
        const js_func = self.js_func_pers.castToFunction();

        // retrieve JS arguments from persistent handle
        const js_args = try alloc.alloc(v8.Value, self.js_args_pers.len);
        defer alloc.free(js_args);
        for (self.js_args_pers) |arg, i| {
            js_args[i] = arg.toValue();
        }

        // retrieve JS "this" from persistent handle
        // TODO: see correct "this" comment above
        const this = ctx.getGlobal();

        // execute function
        const result = js_func.call(ctx, this, js_args);
        if (result == null) {
            return error.JSCallback;
        }
    }
};
