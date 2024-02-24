const std = @import("std");
const builtin = @import("builtin");

const v8 = @import("v8");

const internal = @import("../../internal_api.zig");
const refs = internal.refs;
const refl = internal.refl;
const gen = internal.gen;
const NativeContext = internal.NativeContext;

const public = @import("../../api.zig");

pub const Callback = @import("callback.zig").Func;
pub const CallbackSync = @import("callback.zig").FuncSync;
pub const CallbackArg = @import("callback.zig").Arg;

pub const LoadFnType = @import("generate.zig").LoadFnType;
pub const loadFn = @import("generate.zig").loadFn;
const setNativeObject = @import("generate.zig").setNativeObject;
const loadObjectTemplate = @import("generate.zig").loadObjectTemplate;
const getTpl = @import("generate.zig").getTpl;

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
    nat_ctx: *NativeContext,

    isolate: v8.Isolate,
    isolate_params: v8.CreateParams,
    hscope: v8.HandleScope,
    globals: v8.ObjectTemplate,

    js_ctx: ?v8.Context = null,

    pub fn engine() public.engineType {
        return .v8;
    }

    pub fn init(alloc: std.mem.Allocator, loop: *public.Loop) anyerror!Env {

        // globals values
        // --------------

        // refs
        refs.map = refs.Map{};

        // native context
        // --------------

        const objects_ptr = try alloc.create(NativeContext.Objects);
        objects_ptr.* = NativeContext.Objects{};
        const nat_ctx = try alloc.create(NativeContext);
        nat_ctx.* = .{
            .alloc = alloc,
            .loop = loop,
            .objects = objects_ptr,
        };

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
            .nat_ctx = nat_ctx,
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

        // native context
        // --------------
        self.nat_ctx.objects.deinit(self.nat_ctx.alloc);
        self.nat_ctx.alloc.destroy(self.nat_ctx.objects);
        self.nat_ctx.alloc.destroy(self.nat_ctx);

        // globals values
        // --------------

        // unset globals
        refs.map = undefined;

        self.* = undefined;
    }

    // load user-defined Types into Javascript environement
    pub fn load(self: Env, js_types: []usize) anyerror!void {
        var tpls: [gen.Types.len]TPL = undefined;
        try gen.load(self.nat_ctx, self.isolate, self.globals, TPL, &tpls);
        for (tpls, 0..) |tpl, i| {
            js_types[i] = @intFromPtr(tpl.tpl.handle);
        }
        self.nat_ctx.loadTypes(js_types);
    }

    pub fn loadGlobalT(self: Env, comptime T: type) anyerror!void {
        const T_refl = comptime gen.getType(T);
        self.globals.setInternalFieldCount(1);
        loadObjectTemplate(T_refl, self.globals, self.nat_ctx, self.isolate);
    }

    // start a Javascript context
    pub fn start(self: *Env, alloc: std.mem.Allocator) anyerror!void {

        // context
        self.js_ctx = v8.Context.init(self.isolate, self.globals, null);
        const js_ctx = self.js_ctx.?;
        js_ctx.enter();

        // TODO: ideally all this should disapear,
        // we shouldn't do anything at context startup time
        inline for (gen.Types, 0..) |T_refl, i| {

            // APIs prototype
            // set the prototype of each corresponding constructor Function
            // NOTE: this is required to inherit attributes at the Type level,
            // ie. static class attributes.
            // For static instance attributes we set them
            // on FunctionTemplate.PrototypeTemplate
            // TODO: is there a better way to do it at the Template level?
            // see https://github.com/Browsercore/jsruntime-lib/issues/128
            if (T_refl.proto_index) |proto_index| {
                const cstr_tpl = getTpl(self.nat_ctx, i);
                const proto_tpl = getTpl(self.nat_ctx, proto_index);
                const cstr_obj = cstr_tpl.getFunction(js_ctx).toObject();
                const proto_obj = proto_tpl.getFunction(js_ctx).toObject();
                _ = cstr_obj.setPrototype(js_ctx, proto_obj);
            }

            // Custom exception
            // NOTE: there is no way in v8 to subclass the Error built-in type
            // TODO: this is an horrible hack
            if (comptime T_refl.isException()) {
                const script = T_refl.name ++ ".prototype.__proto__ = Error.prototype";
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
        if (self.js_ctx == null) {
            return; // no-op
        }

        // context
        self.js_ctx.?.exit();
        self.js_ctx = undefined;
    }
    pub fn getGlobal(self: Env) anyerror!Object {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }
        return self.js_ctx.?.getGlobal();
    }

    // add a Native object in the Javascript context
    pub fn addObject(self: Env, obj: anytype, name: []const u8) anyerror!Object {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }
        return createJSObject(
            self.nat_ctx.alloc,
            self.nat_ctx,
            obj,
            name,
            self.js_ctx.?.getGlobal(),
            self.js_ctx.?,
            self.isolate,
        );
    }

    pub fn attachObject(self: Env, obj: Object, name: []const u8, to_obj: ?Object) anyerror!void {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }
        const key = v8.String.initUtf8(self.isolate, name);
        // attach to globals if to_obj is not specified
        const to = to_obj orelse try self.getGlobal();
        const res = to.setValue(self.js_ctx.?, key, obj);
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
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }

        var res = JSResult.init();
        try res.exec(alloc, script, name, self.isolate, self.js_ctx.?, try_catch.try_catch.*);
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
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }

        // run loop
        self.nat_ctx.loop.run() catch |err| {
            if (try_catch.hasCaught()) {
                if (cbk_res) |res| {
                    res.success = false;
                    return res.setError(alloc, self.isolate, self.js_ctx.?, try_catch);
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
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }

        // JS try cache
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(self.isolate);
        defer try_catch.deinit();

        // exec script
        try res.exec(alloc, script, name, self.isolate, self.js_ctx.?, try_catch);

        // run loop
        self.nat_ctx.loop.run() catch |err| {
            if (try_catch.hasCaught()) {
                if (cbk_res) |r| {
                    r.success = false;
                    return r.setError(alloc, self.isolate, self.js_ctx.?, try_catch);
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
    alloc: std.mem.Allocator,
    nat_ctx: *NativeContext,
    obj: anytype,
    name: []const u8,
    target: v8.Object,
    js_ctx: v8.Context,
    isolate: v8.Isolate,
) !v8.Object {

    // retrieve obj API
    const T_refl = comptime gen.getType(@TypeOf(obj));

    // bind Native and JS objects together
    const js_obj = try setNativeObject(
        alloc,
        nat_ctx,
        T_refl,
        T_refl.value.underT(),
        obj,
        null,
        isolate,
        js_ctx,
    );

    // set JS object on target's key
    const key = v8.String.initUtf8(isolate, name);
    if (!target.setValue(js_ctx, key, js_obj)) {
        return error.CreateV8Object;
    }

    return js_obj;
}

pub const JSObjectID = struct {
    id: usize,

    pub fn set(obj: v8.Object) JSObjectID {
        return .{ .id = obj.getIdentityHash() };
    }

    pub fn get(self: JSObjectID) usize {
        return self.id;
    }
};

pub const JSObject = struct {
    nat_ctx: *NativeContext,
    js_ctx: v8.Context,
    js_obj: v8.Object,

    pub fn set(self: JSObject, key: []const u8, value: anytype) !void {
        const isolate = self.js_ctx.getIsolate();
        // const js_value = try nativeToJS(@TypeOf(value), value, isolate);
        var js_value: v8.Value = undefined;
        if (comptime refl.isBuiltinType(@TypeOf(value))) {
            js_value = try nativeToJS(@TypeOf(value), value, isolate);
        } else {
            const T_refl = comptime gen.getType(@TypeOf(value));
            const js_obj = try setNativeObject(
                self.nat_ctx.alloc,
                self.nat_ctx,
                T_refl,
                T_refl.Self(),
                value,
                null,
                isolate,
                self.js_ctx,
            );
            js_value = js_obj.toValue();
        }
        const js_key = v8.String.initUtf8(isolate, key);
        if (!self.js_obj.setValue(self.js_ctx, js_key, js_value)) {
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
            return try valueToUtf8(alloc, msg, env.isolate, env.js_ctx.?);
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
        js_ctx: v8.Context,
        try_catch: v8.TryCatch,
    ) !void {

        // compile
        var origin: ?v8.ScriptOrigin = undefined;
        if (name) |n| {
            const scr_name = v8.String.initUtf8(isolate, n);
            origin = v8.ScriptOrigin.initDefault(isolate, scr_name.toValue());
        }
        const scr_js = v8.String.initUtf8(isolate, script);
        const scr = v8.Script.compile(js_ctx, scr_js, origin) catch {
            return self.setError(alloc, isolate, js_ctx, try_catch);
        };

        // run
        const res = scr.run(js_ctx) catch {
            return self.setError(alloc, isolate, js_ctx, try_catch);
        };
        self.success = true;
        self.result = try valueToUtf8(alloc, res, isolate, js_ctx);
    }

    pub fn setError(
        self: *JSResult,
        alloc: std.mem.Allocator,
        isolate: v8.Isolate,
        js_ctx: v8.Context,
        try_catch: v8.TryCatch,
    ) !void {

        // exception
        const except = try_catch.getException().?;
        self.success = false;
        self.result = try valueToUtf8(alloc, except, isolate, js_ctx);

        // stack
        if (self.stack != null) {
            return;
        }
        if (try_catch.getStackTrace(js_ctx)) |stack| {
            self.stack = try valueToUtf8(alloc, stack, isolate, js_ctx);
        }
    }
};
