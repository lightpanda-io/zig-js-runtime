const std = @import("std");

const eng = @import("engine.zig");
const ref = @import("reflect.zig");

const bench = @import("bench.zig");
const pretty = @import("pretty.zig");

const public = @import("api.zig");
const VM = public.VM;

// tests
const proto = @import("tests/proto_test.zig");
const primitive_types = @import("tests/types_primitives_test.zig");
const native_types = @import("tests/types_native_test.zig");
const complex_types = @import("tests/types_complex_test.zig");
const multiple_types = @import("tests/types_multiple_test.zig");
const callback = @import("tests/cbk_test.zig");

test {
    std.debug.print("\n", .{});

    // reflect tests
    try comptime ref.tests();
    std.debug.print("Reflect tests: OK\n", .{});

    // test to do
    comptime var tests_nb: usize = 0;
    const do_proto = true;
    const do_prim = true;
    const do_nat = true; // TODO: if enable alone we have "exceeded 1000 backwards branches" error
    const do_complex = true;
    const do_multi = true;
    const do_cbk = true;
    if (!do_proto and !do_prim and !do_nat and !do_complex and !do_multi and !do_cbk) {
        std.debug.print("\nWARNING: No end to end tests.\n", .{});
        return;
    }

    // create JS vm
    const vm = VM.init();
    defer vm.deinit();

    // base and prototype tests
    var proto_alloc: bench.Allocator = undefined;
    if (do_proto) {
        tests_nb += 1;
        const proto_apis = comptime try proto.generate(); // stage1: we need comptime
        proto_alloc = bench.allocator(std.testing.allocator);
        var proto_arena = std.heap.ArenaAllocator.init(proto_alloc.allocator());
        defer proto_arena.deinit();
        _ = try eng.loadEnv(&proto_arena, proto.exec, proto_apis);
    }

    // primitive types tests
    var prim_alloc: bench.Allocator = undefined;
    if (do_prim) {
        tests_nb += 1;
        const prim_apis = comptime try primitive_types.generate(); // stage1: we need to comptime
        prim_alloc = bench.allocator(std.testing.allocator);
        var prim_arena = std.heap.ArenaAllocator.init(prim_alloc.allocator());
        defer prim_arena.deinit();
        _ = try eng.loadEnv(&prim_arena, primitive_types.exec, prim_apis);
    }

    // native types tests
    var nat_alloc: bench.Allocator = undefined;
    if (do_nat) {
        tests_nb += 1;
        const nat_apis = comptime try native_types.generate(); // stage1: we need to comptime
        nat_alloc = bench.allocator(std.testing.allocator);
        var nat_arena = std.heap.ArenaAllocator.init(nat_alloc.allocator());
        defer nat_arena.deinit();
        _ = try eng.loadEnv(&nat_arena, native_types.exec, nat_apis);
    }

    // complex types tests
    var complex_alloc: bench.Allocator = undefined;
    if (do_complex) {
        tests_nb += 1;
        const complex_apis = comptime try complex_types.generate(); // stage1: we need to comptime
        complex_alloc = bench.allocator(std.testing.allocator);
        var complex_arena = std.heap.ArenaAllocator.init(complex_alloc.allocator());
        defer complex_arena.deinit();
        _ = try eng.loadEnv(&complex_arena, complex_types.exec, complex_apis);
    }

    // multiple types tests
    var multi_alloc: bench.Allocator = undefined;
    if (do_multi) {
        tests_nb += 1;
        const multi_apis = comptime try multiple_types.generate(); // stage1: we need to comptime
        multi_alloc = bench.allocator(std.testing.allocator);
        var multi_arena = std.heap.ArenaAllocator.init(multi_alloc.allocator());
        defer multi_arena.deinit();
        _ = try eng.loadEnv(&multi_arena, multiple_types.exec, multi_apis);
    }

    // callback tests
    var cbk_alloc: bench.Allocator = undefined;
    if (do_cbk) {
        tests_nb += 1;
        const cbk_apis = comptime try callback.generate(); // stage1: we need comptime
        cbk_alloc = bench.allocator(std.testing.allocator);
        var cbk_arena = std.heap.ArenaAllocator.init(cbk_alloc.allocator());
        defer cbk_arena.deinit();
        _ = try eng.loadEnv(&cbk_arena, callback.exec, cbk_apis);
    }

    if (tests_nb == 0) {
        return;
    }

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
    const table = try pretty.GenerateTable(tests_nb, row_shape, pretty.TableConf{ .margin_left = "  " });
    const title = "Test jsengine ✅";
    var t = table.init(title, header);

    if (do_proto) {
        const proto_alloc_stats = proto_alloc.stats();
        const proto_alloc_size = pretty.Measure{
            .unit = "b",
            .value = proto_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Prototype", proto_alloc.alloc_nb, proto_alloc_size });
    }

    if (do_prim) {
        const prim_alloc_stats = prim_alloc.stats();
        const prim_alloc_size = pretty.Measure{
            .unit = "b",
            .value = prim_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Primitives", prim_alloc.alloc_nb, prim_alloc_size });
    }
    if (do_nat) {
        const nat_alloc_stats = nat_alloc.stats();
        const nat_alloc_size = pretty.Measure{
            .unit = "b",
            .value = nat_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Natives", nat_alloc.alloc_nb, nat_alloc_size });
    }

    if (do_complex) {
        const complex_alloc_stats = complex_alloc.stats();
        const complex_alloc_size = pretty.Measure{
            .unit = "b",
            .value = complex_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Complexes", complex_alloc.alloc_nb, complex_alloc_size });
    }

    if (do_multi) {
        const multi_alloc_stats = multi_alloc.stats();
        const multi_alloc_size = pretty.Measure{
            .unit = "b",
            .value = multi_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Multiples", multi_alloc.alloc_nb, multi_alloc_size });
    }

    if (do_cbk) {
        const cbk_alloc_stats = cbk_alloc.stats();
        const cbk_alloc_size = pretty.Measure{
            .unit = "b",
            .value = cbk_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Callbacks", cbk_alloc.alloc_nb, cbk_alloc_size });
    }

    const out = std.io.getStdErr().writer();
    try t.render(out);
}
