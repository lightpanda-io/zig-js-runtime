const std = @import("std");
const v8 = @import("v8");

const engine = @import("engine.zig");
const utils = @import("utils.zig");
const refs = @import("refs.zig");
const Store = @import("store.zig");

pub fn main() !void {

    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    utils.allocator = alloc;

    // store
    Store.default = Store.init(utils.allocator);
    defer Store.default.deinit(utils.allocator);

    // create v8 vm
    const vm = engine.VM.init();
    defer vm.deinit();

    // create v8 isolate
    const iso = engine.Isolate.init(utils.allocator);
    defer iso.deinit(utils.allocator);
    const isolate = iso.isolate;

    // create a v8 ObjectTemplate for the global namespace
    const globals = v8.ObjectTemplate.initDefault(isolate);

    // create v8 context
    const context = iso.initContext(globals);
    defer iso.deinitContext(context);

    // javascript script
    const script =
        \\true === true;
    ;

    // exec javascript in context
    var res = engine.jsExecScript(utils.allocator, isolate, context, script, "main.js");
    defer res.deinit();

    // javascript result
    if (!res.success) {
        std.debug.print("{s}\n", .{res.stack.?});
        return error.JavascriptError;
    }
    std.log.info("{s}", .{res.result});
}

test {
    // allocator
    utils.allocator = std.testing.allocator;

    // refs map
    refs.map = refs.Map{};
    defer refs.map.deinit(utils.allocator);

    // store
    Store.default = Store.init(utils.allocator);
    defer Store.default.deinit(utils.allocator);

    // create v8 vm
    const vm = engine.VM.init();
    defer vm.deinit();

    // create v8 isolate
    const iso = engine.Isolate.init(utils.allocator);
    defer iso.deinit(utils.allocator);
    const isolate = iso.isolate;

    // end to end
    const proto = @import("proto_test.zig");
    try proto.doTest(isolate);

    // unitary
    const primitive_types = @import("types_primitives_test.zig");
    try primitive_types.doTest(isolate);
}
