const std = @import("std");

const tests = @import("run_tests.zig");

pub const Types = tests.Types;
pub const UserContext = tests.UserContext;

pub fn main() !void {
    try tests.main();
}
