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
const builtin = @import("builtin");

const internal = @import("internal_api.zig");
const refs = internal.refs;
const gen = internal.gen;
const refl = internal.refl;
const NativeContext = internal.NativeContext;

const public = @import("api.zig");
const Env = public.Env;
const Loop = public.Loop;
const UserContext = public.UserContext;

pub const ContextExecFn = (fn (std.mem.Allocator, *Env) anyerror!void);

pub fn loadEnv(
    arena_alloc: *std.heap.ArenaAllocator,
    userctx: ?UserContext,
    comptime ctxExecFn: ContextExecFn,
) !void {
    const alloc = arena_alloc.allocator();

    // create JS env
    var start: std.time.Instant = undefined;
    if (builtin.is_test) {
        start = try std.time.Instant.now();
    }
    var loop = try Loop.init(alloc);
    defer loop.deinit();
    var js_env = try Env.init(alloc, &loop, userctx);
    defer js_env.deinit();

    // load APIs in JS env
    var load_start: std.time.Instant = undefined;
    if (builtin.is_test) {
        load_start = try std.time.Instant.now();
    }
    var js_types: [gen.Types.len]usize = undefined;
    try js_env.load(&js_types);

    // execute JS function
    var exec_start: std.time.Instant = undefined;
    if (builtin.is_test) {
        exec_start = try std.time.Instant.now();
    }
    try ctxExecFn(alloc, &js_env);

    // Stats
    // -----

    var exec_end: std.time.Instant = undefined;
    if (builtin.is_test) {
        exec_end = try std.time.Instant.now();
    }

    if (builtin.is_test) {
        const us = std.time.ns_per_us;

        const create_time = std.time.Instant.since(load_start, start);
        const load_time = std.time.Instant.since(exec_start, load_start);
        const exec_time = std.time.Instant.since(exec_end, exec_start);
        const total_time = std.time.Instant.since(exec_end, start);

        const create_per = create_time * 100 / total_time;
        const load_per = load_time * 100 / total_time;
        const exec_per = exec_time * 100 / total_time;

        std.debug.print("\ncreation of env:\t{d}us\t{d}%\n", .{ create_time / us, create_per });
        std.debug.print("load of apis:\t\t{d}us\t{d}%\n", .{ load_time / us, load_per });
        std.debug.print("exec:\t\t\t{d}us\t{d}%\n", .{ exec_time / us, exec_per });
        std.debug.print("Total:\t\t\t{d}us\n", .{total_time / us});
    }
}
