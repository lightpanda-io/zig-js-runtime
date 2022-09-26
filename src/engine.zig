const std = @import("std");
const v8 = @import("v8");
const utils = @import("utils.zig");

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

pub const Isolate = struct {
    isolate: v8.Isolate,
    params: v8.CreateParams,
    hscope: v8.HandleScope,

    pub fn init(alloc: std.mem.Allocator) *Isolate {
        // create a new v8 Isolate
        var params = v8.initCreateParams();
        params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
        var isolate = v8.Isolate.init(&params);
        isolate.enter();

        // v8 handle scope
        var hscope: v8.HandleScope = undefined;
        hscope.init(isolate);

        // allocate memory of instance
        var iso = alloc.create(Isolate) catch unreachable;
        iso.* = .{
            .isolate = isolate,
            .params = params,
            .hscope = hscope,
        };
        return iso;
    }

    // create a v8 Context, providing the globals namespace
    pub fn initContext(self: Isolate, globals: v8.ObjectTemplate) v8.Context {
        var context = v8.Context.init(self.isolate, globals, null);
        context.enter();
        return context;
    }

    pub fn deinitContext(_: Isolate, context: v8.Context) void {
        context.exit();
    }

    pub fn deinit(self: *Isolate, alloc: std.mem.Allocator) void {
        // handle scope
        self.hscope.deinit();

        // isolate
        self.isolate.exit();
        self.isolate.deinit();
        v8.destroyArrayBufferAllocator(self.params.array_buffer_allocator.?);

        // free memory of instance
        alloc.destroy(self);
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
