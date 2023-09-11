const std = @import("std");

const public = @import("../api.zig");

const js_response_size = 200;

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
    js_env: *public.Env,
    cases: []Case,
) !void {
    var has_error = false;

    // res buf
    var res_buf: [js_response_size]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&res_buf);
    const fba_alloc = fba.allocator();

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

        try js_env.run(fba_alloc, case.src, name, &res, &cbk_res);

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

        fba.reset();
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
