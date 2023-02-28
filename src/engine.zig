const std = @import("std");
const builtin = @import("builtin");

const v8 = @import("v8");

const utils = @import("utils.zig");
const Loop = @import("loop.zig").SingleThreaded;
const refs = @import("refs.zig");
const gen = @import("generate.zig");
const refl = @import("reflect.zig");

// Better use public API as input parameters
const public = @import("jsruntime.zig");
const API = public.API;
const TPL = public.TPL;

pub const ContextExecFn = (fn (std.mem.Allocator, *Env, comptime []API) anyerror!void);

pub fn loadEnv(
    arena_alloc: *std.heap.ArenaAllocator,
    comptime ctxExecFn: ContextExecFn,
    comptime apis: []API,
) !void {
    const alloc = arena_alloc.allocator();

    // create JS env
    var start: std.time.Instant = undefined;
    if (builtin.is_test) {
        start = try std.time.Instant.now();
    }
    var loop = try Loop.init(alloc);
    defer loop.deinit();
    var js_env = try Env.init(arena_alloc, &loop);
    defer js_env.deinit();

    // load APIs in JS env
    var load_start: std.time.Instant = undefined;
    if (builtin.is_test) {
        load_start = try std.time.Instant.now();
    }
    var tpls: [apis.len]TPL = undefined;
    try js_env.load(apis, &tpls);

    // execute JS function
    var exec_start: std.time.Instant = undefined;
    if (builtin.is_test) {
        exec_start = try std.time.Instant.now();
    }
    try ctxExecFn(alloc, &js_env, apis);

    // Stats
    // -----

    var exec_end: std.time.Instant = undefined;
    if (builtin.is_test) {
        exec_end = try std.time.Instant.now();
    }

    if (builtin.is_test) {
        const us = std.time.ns_per_us;

        const create_time = std.time.Instant.since(load_start, start);
        const load_time = std.time.Instant.since(exec_start, load_start);
        const exec_time = std.time.Instant.since(exec_end, exec_start);
        const total_time = std.time.Instant.since(exec_end, start);

        const create_per = create_time * 100 / total_time;
        const load_per = load_time * 100 / total_time;
        const exec_per = exec_time * 100 / total_time;

        std.debug.print("\ncreation of env:\t{d}us\t{d}%\n", .{ create_time / us, create_per });
        std.debug.print("load of apis:\t\t{d}us\t{d}%\n", .{ load_time / us, load_per });
        std.debug.print("exec:\t\t\t{d}us\t{d}%\n", .{ exec_time / us, exec_per });
        std.debug.print("Total:\t\t\t{d}us\n", .{total_time / us});
    }
}

pub const VM = struct {
    platform: v8.Platform,

    pub fn init() VM {
        var platform = v8.Platform.initDefault(0, true);
        v8.initV8Platform(platform);
        v8.initV8();
        return .{
            .platform = platform,
        };
    }

    pub fn deinit(self: VM) void {
        _ = v8.deinitV8();
        v8.deinitV8Platform();
        self.platform.deinit();
    }
};

pub const Env = struct {
    loop: *Loop,

    isolate: v8.Isolate,
    isolate_params: v8.CreateParams,
    hscope: v8.HandleScope,
    globals: v8.ObjectTemplate,

    context: ?v8.Context = null,

    pub fn init(arena_alloc: *std.heap.ArenaAllocator, loop: *Loop) !Env {

        // globals values
        // --------------

        // allocator
        utils.allocator = arena_alloc.allocator();

        // refs
        refs.map = refs.Map{};

        // I/O loop
        utils.loop = loop;

        // v8 values
        // ---------

        // params
        var params = v8.initCreateParams();
        params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();

        // isolate
        var isolate = v8.Isolate.init(&params);
        isolate.enter();

        // handle scope
        var hscope: v8.HandleScope = undefined;
        hscope.init(isolate);

        // ObjectTemplate for the global namespace
        const globals = v8.ObjectTemplate.initDefault(isolate);

        return .{
            .loop = loop,
            .isolate_params = params,
            .isolate = isolate,
            .hscope = hscope,
            .globals = globals,
        };
    }

    pub fn deinit(self: *Env) void {

        // v8 values
        // ---------

        // handle scope
        var hscope = self.hscope;
        hscope.deinit();

        // isolate
        var isolate = self.isolate;
        isolate.exit();
        isolate.deinit();

        // params
        v8.destroyArrayBufferAllocator(self.isolate_params.array_buffer_allocator.?);

        // globals values
        // --------------

        // unset globals
        refs.map = undefined;
        utils.loop = undefined;
        utils.allocator = undefined;

        self.* = undefined;
    }

    // load APIs into Javascript environement
    pub fn load(self: Env, comptime apis: []API, tpls: []TPL) !void {
        try gen.load(self.isolate, self.globals, apis, tpls);
    }

    // start a Javascript context
    pub fn start(self: *Env) void {

        // context
        self.context = v8.Context.init(self.isolate, self.globals, null);
        self.context.?.enter();
    }

    // stop a Javascript context
    pub fn stop(self: *Env) void {
        if (self.context == null) {
            return; // no-op
        }

        // context
        self.context.?.exit();
        self.context = undefined;
    }

    // add a Native object in the Javascript context
    pub fn addObject(self: Env, comptime apis: []API, obj: anytype, name: []const u8) !void {
        if (self.context == null) {
            return error.EnvNotStarted;
        }
        return createJSObject(
            apis,
            obj,
            name,
            self.context.?.getGlobal(),
            self.context.?,
            self.isolate,
        );
    }

    // compile and run a Javascript script
    // if no error you need to call deinit on the returned result
    pub fn exec(
        self: Env,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: ?[]const u8,
        try_catch: v8.TryCatch,
    ) !JSResult {
        if (self.context == null) {
            return error.EnvNotStarted;
        }

        var res = JSResult.init();
        try res.exec(alloc, script, name, self.isolate, self.context.?, try_catch);
        return res;
    }

    // compile and run a Javascript script with try/catch
    // if no error you need to call deinit on the returned result
    pub fn execTryCatch(
        self: Env,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: ?[]const u8,
    ) !JSResult {

        // JS try cache
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(self.isolate);
        defer try_catch.deinit();

        return self.exec(alloc, script, name, try_catch);
    }

    // wait I/O loop until all JS callbacks are executed
    // This is a blocking operation.
    pub fn wait(
        self: Env,
        alloc: std.mem.Allocator,
        try_catch: v8.TryCatch,
        cbk_res: ?*JSResult,
    ) !void {
        if (self.context == null) {
            return error.EnvNotStarted;
        }

        // run loop
        utils.loop.run() catch |err| {
            if (try_catch.hasCaught()) {
                if (cbk_res) |res| {
                    res.success = false;
                    return res.setError(alloc, self.isolate, self.context.?, try_catch);
                }
                // otherwise ignore JS errors
            } else {
                // IO kernel error
                return err;
            }
        };
    }

    // run a JS script and wait for all callbacks
    // try_catch + exec + wait
    pub fn run(
        self: Env,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: ?[]const u8,
        res: *JSResult,
        cbk_res: ?*JSResult,
    ) !void {
        if (self.context == null) {
            return error.EnvNotStarted;
        }

        // JS try cache
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(self.isolate);
        defer try_catch.deinit();

        // exec script
        try res.exec(alloc, script, name, self.isolate, self.context.?, try_catch);

        // run loop
        utils.loop.run() catch |err| {
            if (try_catch.hasCaught()) {
                if (cbk_res) |r| {
                    r.success = false;
                    return r.setError(alloc, self.isolate, self.context.?, try_catch);
                }
                // otherwise ignore JS errors
            } else {
                // IO kernel error
                return err;
            }
        };
    }
};

fn createJSObject(
    comptime apis: []API,
    obj: anytype,
    name: []const u8,
    target: v8.Object,
    ctx: v8.Context,
    isolate: v8.Isolate,
) !void {

    // retrieve obj tpl
    comptime var obj_api_index: comptime_int = undefined;
    comptime {
        inline for (apis) |api| {
            if (@TypeOf(obj) == api.T_refl.T or @TypeOf(obj) == *api.T_refl.T) {
                obj_api_index = api.T_refl.index;
            }
        }
    }
    const T_refl = apis[obj_api_index].T_refl;
    const tpl = gen.getTpl(obj_api_index).tpl;

    // instantiate JS object
    const instance_tpl = tpl.getInstanceTemplate();
    const js_obj = instance_tpl.initInstance(ctx);
    const key = v8.String.initUtf8(isolate, name);
    if (!target.setValue(ctx, key, js_obj)) {
        return error.CreateV8Object;
    }

    // bind Native and JS objects together
    try gen.setNativeObject(
        utils.allocator,
        T_refl,
        obj,
        js_obj,
        isolate,
    );
}

pub const JSResult = struct {
    success: bool = false,
    result: []const u8 = undefined,
    stack: ?[]const u8 = null,

    pub fn init() JSResult {
        return .{};
    }

    pub fn deinit(self: JSResult, alloc: std.mem.Allocator) void {
        alloc.free(self.result);
        if (self.stack) |stack| {
            alloc.free(stack);
        }
    }

    pub fn exec(
        self: *JSResult,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: ?[]const u8,
        isolate: v8.Isolate,
        context: v8.Context,
        try_catch: v8.TryCatch,
    ) !void {

        // compile
        var origin: ?v8.ScriptOrigin = undefined;
        if (name) |n| {
            const scr_name = v8.String.initUtf8(isolate, n);
            origin = v8.ScriptOrigin.initDefault(isolate, scr_name.toValue());
        }
        const scr_js = v8.String.initUtf8(isolate, script);
        const scr = v8.Script.compile(context, scr_js, origin) catch {
            return self.setError(alloc, isolate, context, try_catch);
        };

        // run
        const res = scr.run(context) catch {
            return self.setError(alloc, isolate, context, try_catch);
        };
        self.success = true;
        self.result = try utils.valueToUtf8(alloc, res, isolate, context);
    }

    pub fn setError(
        self: *JSResult,
        alloc: std.mem.Allocator,
        isolate: v8.Isolate,
        context: v8.Context,
        try_catch: v8.TryCatch,
    ) !void {

        // exception
        const except = try_catch.getException().?;
        self.result = try utils.valueToUtf8(alloc, except, isolate, context);

        // stack
        if (self.stack == null) {
            return;
        }
        const stack = try_catch.getStackTrace(context).?;
        self.stack = try utils.valueToUtf8(alloc, stack, isolate, context);
    }
};
