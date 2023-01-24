const std = @import("std");

const eng = @import("engine.zig");

const bench = @import("bench.zig");
const pretty = @import("pretty.zig");

const proto = @import("proto_test.zig");
const primitive_types = @import("types_primitives_test.zig");
const callback = @import("cbk_test.zig");

test {

    // create v8 vm
    const vm = eng.VM.init();
    defer vm.deinit();

    // base and prototype tests
    const proto_apis = comptime proto.generate(); // stage1: we need comptime
    var proto_alloc = bench.allocator(std.testing.allocator);
    _ = try eng.Load(proto_alloc.allocator(), false, proto.exec, proto_apis);
    const proto_alloc_stats = proto_alloc.stats();
    const proto_alloc_size = pretty.Measure{
        .unit = "b",
        .value = proto_alloc_stats.alloc_size,
    };

    // primitive types tests
    const prim_apis = comptime primitive_types.generate(); // stage1: we need to comptime
    var prim_alloc = bench.allocator(std.testing.allocator);
    _ = try eng.Load(prim_alloc.allocator(), false, primitive_types.exec, prim_apis);
    const prim_alloc_stats = prim_alloc.stats();
    const prim_alloc_size = pretty.Measure{
        .unit = "b",
        .value = prim_alloc_stats.alloc_size,
    };

    // callback tests
    const cbk_apis = comptime callback.generate(); // stage1: we need comptime
    var cbk_alloc = bench.allocator(std.testing.allocator);
    _ = try eng.Load(cbk_alloc.allocator(), false, callback.exec, cbk_apis);
    const cbk_alloc_stats = cbk_alloc.stats();
    const cbk_alloc_size = pretty.Measure{
        .unit = "b",
        .value = cbk_alloc_stats.alloc_size,
    };

    // benchmark table
    const row_shape = .{
        []const u8,
        u64,
        pretty.Measure,
    };
    const header = .{
        "FUNCTION",
        "ALLOCATIONS",
        "HEAP SIZE",
    };
    const table = try pretty.GenerateTable(3, row_shape, pretty.TableConf{ .margin_left = "  " });
    const title = "Test jsengine ✅";
    var t = table.init(title, header);
    try t.addRow(.{ "Prototype", proto_alloc.alloc_nb, proto_alloc_size });
    try t.addRow(.{ "Primitives", prim_alloc.alloc_nb, prim_alloc_size });
    try t.addRow(.{ "Callbacks", cbk_alloc.alloc_nb, cbk_alloc_size });

    const out = std.io.getStdErr().writer();
    try t.render(out);
}
