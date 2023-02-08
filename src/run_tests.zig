const std = @import("std");

const eng = @import("engine.zig");

const bench = @import("bench.zig");
const pretty = @import("pretty.zig");

const proto = @import("tests/proto_test.zig");
const primitive_types = @import("tests/types_primitives_test.zig");
const native_types = @import("tests/types_native_test.zig");
const multiple_types = @import("tests/types_multiple_test.zig");
const callback = @import("tests/cbk_test.zig");

test {

    // create JS vm
    const vm = eng.VM.init();
    defer vm.deinit();

    // base and prototype tests
    const proto_apis = comptime proto.generate(); // stage1: we need comptime
    var proto_alloc = bench.allocator(std.testing.allocator);
    var proto_arena = std.heap.ArenaAllocator.init(proto_alloc.allocator());
    defer proto_arena.deinit();
    _ = try eng.loadEnv(&proto_arena, proto.exec, proto_apis);
    const proto_alloc_stats = proto_alloc.stats();
    const proto_alloc_size = pretty.Measure{
        .unit = "b",
        .value = proto_alloc_stats.alloc_size,
    };

    // primitive types tests
    const prim_apis = comptime primitive_types.generate(); // stage1: we need to comptime
    var prim_alloc = bench.allocator(std.testing.allocator);
    var prim_arena = std.heap.ArenaAllocator.init(prim_alloc.allocator());
    defer prim_arena.deinit();
    _ = try eng.loadEnv(&prim_arena, primitive_types.exec, prim_apis);
    const prim_alloc_stats = prim_alloc.stats();
    const prim_alloc_size = pretty.Measure{
        .unit = "b",
        .value = prim_alloc_stats.alloc_size,
    };

    // native types tests
    const nat_apis = comptime native_types.generate(); // stage1: we need to comptime
    var nat_alloc = bench.allocator(std.testing.allocator);
    var nat_arena = std.heap.ArenaAllocator.init(nat_alloc.allocator());
    defer nat_arena.deinit();
    _ = try eng.loadEnv(&nat_arena, native_types.exec, nat_apis);
    const nat_alloc_stats = nat_alloc.stats();
    const nat_alloc_size = pretty.Measure{
        .unit = "b",
        .value = nat_alloc_stats.alloc_size,
    };

    // multiple types tests
    const multi_apis = comptime multiple_types.generate(); // stage1: we need to comptime
    var multi_alloc = bench.allocator(std.testing.allocator);
    var multi_arena = std.heap.ArenaAllocator.init(multi_alloc.allocator());
    defer multi_arena.deinit();
    _ = try eng.loadEnv(&multi_arena, multiple_types.exec, multi_apis);
    const multi_alloc_stats = multi_alloc.stats();
    const multi_alloc_size = pretty.Measure{
        .unit = "b",
        .value = multi_alloc_stats.alloc_size,
    };

    // callback tests
    const cbk_apis = comptime callback.generate(); // stage1: we need comptime
    var cbk_alloc = bench.allocator(std.testing.allocator);
    var cbk_arena = std.heap.ArenaAllocator.init(cbk_alloc.allocator());
    defer cbk_arena.deinit();
    _ = try eng.loadEnv(&cbk_arena, callback.exec, cbk_apis);
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
    const table = try pretty.GenerateTable(5, row_shape, pretty.TableConf{ .margin_left = "  " });
    const title = "Test jsengine ✅";
    var t = table.init(title, header);
    try t.addRow(.{ "Prototype", proto_alloc.alloc_nb, proto_alloc_size });
    try t.addRow(.{ "Primitives", prim_alloc.alloc_nb, prim_alloc_size });
    try t.addRow(.{ "Natives", nat_alloc.alloc_nb, nat_alloc_size });
    try t.addRow(.{ "Multiples", multi_alloc.alloc_nb, multi_alloc_size });
    try t.addRow(.{ "Callbacks", cbk_alloc.alloc_nb, cbk_alloc_size });

    const out = std.io.getStdErr().writer();
    try t.render(out);
}
