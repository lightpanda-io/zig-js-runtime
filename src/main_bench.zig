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
const io = @import("std").io;

const public = @import("api.zig");

const bench = @import("bench.zig");
const pretty = @import("pretty.zig");

const proto = @import("tests/proto_test.zig");

const kb = 1024;
const us = std.time.ns_per_us;

pub const Types = public.reflect(proto.Types);

fn benchWithIsolate(
    bench_alloc: *bench.Allocator,
    arena_alloc: *std.heap.ArenaAllocator,
    comptime ctxExecFn: public.ContextExecFn,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !bench.Result {
    const duration = try bench.call(
        public.loadEnv,
        .{ arena_alloc, null, ctxExecFn },
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
    comptime ctxExecFn: public.ContextExecFn,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !bench.Result {
    const s = struct {
        fn do(
            alloc_func: std.mem.Allocator,
            js_env: *public.Env,
        ) anyerror!void {
            const duration = try bench.call(
                ctxExecFn,
                .{ alloc_func, js_env },
                iter,
                warmup,
            );
            duration_global = duration;
        }
    };
    try public.loadEnv(arena_alloc, null, s.do);
    const alloc_stats = bench_alloc.stats();
    return bench.Result{
        .duration = duration_global,
        .alloc_nb = alloc_stats.alloc_nb,
        .realloc_nb = alloc_stats.realloc_nb,
        .alloc_size = alloc_stats.alloc_size,
    };
}

const usage =
    \\usage: {s} [options]
    \\  Run and display a jsruntime benchmark.
    \\
    \\  -h, --help       Print this help message and exit.
    \\  --json           result is formatted in JSON.
    \\
;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // get the exec name.
    const execname = args.next().?;

    var json = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try io.getStdErr().writer().print(usage, .{execname});
            std.posix.exit(0);
        } else if (std.mem.eql(u8, "--json", arg)) {
            json = true;
        }
    }

    // create JS vm
    const vm = public.VM.init();
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
    const res1 = try benchWithIsolate(&bench1, &arena1, proto.exec, iter, warmup);
    const res2 = try benchWithoutIsolate(&bench2, &arena2, proto.exec, iter, warmup);

    // generate a json output with the bench result.
    if (json) {
        const res = [_]struct {
            name: []const u8,
            bench: bench.Result,
        }{
            .{ .name = "With Isolate", .bench = res1 },
            .{ .name = "Without Isolate", .bench = res2 },
        };

        try std.json.stringify(res, .{ .whitespace = .indent_2 }, io.getStdOut().writer());
        std.posix.exit(0);
    }

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
