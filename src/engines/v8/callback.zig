// Copyright 2023-2024 Lightpanda (Selecy SAS)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

const v8 = @import("v8"); // TODO: remove

const internal = @import("../../internal_api.zig");
const refl = internal.refl;
const gen = internal.gen;
const NativeContext = internal.NativeContext;

const JSObjectID = @import("v8.zig").JSObjectID;
const setNativeType = @import("generate.zig").setNativeType;
const CallbackInfo = @import("generate.zig").CallbackInfo;
const getV8Object = @import("generate.zig").getV8Object;

const valueToUtf8 = @import("types_primitives.zig").valueToUtf8;

// TODO: Make this JS engine agnostic
// by providing a common interface

pub const Arg = struct {
    // TODO: it's required to have a non-empty struct
    // otherwise LLVM emits a warning
    // "stack frame size (x) exceeds limit (y)"
    // foo: bool = false,
};

pub const Result = struct {
    alloc: std.mem.Allocator,
    success: bool = false,
    result: ?[]const u8 = null,
    stack: ?[]const u8 = null,

    pub fn init(alloc: std.mem.Allocator) Result {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: Result) void {
        if (self.result) |res| self.alloc.free(res);
        if (self.stack) |stack| self.alloc.free(stack);
    }

    pub fn setError(
        self: *Result,
        isolate: v8.Isolate,
        js_ctx: v8.Context,
        try_catch: v8.TryCatch,
    ) !void {
        self.success = false;

        // exception
        if (try_catch.getException()) |except| {
            self.result = try valueToUtf8(self.alloc, except, isolate, js_ctx);
        }

        // stack
        if (try_catch.getStackTrace(js_ctx)) |stack| {
            self.stack = try valueToUtf8(self.alloc, stack, isolate, js_ctx);
        }
    }
};

pub const FuncSync = struct {
    js_func: v8.Function,
    js_args: []v8.Value,

    nat_ctx: *NativeContext,
    isolate: v8.Isolate,

    thisArg: ?v8.Object = null,

    pub fn init(
        alloc: std.mem.Allocator,
        nat_ctx: *NativeContext,
        comptime func: refl.Func,
        raw_value: ?*const v8.C_Value,
        info: CallbackInfo,
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
            js_args[i] = info.getArg(raw_value, index, func.index_offset) orelse unreachable;
        }

        var idx = func.callback_index.?;
        if (idx > 0) idx = idx - 1; // -1 because of self

        // retrieve callback function
        const js_func_val = info.getArg(
            raw_value,
            idx,
            func.index_offset,
        ) orelse unreachable;

        if (!js_func_val.isFunction()) {
            return error.JSWrongType;
        }
        const js_func = js_func_val.castTo(v8.Function);

        return FuncSync{
            .js_func = js_func,
            .js_args = js_args,
            .nat_ctx = nat_ctx,
            .isolate = isolate,
        };
    }

    pub fn setThisArg(self: *FuncSync, nat_obj_ptr: anytype) !void {
        self.thisArg = try getV8Object(
            self.nat_ctx,
            nat_obj_ptr,
        ) orelse return error.V8ObjectNotFound;
    }

    // call the function with a try catch to catch errors an report in res.
    pub fn trycall(self: FuncSync, alloc: std.mem.Allocator, res: *Result) anyerror!void {
        // JS try cache
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(self.isolate);
        defer try_catch.deinit();

        self.call(alloc) catch |e| {
            res.success = false;
            if (try_catch.hasCaught()) {
                // retrieve context
                // NOTE: match the Func.call implementation
                const ctx = self.isolate.getCurrentContext();
                try res.setError(self.isolate, ctx, try_catch);
            }

            return e;
        };

        res.success = true;
    }

    pub fn call(self: FuncSync, alloc: std.mem.Allocator) anyerror!void {

        // retrieve context
        // NOTE: match the Func.call implementation
        const ctx = self.isolate.getCurrentContext();

        // Callbacks are typically called with a this value of undefined.
        // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/this#callbacks
        // TODO use undefined this instead of global.
        const this = self.thisArg orelse ctx.getGlobal();

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

    thisArg: ?v8.Object = null,

    pub fn init(
        alloc: std.mem.Allocator,
        nat_ctx: *NativeContext,
        comptime func: refl.Func,
        raw_value: ?*const v8.C_Value,
        info: CallbackInfo,
        isolate: v8.Isolate,
    ) !Func {
        var idx = func.callback_index.?;
        if (idx > 0) idx = idx - 1; // -1 because of self

        // retrieve callback function
        const js_func_val = info.getArg(
            raw_value,
            idx,
            func.index_offset,
        ) orelse unreachable;
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
                const js_arg = info.getArg(raw_value, index, func.index_offset) orelse unreachable;
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

    pub fn setThisArg(self: *Func, nat_obj_ptr: anytype) !void {
        self.thisArg = try getV8Object(
            self.nat_ctx,
            nat_obj_ptr,
        ) orelse return error.V8ObjectNotFound;
    }

    pub fn deinit(self: *Func, alloc: std.mem.Allocator) void {

        // cleanup persistent references in v8
        self.js_func_pers.deinit();
        for (self.js_args_pers) |*arg| {
            arg.deinit();
        }

        // free heap
        alloc.free(self.js_args_pers);
    }

    pub fn id(self: Func) usize {
        return self._id.get();
    }

    // call the function with a try catch to catch errors an report in res.
    pub fn trycall(self: Func, nat_args: anytype, res: *Result) anyerror!void {
        // JS try cache
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(self.isolate);
        defer try_catch.deinit();

        self.call(nat_args) catch |e| {
            res.success = false;
            if (try_catch.hasCaught()) {
                // retrieve context
                // NOTE: match the Func.call implementation
                const ctx = self.isolate.getCurrentContext();
                try res.setError(self.isolate, ctx, try_catch);
            }

            return e;
        };

        res.success = true;
    }

    pub fn call(self: Func, nat_args: anytype) anyerror!void {
        // ensure Native args and JS args are not both provided
        const info = @typeInfo(@TypeOf(nat_args));
        if (comptime info != .null) {
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
        if (comptime info == .@"struct") {

            // - Native arguments provided on function call
            std.debug.assert(info.@"struct".is_tuple);
            args = try self.nat_ctx.alloc.alloc(v8.Value, info.@"struct".fields.len);
            comptime var i = 0;
            inline while (i < info.@"struct".fields.len) {
                comptime var ret: refl.Type = undefined;
                comptime {
                    ret = try refl.Type.reflect(info.@"struct".fields[i].type, null);
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

        // Callbacks are typically called with a this value of undefined.
        // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/this#callbacks
        // TODO use undefined this instead of global.
        const this = self.thisArg orelse js_ctx.getGlobal();

        // execute function
        const result = js_func.call(js_ctx, this, args);
        if (result == null) {
            return error.JSExecCallback;
        }
    }
};
