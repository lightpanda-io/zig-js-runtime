const std = @import("std");

const jsruntime = @import("jsruntime.zig");
const eng = @import("engine.zig");

const bench = @import("bench.zig");
const pretty = @import("pretty.zig");

const proto = @import("tests/proto_test.zig");

const kb = 1024;
const us = std.time.ns_per_us;

fn benchWithIsolate(
    alloc: std.mem.Allocator,
    comptime ctxExecFn: jsruntime.ContextExecFn,
    comptime apis: []jsruntime.API,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !bench.Result {
    var ba = bench.allocator(alloc);
    const duration = try bench.call(
        jsruntime.loadEnv,
        .{ ba.allocator(), true, ctxExecFn, apis },
        iter,
        warmup,
    );
    const alloc_stats = ba.stats();
    return bench.Result{
        .duration = duration,
        .alloc_nb = alloc_stats.alloc_nb,
        .realloc_nb = alloc_stats.realloc_nb,
        .alloc_size = alloc_stats.alloc_size,
    };
}

var duration_global: u64 = undefined;

fn benchWithoutIsolate(
    alloc: std.mem.Allocator,
    comptime ctxExecFn: jsruntime.ContextExecFn,
    comptime apis: []jsruntime.API,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !bench.Result {
    var ba = bench.allocator(alloc);
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
    try eng.loadEnv(ba.allocator(), true, s.do, apis);
    const alloc_stats = ba.stats();
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
    var gpa1 = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa1.deinit();
    var alloc1 = std.heap.ArenaAllocator.init(gpa1.allocator());
    defer alloc1.deinit();
    var gpa2 = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa2.deinit();
    var alloc2 = std.heap.ArenaAllocator.init(gpa2.allocator());
    defer alloc2.deinit();

    // benchmark conf
    const iter = 100;
    const warmup = iter / 20;
    const title_fmt = "Benchmark jsengine 🚀 (~= {d} iters)";
    var buf: [100]u8 = undefined;
    const title = try std.fmt.bufPrint(buf[0..], title_fmt, .{iter});

    // benchmark funcs
    const res1 = try benchWithIsolate(alloc1.allocator(), proto.exec, apis, iter, warmup);
    const res2 = try benchWithoutIsolate(alloc2.allocator(), proto.exec, apis, iter, warmup);

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
        pretty.Measure,
    };
    const table = try pretty.GenerateTable(2, row_shape, pretty.TableConf{ .margin_left = "  " });
    const header = .{
        "FUNCTION",
        "DURATION (per iter)",
        "ALLOCATIONS (nb)",
        "HEAP SIZE",
    };
    var t = table.init(title, header);
    try t.addRow(.{ "With Isolate", dur1, res1.alloc_nb, size1 });
    try t.addRow(.{ "Without Isolate", dur2, res2.alloc_nb, size2 });
    const out = std.io.getStdOut().writer();
    try t.render(out);
}
