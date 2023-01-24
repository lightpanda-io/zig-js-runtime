const std = @import("std");
const builtin = @import("builtin");

const v8 = @import("v8");

const utils = @import("utils.zig");
const Loop = @import("loop.zig").SingleThreaded;
const refs = @import("refs.zig");
const Store = @import("store.zig");
const gen = @import("generate.zig");
const refl = @import("reflect.zig");

pub const compile = gen.compile;
pub const shell = @import("shell.zig").shell;

pub const ExecRes = union(enum) {
    OK: void,
    Time: u64,
};

pub const ExecOK = ExecRes{ .OK = {} };

pub const ExecFunc = (fn (
    *Loop,
    v8.Isolate,
    v8.ObjectTemplate,
    []gen.ProtoTpl,
    comptime []gen.API,
) anyerror!ExecRes);

pub fn Load(
    alloc: std.mem.Allocator,
    comptime alloc_auto_free: bool,
    comptime execFn: ExecFunc,
    comptime apis: []gen.API,
) !ExecRes {

    // Set globals values
    // ------------------

    // allocator
    utils.allocator = alloc;

    // refs map
    refs.map = refs.Map{};
    defer refs.map.deinit(utils.allocator);

    // I/O loop
    var loop = try Loop.init(utils.allocator);
    utils.loop = &loop;
    defer loop.deinit();

    // store
    if (!alloc_auto_free) {
        Store.default = Store.init(utils.allocator);
    }
    defer {
        // keep defer on the function scope
        if (!alloc_auto_free) {
            Store.default.?.deinit(utils.allocator);
        }
    }

    var start: std.time.Instant = undefined;
    if (builtin.is_test) {
        start = try std.time.Instant.now();
    }

    // v8 values
    // ---------

    // params
    var params = v8.initCreateParams();
    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    defer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

    // isolate
    var isolate = v8.Isolate.init(&params);
    defer isolate.deinit();
    isolate.enter();
    defer isolate.exit();

    // handle scope
    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    // ObjectTemplate for the global namespace
    const globals = v8.ObjectTemplate.initDefault(isolate);

    var iso_start: std.time.Instant = undefined;
    if (builtin.is_test) {
        iso_start = try std.time.Instant.now();
    }

    // APIs
    // ----

    // NOTE: apis ([]gen.API) and tpls ([]gen.ProtoTpl)
    // represent the same structs, one at comptime (apis),
    // the other at runtime (tpls).
    // The implementation assumes that they are consistents:
    // - same size
    // - same order

    var tpls: [apis.len]gen.ProtoTpl = undefined;
    try gen.load(isolate, globals, apis, &tpls);

    var load_start: std.time.Instant = undefined;
    if (builtin.is_test) {
        load_start = try std.time.Instant.now();
    }

    // JS exec
    // -------

    // execute JS function
    const res = try execFn(utils.loop, isolate, globals, &tpls, apis);

    // Stats
    // -----

    var exec_end: std.time.Instant = undefined;
    if (builtin.is_test) {
        exec_end = try std.time.Instant.now();
    }

    if (builtin.is_test) {
        const us = std.time.ns_per_us;

        const iso_time = std.time.Instant.since(iso_start, start);
        const load_time = std.time.Instant.since(load_start, iso_start);
        const exec_time = std.time.Instant.since(exec_end, load_start);
        const total_time = std.time.Instant.since(exec_end, start);

        const iso_per = iso_time * 100 / total_time;
        const load_per = load_time * 100 / total_time;
        const exec_per = exec_time * 100 / total_time;

        std.debug.print("\nstart of isolate:\t{d}us\t{d}%\n", .{ iso_time / us, iso_per });
        std.debug.print("load of apis:\t\t{d}us\t{d}%\n", .{ load_time / us, load_per });
        std.debug.print("exec:\t\t\t{d}us\t{d}%\n", .{ exec_time / us, exec_per });
        std.debug.print("Total:\t\t\t{d}us\n", .{total_time / us});
    }

    return res;
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

// Execute Javascript script
// if no error you need to call deinit on the returned result
pub fn jsExecScript(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, script: []const u8, name: []const u8, try_catch: v8.TryCatch) utils.ExecuteResult {
    var res: utils.ExecuteResult = undefined;
    const origin = v8.String.initUtf8(isolate, name);
    utils.executeString(alloc, isolate, context, script, origin, &res, try_catch);
    return res;
}

pub fn createV8Object(
    alloc: std.mem.Allocator,
    isolate: v8.Isolate,
    context: v8.Context,
    target: v8.Object,
    tpl: v8.FunctionTemplate,
    comptime T_refl: refl.Struct,
) !*T_refl.T {
    const obj_tpl = tpl.getInstanceTemplate();
    const obj = obj_tpl.initInstance(context);
    const key = v8.String.initUtf8(isolate, T_refl.js_name);
    if (!target.setValue(context, key, obj)) {
        return error.CreateV8Object;
    }
    return try gen.setNativeObject(alloc, T_refl, obj, isolate);
}
