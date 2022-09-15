const std = @import("std");
const engine = @import("main.zig");
const utils = @import("utils.zig");

test "basic" {
    // allocator
    const alloc = std.testing.allocator;

    // javascript script
    const script = engine.Script{
        .origin = "main.js",
        .content = 
        \\let p = new Person(40);
        \\p.age === 40;
        ,
    };

    // javascript exec
    var res: utils.ExecuteResult = undefined;
    defer res.deinit();
    engine.jsExecScript(alloc, script, &res);

    // javascript result
    if (!res.success) {
        std.log.err("\n{s}", .{res.err.?});
    }
    try std.testing.expect(res.success);
}
