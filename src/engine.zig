const std = @import("std");
const builtin = @import("builtin");

const v8 = @import("v8");

const utils = @import("utils.zig");
const Loop = @import("loop.zig").SingleThreaded;
const refs = @import("refs.zig");
const Store = @import("store.zig");
const gen = @import("generate.zig");
const refl = @import("reflect.zig");

// Better use public API as input parameters
const public = @import("jsruntime.zig");
const API = public.API;
const TPL = public.TPL;

pub const ContextExecFn = (fn (std.mem.Allocator, *Env, comptime []API) anyerror!void);

pub fn loadEnv(
    alloc: std.mem.Allocator,
    comptime alloc_auto_free: bool,
    comptime ctxExecFn: ContextExecFn,
    comptime apis: []API,
) !void {

    // create JS env
    var start: std.time.Instant = undefined;
    if (builtin.is_test) {
        start = try std.time.Instant.now();
    }
    var loop = try Loop.init(alloc);
    defer loop.deinit();
    var js_env = try Env.init(alloc, alloc_auto_free, &loop);
    defer js_env.deinit(alloc);

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
    alloc_auto_free: bool,
    loop: *Loop,

    isolate: v8.Isolate,
    isolate_params: v8.CreateParams,
    hscope: v8.HandleScope,
    globals: v8.ObjectTemplate,

    context: ?v8.Context = null,

    pub fn init(
        alloc: std.mem.Allocator,
        comptime alloc_auto_free: bool,
        loop: *Loop,
    ) !Env {

        // globals values
        // --------------

        // allocator
        utils.allocator = alloc;

        // refs
        refs.map = refs.Map{};

        // I/O loop
        utils.loop = loop;

        // store
        if (!alloc_auto_free) {
            Store.default = Store.init(utils.allocator);
        }

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
            .alloc_auto_free = alloc_auto_free,
            .isolate_params = params,
            .isolate = isolate,
            .hscope = hscope,
            .globals = globals,
        };
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

    // compile and run a Javascript script
    // if no error you need to call deinit on the returned result
    pub fn exec(
        self: Env,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: []const u8,
        try_catch: v8.TryCatch,
    ) !utils.ExecuteResult {
        if (self.context == null) {
            return error.EnvNotStarted;
        }

        return jsExecScript(alloc, self.isolate, self.context.?, script, name, try_catch);
    }

    // compile and run a Javascript script with try/catch
    // if no error you need to call deinit on the returned result
    pub fn execTryCatch(
        self: Env,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: []const u8,
    ) utils.ExecuteResult {
        if (self.context == null) {
            return error.EnvNotStarted;
        }

        // JS try cache
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(self.isolate);
        defer try_catch.deinit();

        return jsExecScript(alloc, self.isolate, self.context.?, script, name, try_catch);
    }

    // add a Native object in the Javascript context
    pub fn addObject(self: Env, comptime apis: []API, obj: anytype) !void {
        if (self.context == null) {
            return error.EnvNotStarted;
        }
        return createJSObject(apis, obj, self.context.?.getGlobal(), self.context.?, self.isolate);
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

    pub fn deinit(self: *Env, alloc: std.mem.Allocator) void {

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

        // store
        if (!self.alloc_auto_free) {
            Store.default.?.deinit(alloc);
            Store.default = undefined;
        }

        // refs
        refs.map.deinit(alloc);
        refs.map = undefined;

        // I/O
        utils.loop = undefined;

        // allocator
        utils.allocator = undefined;

        self.* = undefined;
    }
};

// Execute Javascript script
// if no error you need to call deinit on the returned result
pub fn jsExecScript(
    alloc: std.mem.Allocator,
    isolate: v8.Isolate,
    context: v8.Context,
    script: []const u8,
    name: []const u8,
    try_catch: v8.TryCatch,
) utils.ExecuteResult {
    var res: utils.ExecuteResult = undefined;
    const origin = v8.String.initUtf8(isolate, name);
    utils.executeString(alloc, isolate, context, script, origin, &res, try_catch);
    return res;
}

fn createJSObject(
    comptime apis: []API,
    obj: anytype,
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
    const key = v8.String.initUtf8(isolate, T_refl.js_name);
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
