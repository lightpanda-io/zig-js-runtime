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
    comptime API_T: type,
    comptime JSResult_T: type,
    comptime Object_T: type,
) void {

    // engine()
    assertDecl(T, "engine", fn () public.engineType);

    // init()
    assertDecl(T, "init", fn (alloc: std.mem.Allocator, loop: *public.Loop) anyerror!T);

    // deinit()
    assertDecl(T, "deinit", fn (self: *T) void);

    // load() native apis into js templates
    assertDecl(T, "load", fn (
        self: T,
        comptime apis: []API_T,
        js_types: []usize,
    ) anyerror!void);

    // start()
    assertDecl(T, "start", fn (
        self: *T,
        alloc: std.mem.Allocator,
        comptime apis: []API_T,
    ) anyerror!void);

    // stop()
    assertDecl(T, "stop", fn (self: *T) void);

    // getGlobal() to retrieve global object from current JS context
    assertDecl(T, "getGlobal", fn (self: T) anyerror!Object_T);

    // addObject() from native api into JS
    assertDecl(T, "addObject", fn (
        self: T,
        comptime apis: []API_T,
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

    // TODO: check exec, wait who have v8 specific params

    // execTryCatch() executes script in JS
    assertDecl(T, "execTryCatch", fn (
        self: T,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: ?[]const u8,
    ) anyerror!JSResult_T);

    // run() executes script in JS and waits all JS callbacks
    assertDecl(T, "run", fn (
        self: T,
        alloc: std.mem.Allocator,
        script: []const u8,
        name: ?[]const u8,
        res: *JSResult_T,
        cbk_res: ?*JSResult_T,
    ) anyerror!void);
}

pub fn JSResult(comptime T: type) void {

    // init()
    assertDecl(T, "init", fn () T);

    // deinit()
    assertDecl(T, "deinit", fn (self: T, alloc: std.mem.Allocator) void);

    // TODO: how to get the result?
}

pub fn TryCatch(comptime T: type, comptime env: type) void {

    // init()
    assertDecl(T, "init", fn (env: env) callconv(.Inline) T);

    // deinit()
    assertDecl(T, "deinit", fn (self: *T) callconv(.Inline) void);

    // exception
    assertDecl(T, "exception", fn (
        self: T,
        alloc: std.mem.Allocator,
        env: env,
    ) callconv(.Inline) anyerror!?[]const u8);
}

pub fn Callback(comptime T: type) void {
    // call()
    assertDecl(T, "call", fn (T: T, alloc: std.mem.Allocator) anyerror!void);
}

pub fn CallbackSync(comptime T: type) void {
    // call()
    assertDecl(T, "call", fn (T: T, alloc: std.mem.Allocator) anyerror!void);
}

pub fn CallbackArg(comptime _: type) void {}

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
