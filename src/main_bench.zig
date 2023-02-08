const std = @import("std");

const jsruntime = @import("jsruntime.zig");
const eng = @import("engine.zig");

const bench = @import("bench.zig");
const pretty = @import("pretty.zig");

const proto = @import("tests/proto_test.zig");

const kb = 1024;
const us = std.time.ns_per_us;

fn benchWithIsolate(
    bench_alloc: *bench.Allocator,
    arena_alloc: *std.heap.ArenaAllocator,
    comptime ctxExecFn: jsruntime.ContextExecFn,
    comptime apis: []jsruntime.API,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !bench.Result {
    const duration = try bench.call(
        jsruntime.loadEnv,
        .{ arena_alloc, ctxExecFn, apis },
        iter,
        warmup,
    );
    const alloc_stats = bench_alloc.stats();
    return bench.Result{
        .duration = duration,
        .alloc_nb = alloc_stats.alloc_nb,
        .realloc_nb = alloc_stats.realloc_nb,
        .alloc_size = alloc_stats.alloc_size,
    };
}

var duration_global: u64 = undefined;

fn benchWithoutIsolate(
    bench_alloc: *bench.Allocator,
    arena_alloc: *std.heap.ArenaAllocator,
    comptime ctxExecFn: jsruntime.ContextExecFn,
    comptime apis: []jsruntime.API,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !bench.Result {
    const s = struct {
        fn do(
            alloc_func: std.mem.Allocator,
            js_env: *jsruntime.Env,
            comptime apis_func: []jsruntime.API,
        ) !void {
            const duration = try bench.call(
                ctxExecFn,
                .{ alloc_func, js_env, apis_func },
                iter,
                warmup,
            );
            duration_global = duration;
        }
    };
    try eng.loadEnv(arena_alloc, s.do, apis);
    const alloc_stats = bench_alloc.stats();
    return bench.Result{
        .duration = duration_global,
        .alloc_nb = alloc_stats.alloc_nb,
        .realloc_nb = alloc_stats.realloc_nb,
        .alloc_size = alloc_stats.alloc_size,
    };
}

pub fn main() !void {

    // generate APIs
    const apis = comptime proto.generate(); // stage1: we need comptime

    // create JS vm
    const vm = jsruntime.VM.init();
    defer vm.deinit();

    // allocators
    var bench1 = bench.allocator(std.heap.page_allocator);
    var arena1 = std.heap.ArenaAllocator.init(bench1.allocator());
    defer arena1.deinit();
    var bench2 = bench.allocator(std.heap.page_allocator);
    var arena2 = std.heap.ArenaAllocator.init(bench2.allocator());
    defer arena2.deinit();

    // benchmark conf
    const iter = 100;
    const warmup = iter / 20;
    const title_fmt = "Benchmark jsengine 🚀 (~= {d} iters)";
    var buf: [100]u8 = undefined;
    const title = try std.fmt.bufPrint(buf[0..], title_fmt, .{iter});

    // benchmark funcs
    const res1 = try benchWithIsolate(&bench1, &arena1, proto.exec, apis, iter, warmup);
    const res2 = try benchWithoutIsolate(&bench2, &arena2, proto.exec, apis, iter, warmup);

    // benchmark measures
    const dur1 = pretty.Measure{ .unit = "us", .value = res1.duration / us };
    const dur2 = pretty.Measure{ .unit = "us", .value = res2.duration / us };
    const size1 = pretty.Measure{ .unit = "kb", .value = res1.alloc_size / kb };
    const size2 = pretty.Measure{ .unit = "kb", .value = res2.alloc_size / kb };

    // benchmark table
    const row_shape = .{
        []const u8,
        pretty.Measure,
        u64,
        u64,
        pretty.Measure,
    };
    const table = try pretty.GenerateTable(2, row_shape, pretty.TableConf{ .margin_left = "  " });
    const header = .{
        "FUNCTION",
        "DURATION (per iter)",
        "ALLOCATIONS (nb)",
        "RE-ALLOCATIONS (nb)",
        "HEAP SIZE",
    };
    var t = table.init(title, header);
    try t.addRow(.{ "With Isolate", dur1, res1.alloc_nb, res1.realloc_nb, size1 });
    try t.addRow(.{ "Without Isolate", dur2, res2.alloc_nb, res2.realloc_nb, size2 });
    const out = std.io.getStdOut().writer();
    try t.render(out);
}
