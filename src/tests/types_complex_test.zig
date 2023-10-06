const std = @import("std");

const public = @import("../api.zig");
const tests = public.test_utils;
const MyIterable = public.Iterable(u8);
const Variadic = public.Variadic;

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

const MyVariadic = struct {
    member: u8,

    const VariadicBool = Variadic(bool);

    pub fn constructor() MyVariadic {
        return .{ .member = 0 };
    }

    pub fn _len(_: MyVariadic, variadic: ?VariadicBool) u64 {
        return @as(u64, variadic.?.slice.len);
    }

    pub fn _first(_: MyVariadic, _: []const u8, variadic: ?VariadicBool) bool {
        return variadic.?.slice[0];
    }

    pub fn _last(_: MyVariadic, _: std.mem.Allocator, variadic: ?VariadicBool) bool {
        return variadic.?.slice[variadic.?.slice.len - 1];
    }

    pub fn _empty(_: MyVariadic, _: ?VariadicBool) bool {
        return true;
    }
};

// generate API, comptime
pub fn generate() []public.API {
    return public.compile(.{ MyIterable, MyList, MyVariadic });
}

// exec tests
pub fn exec(
    _: std.mem.Allocator,
    js_env: *public.Env,
    comptime apis: []public.API,
) !void {

    // start JS env
    js_env.start(apis);
    defer js_env.stop();

    var iter = [_]tests.Case{
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
    try tests.checkCases(js_env, &iter);

    var variadic = [_]tests.Case{
        .{ .src = "let myVariadic = new MyVariadic();", .ex = "undefined" },
        .{ .src = "myVariadic.len(true, false, true)", .ex = "3" },
        .{ .src = "myVariadic.first('a_str', true, false, true, false)", .ex = "true" },
        .{ .src = "myVariadic.last(true, false)", .ex = "false" },
        .{ .src = "myVariadic.empty()", .ex = "true" },
    };
    try tests.checkCases(js_env, &variadic);
}
