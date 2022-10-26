const std = @import("std");
const builtin = @import("builtin");
const v8 = @import("v8");

const utils = @import("utils.zig");
const gen = @import("generate.zig");

pub const ExecFunc = (fn (v8.Isolate, v8.ObjectTemplate) anyerror!void);

pub fn Load(comptime execFn: ExecFunc, comptime apis: []gen.API) !void {
    var start: std.time.Instant = undefined;
    if (builtin.is_test) {
        start = try std.time.Instant.now();
    }

    // v8 params
    var params = v8.initCreateParams();
    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    defer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);

    // v8 Isolate
    var isolate = v8.Isolate.init(&params);
    defer isolate.deinit();
    isolate.enter();
    defer isolate.exit();

    // v8 handle scope
    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    // v8 ObjectTemplate for the global namespace
    const globals = v8.ObjectTemplate.initDefault(isolate);

    var iso_start: std.time.Instant = undefined;
    if (builtin.is_test) {
        iso_start = try std.time.Instant.now();
    }

    // load APIs
    try gen.load(isolate, globals, apis);

    var load_start: std.time.Instant = undefined;
    if (builtin.is_test) {
        load_start = try std.time.Instant.now();
    }

    // exec
    try execFn(isolate, globals);

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
pub fn jsExecScript(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, script: []const u8, name: []const u8) utils.ExecuteResult {
    var res: utils.ExecuteResult = undefined;
    const origin = v8.String.initUtf8(isolate, name);
    utils.executeString(alloc, isolate, context, script, origin, &res);
    return res;
}
