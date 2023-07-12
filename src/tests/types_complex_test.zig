const std = @import("std");

const jsruntime = @import("../jsruntime.zig");

const tests = jsruntime.test_utils;

const MyIterable = jsruntime.Iterable(u8);

const MyList = struct {
    items: []u8,

    pub fn constructor(alloc: std.mem.Allocator, elem1: u8, elem2: u8, elem3: u8) MyList {
        var items = alloc.alloc(u8, 3) catch unreachable;
        items[0] = elem1;
        items[1] = elem2;
        items[2] = elem3;
        return .{ .items = items };
    }

    pub fn _first(self: MyList) u8 {
        return self.items[0];
    }

    pub fn _symbol_iterator(self: MyList) MyIterable {
        return MyIterable.init(self.items);
    }
};

// generate API, comptime
pub fn generate() []jsruntime.API {
    return jsruntime.compile(.{ MyList, MyIterable });
}

// exec tests
pub fn exec(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime apis: []jsruntime.API,
) !void {

    // start JS env
    js_env.start(apis);
    defer js_env.stop();

    var cases = [_]tests.Case{
        .{ .src = "let myList = new MyList(1, 2, 3);", .ex = "undefined" },
        .{ .src = "myList.first();", .ex = "1" },
        .{ .src = "let iter = myList[Symbol.iterator]();", .ex = "undefined" },
        .{ .src = "iter.next().value;", .ex = "1" },
        .{ .src = "iter.next().value;", .ex = "2" },
        .{ .src = "iter.next().value;", .ex = "3" },
        .{ .src = "iter.next().done;", .ex = "true" },
        .{ .src = "let arr = Array.from(myList);", .ex = "undefined" },
        .{ .src = "arr.length;", .ex = "3" },
        .{ .src = "arr[0];", .ex = "1" },
    };
    try tests.checkCases(js_env, &cases);
}
