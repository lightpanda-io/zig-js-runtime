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

const public = @import("../api.zig");

const js_response_size = 220;

fn isTypeError(expected: []const u8, msg: []const u8) bool {
    if (!std.mem.eql(u8, expected, "TypeError")) {
        return false;
    }
    if (std.mem.startsWith(u8, msg, "Uncaught TypeError: ")) {
        return true;
    }
    if (std.mem.startsWith(u8, msg, "TypeError: ")) {
        // TODO: why callback exception does not start with "Uncaught"?
        return true;
    }
    return false;
}

pub fn sleep(nanoseconds: u64) void {
    const s = nanoseconds / std.time.ns_per_s;
    const ns = nanoseconds % std.time.ns_per_s;
    std.posix.nanosleep(s, ns);
}

// result memory is owned by the caller
pub fn intToStr(alloc: std.mem.Allocator, nb: u8) []const u8 {
    return std.fmt.allocPrint(
        alloc,
        "{d}",
        .{nb},
    ) catch unreachable;
}

// engineOwnPropertiesDefault returns the number of own properties
// by default for a current Type
// result memory is owned by the caller
pub fn engineOwnPropertiesDefault() u8 {
    return switch (public.Env.engine()) {
        .v8 => 5,
    };
}

var test_case: usize = 0;

fn caseError(src: []const u8, exp: []const u8, res: []const u8, stack: ?[]const u8) void {
    std.debug.print("\n\tcase: ", .{});
    std.debug.print("\t\t{s}\n", .{src});
    std.debug.print("\texpected: ", .{});
    std.debug.print("\t{s}\n", .{exp});
    std.debug.print("\tactual: ", .{});
    std.debug.print("\t{s}\n", .{res});
    if (stack != null) {
        std.debug.print("\tstack: \n{s}\n", .{stack.?});
    }
}

pub fn checkCases(js_env: *public.Env, cases: []Case) !void {
    // res buf
    var res_buf: [js_response_size]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&res_buf);
    const fba_alloc = fba.allocator();

    try checkCasesAlloc(fba_alloc, js_env, cases);
}

pub fn checkCasesAlloc(allocator: std.mem.Allocator, js_env: *public.Env, cases: []Case) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const alloc = arena.allocator();
    defer arena.deinit();

    var has_error = false;

    // cases
    for (cases, 0..) |case, i| {
        test_case += 1;

        // prepare script execution
        var buf: [99]u8 = undefined;
        const name = try std.fmt.bufPrint(buf[0..], "test_{d}.js", .{test_case});
        var res = public.JSResult{};
        var cbk_res = public.JSResult{
            .success = true,
            // assume that the return value of the successfull callback is "undefined"
            .result = "undefined",
        };
        // no need to deinit on a FixBufferAllocator

        try js_env.run(alloc, case.src, name, &res, &cbk_res);

        // check script error
        var case_error = false;
        if (res.success) {
            const equal = std.mem.eql(u8, case.ex, res.result);
            if (!equal) {
                case_error = true;
            }
        } else {
            if (!isTypeError(case.ex, res.result)) {
                case_error = true;
            }
        }

        // check callback error
        var cbk_error = false;
        if (cbk_res.success) {
            const equal = std.mem.eql(u8, case.cbk_ex, cbk_res.result);
            if (!equal) {
                cbk_error = true;
            }
        } else {
            if (!isTypeError(case.cbk_ex, cbk_res.result)) {
                cbk_error = true;
            }
        }

        // log error
        if (case_error or cbk_error) {
            has_error = true;
            if (i == 0) {
                std.debug.print("\n", .{});
            }
        }
        if (case_error) {
            caseError(case.src, case.ex, res.result, res.stack);
        } else if (cbk_error) {
            caseError(case.src, case.cbk_ex, cbk_res.result, cbk_res.stack);
        }

        _ = arena.reset(.retain_capacity);
    }

    if (has_error) {
        std.debug.print("\n", .{});
        return error.NotEqual;
    }
}

pub const Case = struct {
    src: []const u8,
    ex: []const u8,
    cbk_ex: []const u8 = "undefined",
};

// a shorthand function to run a script within a JS env
// without providing a JS result
// - on success, do nothing
// - on error, log error the JS result and JS stack if available
pub fn runScript(
    js_env: *public.Env,
    alloc: std.mem.Allocator,
    script: []const u8,
    name: []const u8,
) !void {

    // init result
    var res = public.JSResult{};
    defer res.deinit(alloc);

    try js_env.run(alloc, script, name, &res, null);

    // check result
    if (!res.success) {
        std.log.err("script {s} error: {s}\n", .{ name, res.result });
        if (res.stack) |stack| {
            std.log.err("script {s} stack: {s}\n", .{ name, stack });
        }
        return error.Script;
    }
}
