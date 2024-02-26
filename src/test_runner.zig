const std = @import("std");

const tests = @import("run_tests.zig");

pub const Types = tests.Types;
pub const GlobalType = tests.GlobalType;

pub fn main() !void {
    try tests.main();
}
