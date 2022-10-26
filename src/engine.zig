const std = @import("std");
const v8 = @import("v8");

const utils = @import("utils.zig");
const gen = @import("generate.zig");

pub const ExecFunc = (fn (v8.Isolate, v8.ObjectTemplate) anyerror!void);

pub fn Load(comptime execFn: ExecFunc, comptime apis: []gen.API) !void {

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

    try gen.load(isolate, globals, apis);
    return execFn(isolate, globals);
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
