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

pub const LoadFnType = @import("generate.zig").LoadFnType;
pub const loadFn = @import("generate.zig").loadFn;
const setNativeObject = @import("generate.zig").setNativeObject;
const loadFunctionTemplate = @import("generate.zig").loadFunctionTemplate;
const bindObjectNativeAndJS = @import("generate.zig").bindObjectNativeAndJS;
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
    globals: v8.FunctionTemplate,

    js_ctx: ?v8.Context = null,

    pub fn engine() public.engineType {
        return .v8;
    }

    pub fn init(
        alloc: std.mem.Allocator,
        loop: *public.Loop,
        userctx: ?public.UserContext,
    ) anyerror!Env {

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

        return Env{
            .nat_ctx = try NativeContext.init(alloc, loop, userctx),
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
        self.nat_ctx.deinit();

        self.* = undefined;
    }

    pub fn setUserContext(self: *Env, userctx: public.UserContext) anyerror!void {
        self.nat_ctx.userctx = userctx;
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
                _ = self.exec(script, "errorSubclass") catch {
                    // TODO: is there a reason to override the error?
                    return error.errorSubClass;
                };
            }
        }
    }

    // stop a Javascript context
    pub fn stop(self: *Env) void {
        if (self.js_ctx == null) {
            return; // no-op
        }

        // JS context
        self.js_ctx.?.exit();
        self.js_ctx = undefined;

        // Native context
        self.nat_ctx.stop();
    }
    pub fn getGlobal(self: Env) anyerror!Object {
        if (self.js_ctx == null) {
            return error.EnvNotStarted;
        }
        return self.js_ctx.?.getGlobal();
    }

    pub fn bindGlobal(self: Env, obj: anytype) anyerror!void {
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
            self.nat_ctx,
            T_refl,
            nat_obj_ptr,
            self.js_ctx.?.getGlobal(),
            self.js_ctx.?,
            self.isolate,
        );
    }

    // add a Native object in the Javascript context
    pub fn addObject(self: Env, obj: anytype, name: []const u8) anyerror!void {
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
        } else if (@typeInfo(@TypeOf(value)) == .Union) {
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
    pub fn toString(self: JSValue, alloc: std.mem.Allocator, env: Env) anyerror![]const u8 {
        return valueToUtf8(alloc, self.value, env.isolate, env.js_ctx.?);
    }

    pub fn typeOf(self: JSValue, env: Env) anyerror!public.JSTypes {
        var buf: [20]u8 = undefined;
        const str = try self.value.typeOf(env.isolate);
        const len = str.lenUtf8(env.isolate);
        const s = buf[0..len];
        _ = str.writeUtf8(env.isolate, s);
        return std.meta.stringToEnum(public.JSTypes, s) orelse {
            std.log.err("JSValueTypeNotHandled: {s}", .{s});
            return error.JSValueTypeNotHandled;
        };
    }
};

pub const TryCatch = struct {
    inner: v8.TryCatch,

    pub fn init(self: *TryCatch, env: Env) void {
        self.inner.init(env.isolate);
    }

    pub fn hasCaught(self: TryCatch) bool {
        return self.inner.hasCaught();
    }

    // the caller needs to deinit the string returned
    pub fn exception(self: TryCatch, alloc: std.mem.Allocator, env: Env) anyerror!?[]const u8 {
        if (self.inner.getException()) |msg| {
            return try valueToUtf8(alloc, msg, env.isolate, env.js_ctx.?);
        }
        return null;
    }

    // the caller needs to deinit the string returned
    pub fn stack(self: TryCatch, alloc: std.mem.Allocator, env: Env) anyerror!?[]const u8 {
        const stck = self.inner.getStackTrace(env.js_ctx.?);
        if (stck) |s| return try valueToUtf8(alloc, s, env.isolate, env.js_ctx.?);
        return null;
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
