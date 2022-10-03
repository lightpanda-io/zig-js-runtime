const std = @import("std");
const v8 = @import("v8");

const engine = @import("engine.zig");

fn isTypeError(expected: []const u8, msg: []const u8) bool {
    if (!std.mem.eql(u8, expected, "TypeError")) {
        return false;
    }
    return std.mem.startsWith(u8, msg, "Uncaught TypeError: ");
}

pub fn checkCases(alloc: std.mem.Allocator, isolate: v8.Isolate, context: v8.Context, comptime n: comptime_int, cases: [n]Case) !void {
    var has_error = false;
    for (cases) |case, i| {
        const res = engine.jsExecScript(alloc, isolate, context, case.src, "test.js");
        defer res.deinit();
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
        if (case_error) {
            if (!has_error) {
                has_error = true;
            }
            if (i == 0) {
                std.debug.print("\n", .{});
            }
            std.debug.print("\n\tcase: ", .{});
            std.debug.print("\t\t{s}\n", .{case.src});
            std.debug.print("\texpected: ", .{});
            std.debug.print("\t{s}\n", .{case.ex});
            std.debug.print("\tactual: ", .{});
            std.debug.print("\t{s}\n", .{res.result});
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
};
