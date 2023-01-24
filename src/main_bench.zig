const std = @import("std");

const v8 = @import("v8");

const eng = @import("engine.zig");
const gen = @import("generate.zig");
const Loop = @import("loop.zig").SingleThreaded;

const bench = @import("bench.zig");
const pretty = @import("pretty.zig");

const proto = @import("proto_test.zig");

const kb = 1024;
const us = std.time.ns_per_us;

fn benchWithIsolate(
    alloc: std.mem.Allocator,
    comptime execFn: eng.ExecFunc,
    comptime apis: []gen.API,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !bench.Result {
    var ba = bench.allocator(alloc);
    const duration = try bench.call(
        eng.Load,
        .{ ba.allocator(), true, execFn, apis },
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

fn benchWithoutIsolate(
    alloc: std.mem.Allocator,
    comptime execFn: eng.ExecFunc,
    comptime apis: []gen.API,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !bench.Result {
    var ba = bench.allocator(alloc);
    const s = struct {
        fn do(
            loop: *Loop,
            isolate: v8.Isolate,
            globals: v8.ObjectTemplate,
            tpls: []gen.ProtoTpl,
            comptime apis_scoped: []gen.API,
        ) !eng.ExecRes {
            const t = try bench.call(
                execFn,
                .{ loop, isolate, globals, tpls, apis_scoped },
                iter,
                warmup,
            );
            return eng.ExecRes{ .Time = t };
        }
    };
    const res = try eng.Load(ba.allocator(), true, s.do, apis);
    const alloc_stats = ba.stats();
    return bench.Result{
        .duration = res.Time,
        .alloc_nb = alloc_stats.alloc_nb,
        .realloc_nb = alloc_stats.realloc_nb,
        .alloc_size = alloc_stats.alloc_size,
    };
}

pub fn main() !void {

    // benchmark conf
    const iter = 100;
    const warmup = iter / 20;
    const title_fmt = "Benchmark jsengine 🚀 (~= {d} iters)";
    var buf: [100]u8 = undefined;
    const title = try std.fmt.bufPrint(buf[0..], title_fmt, .{iter});

    // create v8 vm
    const vm = eng.VM.init();
    defer vm.deinit();

    // generate APIs
    const apis = comptime proto.generate(); // stage1: we need comptime

    // allocators
    var gpa1 = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa1.deinit();
    var alloc1 = std.heap.ArenaAllocator.init(gpa1.allocator());
    defer alloc1.deinit();
    var gpa2 = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa2.deinit();
    var alloc2 = std.heap.ArenaAllocator.init(gpa2.allocator());
    defer alloc2.deinit();

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
