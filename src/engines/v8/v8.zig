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
pub const CallbackResult = @import("callback.zig").Result;

pub const Module = v8.Module;
pub const ModuleLoadFn = *const fn (ctx: *anyopaque, referrer: ?Module, specifier: []const u8) anyerror!Module;

pub const LoadFnType = @import("generate.zig").LoadFnType;
pub const loadFn = @import("generate.zig").loadFn;
const setNativeObject = @import("generate.zig").setNativeObject;
const setNativeType = @import("generate.zig").setNativeType;
const loadFunctionTemplate = @import("generate.zig").loadFunctionTemplate;
const bindObjectNativeAndJS = @import("generate.zig").bindObjectNativeAndJS;
const getTpl = @import("generate.zig").getTpl;

const nativeToJS = @import("types_primitives.zig").nativeToJS;
const valueToUtf8 = @import("types_primitives.zig").valueToUtf8;

const log = std.log.scoped(.v8);

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

    pub fn pumpMessageLoop(self: *const VM, env: *const Env, wait: bool) bool {
        log.debug("pumpMessageLoop", .{});
        return self.platform.pumpMessageLoop(env.isolate, wait);
    }
};

pub const Env = struct {
    nat_ctx: NativeContext,

    isolate: v8.Isolate,
    isolate_params: v8.CreateParams,
    hscope: v8.HandleScope,
    globals: v8.FunctionTemplate,
    inspector: ?Inspector = null,

    js_ctx: ?v8.Context = null,

    moduleLoad: ?struct {
        ctx: *anyopaque,
        func: ModuleLoadFn,
    } = null,

    pub fn engine() public.EngineType {
        return .v8;
    }

    pub fn init(
        self: *Env,
        alloc: std.mem.Allocator,
        loop: *public.Loop,
        userctx: ?public.UserContext,
    ) void {

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
        const globals = v8.FunctionTemplate.initDefault(isolate);

        self.* = Env{
            .nat_ctx = undefined,
            .isolate_params = params,
            .isolate = isolate,
            .hscope = hscope,
            .globals = globals,
        };
        NativeContext.init(&self.nat_ctx, alloc, loop, userctx);
        self.startMicrotasks();
    }

    pub fn deinit(self: *Env) void {
        self.stopMicrotasks();

        // v8 values
        // ---------

        // handle scope
        self.hscope.deinit();

        // isolate
        var isolate = self.isolate;
        isolate.exit();
        isolate.deinit();

        // params
        v8.destroyArrayBufferAllocator(self.isolate_params.array_buffer_allocator.?);

        // native context
        // --------------
        self.nat_ctx.deinit();

        self.* = undefined;
    }

    pub fn setInspector(self: *Env, inspector: Inspector) void {
        self.inspector = inspector;
    }

    pub inline fn getInspector(self: Env) ?Inspector {
        return self.inspector;
    }

    pub fn setUserContext(self: *Env, userctx: public.UserContext) anyerror!void {
        self.nat_ctx.userctx = userctx;
    }

    pub fn runMicrotasks(self: *const Env) void {
        self.isolate.performMicrotasksCheckpoint();
    }

    fn startMicrotasks(self: *Env) void {
        self.runMicrotasks();
        self.nat_ctx.loop.zigTimeout(1 * std.time.ns_per_ms, *Env, self, startMicrotasks);
    }

    fn stopMicrotasks(self: *const Env) void {
        // We force a loop reset for all zig callback.
        // The goal is to stop the callbacks used for the run micro tasks.
        self.nat_ctx.loop.resetZig();
    }

    // load user-defined Types into Javascript environement
    pub fn load(self: *Env, js_types: []usize) anyerror!void {
        var tpls: [gen.Types.len]TPL = undefined;
        try gen.load(&self.nat_ctx, self.isolate, self.globals, TPL, &tpls);
        for (tpls, 0..) |tpl, i| {
            js_types[i] = @intFromPtr(tpl.tpl.handle);
        }
        self.nat_ctx.loadTypes(js_types);
    }

    const envIdx = 1;

    // tov8Ctx saves the current env pointer into the v8 context.
    fn tov8Ctx(self: *Env) void {
        if (self.js_ctx == null) unreachable;
        self.js_ctx.?.getIsolate().setData(envIdx, self);
    }

    // fromv8Ctx extracts the current env pointer into the v8 context.
    fn fromv8Ctx(ctx: v8.Context) *Env {
        const env = ctx.getIsolate().getData(envIdx);
        if (env == null) unreachable;
        return @ptrCast(@alignCast(env));
    }

    // start a Javascript context
    pub fn start(self: *Env) anyerror!void {

        // context
        self.js_ctx = v8.Context.init(self.isolate, self.globals.getInstanceTemplate(), null);
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
                const cstr_tpl = getTpl(&self.nat_ctx, i);
                const proto_tpl = getTpl(&self.nat_ctx, proto_index);
                const cstr_obj = cstr_tpl.getFunction(js_ctx).toObject();
                const proto_obj = proto_tpl.getFunction(js_ctx).toObject();
                _ = cstr_obj.setPrototype(js_ctx, proto_obj);
            }

            // Custom exception
            // NOTE: there is no way in v8 to subclass the Error built-in type
            // TODO: this is an horrible hack
            if (comptime T_refl.isException()) {
                const script = T_refl.name ++ ".prototype.__proto__ = Error.prototype";
                _ = self.exec(script, "errorSubclass") catch {
                    // TODO: is there a reason to override the error?
                    return error.errorSubClass;
                };
            }
        }

        // save the env into the context.
        self.tov8Ctx();
    }

    // stop a Javascript context
    pub fn stop(self: *Env) void {
        if (self.js_ctx == null) {
            return; // no-op
        }

        // JS context
        self.js_ctx.?.exit();
        self.js_ctx = null;

        // Native context
        self.nat_ctx.stop();
    }

    pub fn getGlobal(self: Env) anyerror!Object {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }
        return self.js_ctx.?.getGlobal();
    }

    pub fn bindGlobal(self: *Env, obj: anytype) anyerror!void {
        const T_refl = comptime gen.getType(@TypeOf(obj));
        if (!comptime refl.isGlobalType(T_refl.T)) return error.notGlobalType;
        const T = T_refl.Self();

        // ensure Native object is a pointer
        var nat_obj_ptr: *T = undefined;

        if (comptime refl.isPointer(@TypeOf(obj))) {

            // Native object is a pointer of T
            // no need to create it in heap,
            // we assume it has been done already by the API
            // just assign pointer to Native object
            nat_obj_ptr = obj;
        } else {

            // Native object is a value of T
            // create a pointer in heap
            // (otherwise on the stack it will be delete when the function returns),
            // and assign pointer's dereference value to Native object
            nat_obj_ptr = try self.nat_ctx.alloc.create(T);
            nat_obj_ptr.* = obj;
        }

        _ = try bindObjectNativeAndJS(
            self.nat_ctx.alloc,
            &self.nat_ctx,
            T_refl,
            nat_obj_ptr,
            self.js_ctx.?.getGlobal(),
            self.js_ctx.?,
            self.isolate,
        );
    }

    // add a Native object in the Javascript context
    pub fn addObject(self: *Env, obj: anytype, name: []const u8) anyerror!void {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }
        return createJSObject(
            self.nat_ctx.alloc,
            &self.nat_ctx,
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

    // Currently used for DOM nodes
    // - value Note: *parser.Node should be converted to dom/node.zig.Union to get the most precise type
    pub fn findOrAddValue(env: *Env, value: anytype) !v8.Value {
        if (builtin.is_test) {
            // std.testing.refAllDecls(@import("server.zig")); Causes `try ret.lookup(gen.Types);` to throw an error
            return error.TestingNotSupported;
        }
        comptime var ret: refl.Type = undefined;
        comptime {
            @setEvalBranchQuota(150_000); // Needed when this is called with a dom/node.zig.Union
            ret = try refl.Type.reflect(@TypeOf(value), null);
            try ret.lookup(gen.Types);
        }
        return try setNativeType(
            env.nat_ctx.alloc,
            &env.nat_ctx,
            ret,
            value,
            env.js_ctx.?,
            env.isolate,
        );
    }

    // compile and run a JS script
    // It doesn't wait for callbacks execution
    pub fn exec(
        self: Env,
        script: []const u8,
        name: ?[]const u8,
    ) anyerror!JSValue {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }
        return try jsExec(script, name, self.isolate, self.js_ctx.?);
    }

    pub fn setModuleLoadFn(self: *Env, ctx: *anyopaque, mlfn: ModuleLoadFn) !void {
        self.moduleLoad = .{
            .ctx = ctx,
            .func = mlfn,
        };
    }

    pub fn compileModule(self: Env, src: []const u8, name: []const u8) anyerror!Module {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }

        // compile
        const script_name = v8.String.initUtf8(self.isolate, name);
        const script_source = v8.String.initUtf8(self.isolate, src);

        const origin = v8.ScriptOrigin.init(
            self.isolate,
            script_name.toValue(),
            0, // resource_line_offset
            0, // resource_column_offset
            false, // resource_is_shared_cross_origin
            -1, // script_id
            null, // source_map_url
            false, // resource_is_opaque
            false, // is_wasm
            true, // is_module
            null, // host_defined_options
        );

        var script_comp_source: v8.ScriptCompilerSource = undefined;
        script_comp_source.init(script_source, origin, null);
        defer script_comp_source.deinit();

        return v8.ScriptCompiler.compileModule(
            self.isolate,
            &script_comp_source,
            .kNoCompileOptions,
            .kNoCacheNoReason,
        ) catch return error.JSCompile;
    }

    // compile and eval a JS module
    // It doesn't wait for callbacks execution
    pub fn module(self: Env, src: []const u8, name: []const u8) anyerror!JSValue {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }

        const m = try self.compileModule(src, name);

        // instantiate
        // TODO handle ResolveModuleCallback parameters to load module's
        // dependencies.
        const ok = m.instantiate(self.js_ctx.?, resolveModuleCallback) catch return error.JSExec;
        if (!ok) {
            return error.ModuleInstantiateErr;
        }

        // evaluate
        const value = m.evaluate(self.js_ctx.?) catch return error.JSExec;
        return .{ .value = value };
    }

    pub fn resolveModuleCallback(
        c_ctx: ?*const v8.C_Context,
        specifier: ?*const v8.C_String,
        import_attributes: ?*const v8.C_FixedArray,
        referrer: ?*const v8.C_Module,
    ) callconv(.C) ?*const v8.C_Module {
        _ = import_attributes;

        if (c_ctx == null) unreachable;
        const ctx = v8.Context{ .handle = c_ctx.? };
        const self = Env.fromv8Ctx(ctx);

        const ml = self.moduleLoad orelse unreachable; // if module load is missing, this is a program error.

        // TODO use a fixed allocator?
        const alloc = self.nat_ctx.alloc;

        // build the specifier value.
        const specstr = valueToUtf8(
            alloc,
            v8.Value{ .handle = specifier.? },
            ctx.getIsolate(),
            ctx,
        ) catch |e| {
            log.err("resolveModuleCallback: get ref str: {any}", .{e});
            return null;
        };
        defer alloc.free(specstr);

        const refmod = if (referrer) |ref| v8.Module{ .handle = ref } else null;

        const m = ml.func(ml.ctx, refmod, specstr) catch |e| {
            log.err("resolveModuleCallback: load fn: {any}", .{e});
            return null;
        };
        return m.handle;
    }

    // wait I/O Loop until all JS callbacks are executed
    // This is a blocking operation.
    // Errors can be either:
    // - an error of the Loop (eg. IO kernel)
    // - an error of one of the JS callbacks
    // NOTE: the Loop does not stop when a JS callback throw an error
    // ie. all JS callbacks are executed
    // TODO: return at first error on a JS callback and let the caller
    // decide whether going forward or not
    pub fn wait(self: Env) anyerror!void {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }

        // run loop
        return self.nat_ctx.loop.run();
    }

    // compile and run a JS script and wait for all callbacks (exec + wait)
    // This is a blocking operation.
    pub fn execWait(self: Env, script: []const u8, name: ?[]const u8) anyerror!JSValue {

        // exec script
        const res = try self.exec(script, name);

        // wait
        try self.wait();

        return res;
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
) !void {

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
        } else if (@typeInfo(@TypeOf(value)) == .@"union") {
            // NOTE: inspired by std.meta.TagPayloadByName
            const activeTag = @tagName(std.meta.activeTag(value));
            inline for (std.meta.fields(@TypeOf(value))) |field| {
                if (std.mem.eql(u8, activeTag, field.name)) {
                    return self.set(key, @field(value, field.name));
                }
            }
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

pub const JSValue = struct {
    value: v8.Value,

    // the caller needs to deinit the string returned
    pub fn toString(self: JSValue, alloc: std.mem.Allocator, env: *const Env) anyerror![]const u8 {
        return valueToUtf8(alloc, self.value, env.isolate, env.js_ctx.?);
    }

    pub fn typeOf(self: JSValue, env: Env) anyerror!public.JSTypes {
        var buf: [20]u8 = undefined;
        const str = try self.value.typeOf(env.isolate);
        const len = str.lenUtf8(env.isolate);
        const s = buf[0..len];
        _ = str.writeUtf8(env.isolate, s);
        return std.meta.stringToEnum(public.JSTypes, s) orelse {
            log.err("JSValueTypeNotHandled: {s}", .{s});
            return error.JSValueTypeNotHandled;
        };
    }

    pub fn externalEntry(self: JSValue) ?*ExternalEntry {
        return getExternalEntry(self.value);
    }
};

pub const TryCatch = struct {
    inner: v8.TryCatch,

    pub fn init(self: *TryCatch, env: *const Env) void {
        self.inner.init(env.isolate);
    }

    pub fn hasCaught(self: TryCatch) bool {
        return self.inner.hasCaught();
    }

    // the caller needs to deinit the string returned
    pub fn exception(self: TryCatch, alloc: std.mem.Allocator, env: *const Env) anyerror!?[]const u8 {
        if (env.js_ctx == null) {
            return error.EnvNotStarted;
        }

        if (self.inner.getException()) |msg| {
            return try valueToUtf8(alloc, msg, env.isolate, env.js_ctx.?);
        }
        return null;
    }

    // the caller needs to deinit the string returned
    pub fn stack(self: TryCatch, alloc: std.mem.Allocator, env: *const Env) anyerror!?[]const u8 {
        if (env.js_ctx == null) {
            return error.EnvNotStarted;
        }

        const stck = self.inner.getStackTrace(env.js_ctx.?);
        if (stck) |s| return try valueToUtf8(alloc, s, env.isolate, env.js_ctx.?);
        return null;
    }

    // a shorthand method to return either the entire stack message
    // or just the exception message
    // - in Debug mode return the stack if available
    // - otherwhise return the exception if available
    // the caller needs to deinit the string returned
    pub fn err(self: TryCatch, alloc: std.mem.Allocator, env: *const Env) anyerror!?[]const u8 {
        if (builtin.mode == .Debug) {
            if (try self.stack(alloc, env)) |msg| return msg;
        }
        return try self.exception(alloc, env);
    }

    pub fn deinit(self: *TryCatch) void {
        self.inner.deinit();
    }
};

pub fn jsExec(script: []const u8, name: ?[]const u8, isolate: v8.Isolate, js_ctx: v8.Context) !JSValue {

    // compile
    var origin: ?v8.ScriptOrigin = undefined;
    if (name) |n| {
        const scr_name = v8.String.initUtf8(isolate, n);
        origin = v8.ScriptOrigin.initDefault(isolate, scr_name.toValue());
    }
    const scr_js = v8.String.initUtf8(isolate, script);
    const scr = v8.Script.compile(js_ctx, scr_js, origin) catch return error.JSCompile;

    // run
    const value = scr.run(js_ctx) catch return error.JSExec;
    return .{ .value = value };
}

// Inspector

pub const Inspector = struct {
    inner: *v8.Inspector,
    session: v8.InspectorSession,

    pub fn init(
        alloc: std.mem.Allocator,
        env: *const Env,
        ctx: *anyopaque,
        onResp: public.InspectorOnResponseFn,
        onEvent: public.InspectorOnEventFn,
    ) anyerror!Inspector {
        const inner = try alloc.create(v8.Inspector);
        const channel = v8.InspectorChannel.init(ctx, onResp, onEvent, env.isolate);
        const client = v8.InspectorClient.init();
        v8.Inspector.init(inner, client, channel, env.isolate);
        const session = inner.connect();
        return .{ .inner = inner, .session = session };
    }

    pub fn deinit(self: Inspector, alloc: std.mem.Allocator) void {
        self.inner.deinit();
        alloc.destroy(self.inner);
    }

    // From CDP docs
    // https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#type-ExecutionContextDescription
    // ----
    // - name: Human readable name describing given context.
    // - origin: Execution context origin (ie. URL who initialised the request)
    // - auxData: Embedder-specific auxiliary data likely matching
    // {isDefault: boolean, type: 'default'|'isolated'|'worker', frameId: string}
    pub fn contextCreated(
        self: Inspector,
        env: *const Env,
        name: []const u8,
        origin: []const u8,
        auxData: ?[]const u8,
    ) void {
        self.inner.contextCreated(env.js_ctx.?, name, origin, auxData);
    }

    // msg should be formatted for the Inspector protocol
    // for v8 it's the CDP protocol https://chromedevtools.github.io/devtools-protocol/
    // with only some domains being relevant (mainly Runtime and Debugger)
    pub fn send(self: Inspector, env: Env, msg: []const u8) void {
        return self.session.dispatchProtocolMessage(env.isolate, msg);
    }

    // Retrieves the RemoteObject for a given JsValue. We may extend the interface here to include:
    // backendNodeId, objectGroup, executionContextId. For a complete resolveNode implementation at this level.
    pub fn getRemoteObject(self: Inspector, env: *Env, jsValue: v8.Value, groupName: []const u8) !v8.RemoteObject {
        const generatePreview = false; // We do not want to expose this as a parameter for now
        return self.session.wrapObject(env.isolate, env.js_ctx.?, jsValue, groupName, generatePreview);
    }

    pub fn getValueByObjectId(self: Inspector, allocator: std.mem.Allocator, objectId: []const u8) !JSValue {
        const result = try self.session.unwrapObject(allocator, objectId);
        const unwrapped = switch (result) {
            .err => |err| {
                log.err("Unable to unwrap object {s}: {s}", .{ objectId, if (err) |e| e else "No error message" });
                return error.UnwrapObjectFailed;
            },
            .ok => |value| value,
        };
        return .{ .value = unwrapped.value }; // The values context and groupId are not used here
    }
};

// When we return a Zig instance to V8, we wrap it in a v8.Object. That wrapping
// happens by:
//  - Assigning our instance to a v8.External (which just holds an *anyopaque)
//  - Creating a v8.PersistentObject and assigning the external to the
//    PersistentObject's internalField #0
//  - Casting the v8.PersistentObject to a v8.Object
//
// Now, instead of assigning the instance directly into the v8.External we
// allocate and assign this ExternalEntry, which allows us to hold the ptr to
// the Zig instance, as well as meta data that we'll need.
pub const ExternalEntry = struct {
    // Ptr to the Zig instance
    ptr: *anyopaque,

    // When we're asked to describe an object via the Inspector, we _must_ include
    // the proper subtype (and description) fields in the returned JSON.
    // V8 will give us a Value and ask us for the subtype. Hence, we store it
    // here.
    sub_type: ?[*c]const u8,
};

// See above for documentation for the ExternalEntry's sub_type field.
pub export fn v8_inspector__Client__IMPL__valueSubtype(
    _: *v8.c.InspectorClientImpl,
    c_value: *const v8.C_Value,
) callconv(.C) [*c]const u8 {
    const external_entry = getExternalEntry(.{ .handle = c_value }) orelse return null;
    return if (external_entry.sub_type) |st| st else null;
}

pub export fn v8_inspector__Client__IMPL__descriptionForValueSubtype(
    _: *v8.c.InspectorClientImpl,
    context: *const v8.C_Context,
    c_value: *const v8.C_Value,
) callconv(.C) [*c]const u8 {
    _ = context;

    // We _must_ include a non-null description in order for the subtype value
    // to be included. Besides that, I don't know if the value has any meaning
    const external_entry = getExternalEntry(.{ .handle = c_value }) orelse return null;
    return if (external_entry.sub_type == null) null else "";
}

fn getExternalEntry(value: v8.Value) ?*ExternalEntry {
    if (value.isObject() == false) {
        return null;
    }
    const obj = value.castTo(Object);
    if (obj.internalFieldCount() == 0) {
        return null;
    }

    const external_data = obj.getInternalField(0).castTo(v8.External).get().?;
    return @alignCast(@ptrCast(external_data));
}
