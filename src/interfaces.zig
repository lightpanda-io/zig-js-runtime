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

const internal = @import("internal_api.zig");
const refl = internal.refl;

const public = @import("api.zig");

// Interfaces definitions
// ----------------------

// NOTE: all thoses interfaces defintions checks must be called comptime

// TODO: change anyerror to custom error set

pub fn API(comptime T: type, comptime LoadFnType: type) void {

    // nativeT(), the reflected type of a native struct
    assertDecl(T, "nativeT", fn (self: T) callconv(.Inline) refl.Struct);

    // loadFn(), the function loading and binding this native struct into the JS engine
    assertDecl(T, "loadFn", fn (self: T) callconv(.Inline) LoadFnType);
}

pub fn VM(comptime T: type) void {

    // init()
    assertDecl(T, "init", fn () T);

    // deinit()
    assertDecl(T, "deinit", fn (T) void);
}

pub fn Env(
    comptime T: type,
    comptime Inspector_T: type,
    comptime JSValue_T: type,
    comptime Object_T: type,
) void {

    // engine()
    assertDecl(T, "engine", fn () public.EngineType);

    // init()
    assertDecl(T, "init", fn (self: *T, alloc: std.mem.Allocator, loop: *public.Loop, userctx: ?public.UserContext) void);

    // deinit()
    assertDecl(T, "deinit", fn (self: *T) void);

    // load() native apis into js templates
    assertDecl(T, "load", fn (self: *T, js_types: []usize) anyerror!void);

    assertDecl(T, "bindGlobal", fn (self: *T, ob: anytype) anyerror!void);

    assertDecl(T, "setInspector", fn (self: *T, inspector: Inspector_T) void);
    assertDecl(T, "getInspector", fn (self: T) callconv(.Inline) ?Inspector_T);

    assertDecl(T, "setUserContext", fn (
        self: *T,
        userctx: public.UserContext,
    ) anyerror!void);

    // start()
    assertDecl(T, "start", fn (self: *T) anyerror!void);

    // stop()
    assertDecl(T, "stop", fn (self: *T) void);

    // getGlobal() to retrieve global object from current JS context
    assertDecl(T, "getGlobal", fn (self: T) anyerror!Object_T);

    // addObject() from native api into JS
    assertDecl(T, "addObject", fn (
        self: *T,
        obj: anytype,
        name: []const u8,
    ) anyerror!void);

    // attachObject() from JS to another JS object
    // if to_obj is null, globals is implied
    assertDecl(T, "attachObject", fn (
        self: T,
        obj: Object_T,
        name: []const u8,
        to_obj: ?Object_T,
    ) anyerror!void);

    // exec() executes script in JS
    assertDecl(T, "exec", fn (
        self: T,
        script: []const u8,
        name: ?[]const u8,
    ) anyerror!JSValue_T);

    // wait() all JS callbacks
    assertDecl(T, "wait", fn (self: T) anyerror!void);

    // execWait() executes script in JS and waits all JS callbacks
    assertDecl(T, "execWait", fn (
        self: T,
        script: []const u8,
        name: ?[]const u8,
    ) anyerror!JSValue_T);
}

pub fn JSValue(comptime T: type, env: type) void {

    // toString()
    assertDecl(T, "toString", fn (self: T, alloc: std.mem.Allocator, env: *const env) anyerror![]const u8);

    // typeOf()
    assertDecl(T, "typeOf", fn (self: T, env: env) anyerror!public.JSTypes);
}

pub fn JSObjectID(comptime T: type) void {

    // get()
    assertDecl(T, "get", fn (self: T) usize);
}

pub fn TryCatch(comptime T: type, comptime env: type) void {

    // init()
    assertDecl(T, "init", fn (self: *T, env: *const env) void);

    // deinit()
    assertDecl(T, "deinit", fn (self: *T) void);

    // hasCaught()
    assertDecl(T, "hasCaught", fn (self: T) bool);

    // exception()
    assertDecl(T, "exception", fn (
        self: T,
        alloc: std.mem.Allocator,
        env: *const env,
    ) anyerror!?[]const u8);

    // err()
    assertDecl(T, "err", fn (
        self: T,
        alloc: std.mem.Allocator,
        env: *const env,
    ) anyerror!?[]const u8);

    // stack()
    assertDecl(T, "stack", fn (
        self: T,
        alloc: std.mem.Allocator,
        env: *const env,
    ) anyerror!?[]const u8);
}

pub fn Callback(comptime T: type, comptime Res_T: type) void {

    // id()
    assertDecl(T, "id", fn (T: T) usize);

    // call()
    assertDecl(T, "call", fn (T: T, nat_args: anytype) anyerror!void);

    // trycall()
    assertDecl(T, "trycall", fn (T: T, nat_args: anytype, res: *Res_T) anyerror!void);
}

pub fn CallbackSync(comptime T: type, comptime Res_T: type) void {
    // call()
    assertDecl(T, "call", fn (T: T, alloc: std.mem.Allocator) anyerror!void);

    // trycall()
    assertDecl(T, "trycall", fn (T: T, alloc: std.mem.Allocator, res: *Res_T) anyerror!void);
}

pub fn CallbackArg(comptime _: type) void {}

pub fn CallbackResult(comptime T: type) void {
    // init()
    assertDecl(T, "init", fn (alloc: std.mem.Allocator) T);

    // deinit()
    assertDecl(T, "deinit", fn (self: T) void);

    // TODO: how to get the result?
}

pub fn Inspector(comptime T: type, comptime Env_T: type) void {

    // init()
    assertDecl(T, "init", fn (
        alloc: std.mem.Allocator,
        env: *const Env_T,
        ctx: *anyopaque,
        onResp: public.InspectorOnResponseFn,
        onEvent: public.InspectorOnEventFn,
    ) anyerror!T);

    // deinit()
    assertDecl(T, "deinit", fn (self: T, alloc: std.mem.Allocator) void);

    // contextCreated()
    assertDecl(T, "contextCreated", fn (
        self: T,
        env: *const Env_T,
        name: []const u8,
        origin: []const u8,
        auxData: ?[]const u8,
    ) void);

    // send()
    assertDecl(T, "send", fn (self: T, env: Env_T, msg: []const u8) void);
}

// Utils
// -----

// from https://github.com/hexops/mach-gpu/blob/main/src/interface.zig
fn assertDecl(comptime T: anytype, comptime name: []const u8, comptime Decl: type) void {
    if (!@hasDecl(T, name)) @compileError("Interface missing declaration: " ++ @typeName(Decl));
    // TODO: check if decl is:
    // - function
    // - pub
    const FoundDecl = @TypeOf(@field(T, name));
    if (FoundDecl != Decl) @compileError("Interface field '" ++ name ++ "'\n\texpected type: " ++ @typeName(Decl) ++ "\n\t   found type: " ++ @typeName(FoundDecl));
}
