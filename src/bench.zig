const std = @import("std");
const v8 = @import("v8");

const eng = @import("engine.zig");
const gen = @import("generate.zig");

fn bench(comptime iter: comptime_int, comptime func_name: []const u8, func: anytype, args: anytype) !void {
    var total: u64 = 0;
    var i: usize = 0;
    const warmup = @as(u32, iter * 0.95); // 5% of warmup

    while (i < iter) {
        const start = try std.time.Instant.now();

        // do funcs
        try @call(.{}, func, args);

        const end = try std.time.Instant.now();
        if (i < warmup) {
            const elapsed = std.time.Instant.since(end, start);
            total += elapsed;
        }
        i += 1;
    }

    const mean = total / iter / std.time.ns_per_us;
    std.debug.print("{s}\t(~= of {d} iters)\t{d}us\n", .{ func_name, iter, mean });
}

pub fn withIsolate(comptime iter: comptime_int, comptime execFn: eng.ExecFunc, comptime apis: []gen.API) !void {
    return bench(iter, "with Isolate", eng.Load, .{ execFn, apis });
}

pub fn withoutIsolate(comptime iter: comptime_int, comptime execFn: eng.ExecFunc, comptime apis: []gen.API) !void {
    const s = struct {
        fn do(isolate: v8.Isolate, globals: v8.ObjectTemplate) !void {
            return bench(iter, "without Isolate", execFn, .{ isolate, globals });
        }
    };
    return eng.Load(s.do, apis);
}
