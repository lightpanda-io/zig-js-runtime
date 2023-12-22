const std = @import("std");

const tests = @import("run_tests.zig");

pub fn main() !void {
    try tests.main();
}
