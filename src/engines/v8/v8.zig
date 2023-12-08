const std = @import("std");

const v8 = @import("v8");

const internal = @import("../../internal_api.zig");
const refs = internal.refs;
const refl = internal.refl;
const gen = internal.gen;
const utils = internal.utils;

const public = @import("../../api.zig");
const Loop = public.Loop;

pub const Callback = @import("callback.zig").Func;
pub const CallbackSync = @import("callback.zig").FuncSync;
pub const CallbackArg = @import("callback.zig").Arg;

pub const LoadFnType = @import("generate.zig").LoadFnType;
pub const loadFn = @import("generate.zig").loadFn;
const setNativeObject = @import("generate.zig").setNativeObject;
const nativeToJS = @import("types_primitives.zig").nativeToJS;
const valueToUtf8 = @import("types_primitives.zig").valueToUtf8;

pub const API = struct {
    T_refl: refl.Struct,
    load: LoadFnType,

    pub inline fn nativeT(comptime self: API) refl.Struct {
        return self.T_refl;
    }

    pub inline fn loadFn(comptime self: API) LoadFnType {
        return self.load;
    }
};

pub const TemplateType = v8.FunctionTemplate;

pub const TPL = struct {
    tpl: v8.FunctionTemplate,
    index: usize,

    pub inline fn template(self: TPL) v8.FunctionTemplate {
        return self.tpl;
    }

    pub inline fn idx(self: TPL) usize {
        return self.index;
    }
};

pub const Object = v8.Object;

pub const VM = struct {
    platform: v8.Platform,

    pub fn init() VM {
        const platform = v8.Platform.initDefault(0, true);
        v8.initV8Platform(platform);
        v8.initV8();
        return .{ .platform = platform };
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

    pub fn engine() public.engineType {
        return .v8;
    }

    pub fn init(arena_alloc: *std.heap.ArenaAllocator, loop: *Loop) anyerror!Env {

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

        return Env{
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
    pub fn load(self: Env, comptime apis: []API, tpls: []TPL) anyerror!void {
        try gen.load(self.isolate, self.globals, apis, tpls);
    }

    // start a Javascript context
    pub fn start(self: *Env, alloc: std.mem.Allocator, comptime apis: []API) anyerror!void {

        // context
        self.context = v8.Context.init(self.isolate, self.globals, null);
        const ctx = self.context.?;
        ctx.enter();

        // TODO: ideally all this should disapear,
        // we shouldn't do anything at context startup time
        inline for (apis, 0..) |api, i| {

            // APIs prototype
            // set the prototype of each corresponding constructor Function
            // NOTE: this is required to inherit attributes at the Type level,
            // ie. static class attributes.
            // For static instance attributes we set them
            // on FunctionTemplate.PrototypeTemplate
            // TODO: is there a better way to do it at the Template level?
            // see https://github.com/Browsercore/jsruntime-lib/issues/128
            if (api.T_refl.proto_index) |proto_index| {
                const cstr_tpl = gen.getTpl(i).tpl;
                const proto_tpl = gen.getTpl(proto_index).tpl;
                const cstr_obj = cstr_tpl.getFunction(ctx).toObject();
                const proto_obj = proto_tpl.getFunction(ctx).toObject();
                _ = cstr_obj.setPrototype(ctx, proto_obj);
            }

            // Custom exception
            // NOTE: there is no way in v8 to subclass the Error built-in type
            // TODO: this is an horrible hack
            if (comptime api.T_refl.isException()) {
                const script = api.T_refl.name ++ ".prototype.__proto__ = Error.prototype";
                const res = try self.execTryCatch(
                    alloc,
                    script,
                    "errorSubclass",
                );
                defer res.deinit(alloc);
                if (!res.success) return error.errorSubClass;
            }
        }
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
    pub fn getGlobal(self: Env) anyerror!Object {
        if (self.context == null) {
            return error.EnvNotStarted;
        }
        return self.context.?.getGlobal();
    }

    // add a Native object in the Javascript context
    pub fn addObject(self: Env, comptime apis: []API, obj: anytype, name: []const u8) anyerror!void {
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

    pub fn attachObject(self: Env, obj: Object, name: []const u8, to_obj: ?Object) anyerror!void {
        if (self.context == null) {
            return error.EnvNotStarted;
        }
        const key = v8.String.initUtf8(self.isolate, name);
        // attach to globals if to_obj is not specified
        const to = to_obj orelse try self.getGlobal();
        const res = to.setValue(self.context.?, key, obj);
        if (!res) {
            return error.AttachObject;
        }
    }

    // compile and run a Javascript script
    // if no error you need to call deinit on the returned result
    pub fn exec(
        self: Env,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: ?[]const u8,
        try_catch: TryCatch,
    ) !JSResult {
        if (self.context == null) {
            return error.EnvNotStarted;
        }

        var res = JSResult.init();
        try res.exec(alloc, script, name, self.isolate, self.context.?, try_catch.try_catch.*);
        return res;
    }

    // compile and run a Javascript script with try/catch
    // if no error you need to call deinit on the returned result
    pub fn execTryCatch(
        self: Env,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: ?[]const u8,
    ) anyerror!JSResult {

        // JS try cache
        var try_catch = TryCatch.init(self);
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
    ) anyerror!void {
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

    // retrieve obj API and template
    comptime var obj_api_index: comptime_int = undefined;
    comptime {
        const obj_T = @TypeOf(obj);
        inline for (apis) |api| {
            if (obj_T == api.T_refl.Self() or obj_T == *api.T_refl.Self()) {
                obj_api_index = api.T_refl.index;
                break;
            }
        } else {
            @compileError("addOject type is not in apis");
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
    _ = try setNativeObject(
        utils.allocator,
        T_refl,
        T_refl.value.underT(),
        obj,
        js_obj,
        isolate,
    );
}

pub const JSObject = struct {
    ctx: v8.Context,
    js_obj: v8.Object,

    pub fn set(self: JSObject, key: []const u8, value: anytype) !void {
        const isolate = self.ctx.getIsolate();
        const js_value = try nativeToJS(@TypeOf(value), value, isolate);
        const js_key = v8.String.initUtf8(isolate, key);
        if (!self.js_obj.setValue(self.ctx, js_key, js_value)) {
            return error.SetV8Object;
        }
    }
};

pub const TryCatch = struct {
    try_catch: *v8.TryCatch,

    pub inline fn init(env: Env) TryCatch {
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(env.isolate);
        return .{ .try_catch = &try_catch };
    }

    pub inline fn exception(self: TryCatch, alloc: std.mem.Allocator, env: Env) anyerror!?[]const u8 {
        if (self.try_catch.getException()) |msg| {
            return try valueToUtf8(alloc, msg, env.isolate, env.context.?);
        }
        return null;
    }

    pub inline fn deinit(self: *TryCatch) void {
        self.try_catch.deinit();
    }
};

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
        self.result = try valueToUtf8(alloc, res, isolate, context);
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
        self.success = false;
        self.result = try valueToUtf8(alloc, except, isolate, context);

        // stack
        if (self.stack != null) {
            return;
        }
        if (try_catch.getStackTrace(context)) |stack| {
            self.stack = try valueToUtf8(alloc, stack, isolate, context);
        }
    }
};
