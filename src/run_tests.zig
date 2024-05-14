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

const eng = @import("engine.zig");
const ref = @import("reflect.zig");
const gen = @import("generate.zig");

const bench = @import("bench.zig");
const pretty = @import("pretty.zig");

const public = @import("api.zig");
const VM = public.VM;

// tests imports
const proto = @import("tests/proto_test.zig");
const primitive_types = @import("tests/types_primitives_test.zig");
const native_types = @import("tests/types_native_test.zig");
const complex_types = @import("tests/types_complex_test.zig");
const multiple_types = @import("tests/types_multiple_test.zig");
const object_types = @import("tests/types_object.zig");
const callback = @import("tests/cbk_test.zig");
const global = @import("tests/global_test.zig");

// test to do
const do_proto = true;
const do_prim = true;
const do_nat = true;
const do_complex = true;
const do_multi = true;
const do_obj = true;
const do_cbk = true;
const do_global = true;

// tests nb
const tests_nb = blk: {
    comptime var nb = 0;
    if (do_proto) nb += 1;
    if (do_prim) nb += 1;
    if (do_nat) nb += 1;
    if (do_complex) nb += 1;
    if (do_multi) nb += 1;
    if (do_obj) nb += 1;
    if (do_cbk) nb += 1;
    if (do_global) nb += 1;
    break :blk nb;
};

// Types
pub const Types = gen.reflect(gen.MergeTuple(.{
    proto.Types,
    primitive_types.Types,
    native_types.Types,
    complex_types.Types,
    multiple_types.Types,
    object_types.Types,
    callback.Types,
    global.Types,
}));

pub fn main() !void {
    std.debug.print("\n", .{});

    // reflect tests
    try comptime ref.tests();
    std.debug.print("Reflect tests: OK\n", .{});

    if (tests_nb == 0) {
        std.debug.print("\nWARNING: No end to end tests.\n", .{});
        return;
    }

    // create JS vm
    const vm = VM.init();
    defer vm.deinit();

    // base and prototype tests
    var proto_alloc: bench.Allocator = undefined;
    if (do_proto) {
        proto_alloc = bench.allocator(std.testing.allocator);
        var proto_arena = std.heap.ArenaAllocator.init(proto_alloc.allocator());
        defer proto_arena.deinit();
        _ = try eng.loadEnv(&proto_arena, proto.exec);
    }

    // primitive types tests
    var prim_alloc: bench.Allocator = undefined;
    if (do_prim) {
        prim_alloc = bench.allocator(std.testing.allocator);
        var prim_arena = std.heap.ArenaAllocator.init(prim_alloc.allocator());
        defer prim_arena.deinit();
        _ = try eng.loadEnv(&prim_arena, primitive_types.exec);
    }

    // native types tests
    var nat_alloc: bench.Allocator = undefined;
    if (do_nat) {
        nat_alloc = bench.allocator(std.testing.allocator);
        var nat_arena = std.heap.ArenaAllocator.init(nat_alloc.allocator());
        defer nat_arena.deinit();
        _ = try eng.loadEnv(&nat_arena, native_types.exec);
    }

    // complex types tests
    var complex_alloc: bench.Allocator = undefined;
    if (do_complex) {
        complex_alloc = bench.allocator(std.testing.allocator);
        var complex_arena = std.heap.ArenaAllocator.init(complex_alloc.allocator());
        defer complex_arena.deinit();
        _ = try eng.loadEnv(&complex_arena, complex_types.exec);
    }

    // multiple types tests
    var multi_alloc: bench.Allocator = undefined;
    if (do_multi) {
        multi_alloc = bench.allocator(std.testing.allocator);
        var multi_arena = std.heap.ArenaAllocator.init(multi_alloc.allocator());
        defer multi_arena.deinit();
        _ = try eng.loadEnv(&multi_arena, multiple_types.exec);
    }

    // object types tests
    var obj_alloc: bench.Allocator = undefined;
    if (do_obj) {
        obj_alloc = bench.allocator(std.testing.allocator);
        var obj_arena = std.heap.ArenaAllocator.init(obj_alloc.allocator());
        defer obj_arena.deinit();
        _ = try eng.loadEnv(&obj_arena, object_types.exec);
    }

    // callback tests
    var cbk_alloc: bench.Allocator = undefined;
    if (do_cbk) {
        cbk_alloc = bench.allocator(std.testing.allocator);
        var cbk_arena = std.heap.ArenaAllocator.init(cbk_alloc.allocator());
        defer cbk_arena.deinit();
        _ = try eng.loadEnv(&cbk_arena, callback.exec);
    }

    // global tests
    var global_alloc: bench.Allocator = undefined;
    if (do_global) {
        global_alloc = bench.allocator(std.testing.allocator);
        var global_arena = std.heap.ArenaAllocator.init(global_alloc.allocator());
        defer global_arena.deinit();
        _ = try eng.loadEnv(&global_arena, global.exec);
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

    if (do_obj) {
        const obj_alloc_stats = obj_alloc.stats();
        const obj_alloc_size = pretty.Measure{
            .unit = "b",
            .value = obj_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Objects", obj_alloc.alloc_nb, obj_alloc_size });
    }

    if (do_cbk) {
        const cbk_alloc_stats = cbk_alloc.stats();
        const cbk_alloc_size = pretty.Measure{
            .unit = "b",
            .value = cbk_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Callbacks", cbk_alloc.alloc_nb, cbk_alloc_size });
    }

    if (do_global) {
        const global_alloc_stats = global_alloc.stats();
        const global_alloc_size = pretty.Measure{
            .unit = "b",
            .value = global_alloc_stats.alloc_size,
        };
        try t.addRow(.{ "Global", global_alloc.alloc_nb, global_alloc_size });
    }

    const out = std.io.getStdErr().writer();
    try t.render(out);
}
