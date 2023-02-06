const std = @import("std");

const v8 = @import("v8");

const jsruntime = @import("../jsruntime.zig");
const utils = @import("../utils.zig");

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
    std.os.nanosleep(s, ns);
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

pub fn checkCases(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
    cases: []Case,
) !void {
    var has_error = false;

    for (cases) |case, i| {
        test_case += 1;

        // try cache
        var try_catch: v8.TryCatch = undefined;
        try_catch.init(js_env.isolate);
        defer try_catch.deinit();

        // execute script
        var buf: [99]u8 = undefined;
        const name = try std.fmt.bufPrint(buf[0..], "test_{d}.js", .{test_case});
        const res = try js_env.exec(alloc, case.src, name, try_catch);
        defer res.deinit(alloc);

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

        // callback
        var cbk_res = jsruntime.JSResult{
            .success = true,
            // assume that the return value of the successfull callback is "undefined"
            .result = "undefined",
        };
        var cbk_alloc = false;

        // loop until all JS callbacks are done,
        // blocking operation
        js_env.loop.run() catch {
            cbk_res.success = false;
        };

        // check callback error
        var cbk_error = false;
        if (cbk_res.success) {
            const equal = std.mem.eql(u8, case.cbk_ex, cbk_res.result);
            if (!equal) {
                cbk_error = true;
            }
        } else {
            if (try_catch.hasCaught()) {

                // callback try catch
                cbk_alloc = true;
                const ctx = js_env.context.?;
                const except = try_catch.getException().?;
                cbk_res.result = try utils.valueToUtf8(alloc, except, js_env.isolate, ctx);
                const stack = try_catch.getStackTrace(ctx).?;
                cbk_res.stack = try utils.valueToUtf8(alloc, stack, js_env.isolate, ctx);
                if (!isTypeError(case.cbk_ex, cbk_res.result)) {
                    cbk_error = true;
                }
            } else {
                cbk_error = true;
                cbk_res.result = "IO kernel error";
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
        if (cbk_alloc) {
            cbk_res.deinit(alloc);
        }
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
