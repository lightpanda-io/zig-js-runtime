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

    pub fn deinit(self: *MyList, alloc: std.mem.Allocator) void {
        alloc.free(self.items);
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

    const VariadicList = Variadic(MyList);

    pub fn _myListLen(_: MyVariadic, variadic: ?VariadicList) u8 {
        return @as(u8, @intCast(variadic.?.slice.len));
    }

    pub fn _myListFirst(_: MyVariadic, variadic: ?VariadicList) ?u8 {
        if (variadic.?.slice.len == 0) return null;
        return variadic.?.slice[0]._first();
    }

    pub fn deinit(_: *MyVariadic, _: std.mem.Allocator) void {}
};

const MyErrorUnion = struct {
    pub fn constructor(is_err: bool) !MyErrorUnion {
        if (is_err) return error.MyError;
        return .{};
    }

    pub fn get_withoutError(_: MyErrorUnion) !u8 {
        return 0;
    }

    pub fn get_withError(_: MyErrorUnion) !u8 {
        return error.MyError;
    }

    pub fn set_withoutError(_: *MyErrorUnion, _: bool) !void {}

    pub fn set_withError(_: *MyErrorUnion, _: bool) !void {
        return error.MyError;
    }

    pub fn _funcWithoutError(_: MyErrorUnion) !void {}

    pub fn _funcWithError(_: MyErrorUnion) !void {
        return error.MyError;
    }
};

pub const MyException = struct {
    err: ErrorSet,

    const errorNames = [_][]const u8{
        "MyCustomError",
    };
    const errorMsgs = [_][]const u8{
        "Some custom message.",
    };
    fn errorStrings(comptime i: usize) []const u8 {
        return errorNames[0] ++ ": " ++ errorMsgs[i];
    }

    // interface definition

    pub const ErrorSet = error{
        MyCustomError,
    };

    pub fn init(_: std.mem.Allocator, err: anyerror, _: []const u8) anyerror!MyException {
        return .{ .err = @as(ErrorSet, @errorCast(err)) };
    }

    pub fn get_name(self: MyException) []const u8 {
        return switch (self.err) {
            ErrorSet.MyCustomError => errorNames[0],
        };
    }

    pub fn get_message(self: MyException) []const u8 {
        return switch (self.err) {
            ErrorSet.MyCustomError => errorMsgs[0],
        };
    }

    pub fn _toString(self: MyException) []const u8 {
        return switch (self.err) {
            ErrorSet.MyCustomError => errorStrings(0),
        };
    }

    pub fn deinit(_: *MyException, _: std.mem.Allocator) void {}
};

const MyTypeWithException = struct {
    pub const Exception = MyException;

    pub fn constructor() MyTypeWithException {
        return .{};
    }

    pub fn _withoutError(_: MyTypeWithException) MyException.ErrorSet!void {}

    pub fn _withError(_: MyTypeWithException) MyException.ErrorSet!void {
        return MyException.ErrorSet.MyCustomError;
    }

    pub fn _superSetError(_: MyTypeWithException) !void {
        return MyException.ErrorSet.MyCustomError;
    }

    pub fn _outOfMemory(_: MyTypeWithException) !void {
        return error.OutOfMemory;
    }
};

pub const Types = .{
    MyIterable,
    MyList,
    MyVariadic,
    MyErrorUnion,
    MyException,
    MyTypeWithException,
};

// exec tests
pub fn exec(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
) anyerror!void {

    // start JS env
    try js_env.start(alloc);
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
        .{ .src = "myVariadic.myListLen(myList)", .ex = "1" },
        .{ .src = "myVariadic.myListFirst(myList)", .ex = "1" },
    };
    try tests.checkCases(js_env, &variadic);

    var error_union = [_]tests.Case{
        .{ .src = "var myErrorCstr = ''; try {new MyErrorUnion(true)} catch (error) {myErrorCstr = error}; myErrorCstr", .ex = "Error: MyError" },
        .{ .src = "let myErrorUnion = new MyErrorUnion(false);", .ex = "undefined" },
        .{ .src = "myErrorUnion.withoutError", .ex = "0" },
        .{ .src = "var myErrorGetter = ''; try {myErrorUnion.withError} catch (error) {myErrorGetter = error}; myErrorGetter", .ex = "Error: MyError" },
        .{ .src = "myErrorUnion.withoutError = true", .ex = "true" },
        .{ .src = "var myErrorSetter = ''; try {myErrorUnion.withError = true} catch (error) {myErrorSetter = error}; myErrorSetter", .ex = "Error: MyError" },
        .{ .src = "myErrorUnion.funcWithoutError()", .ex = "undefined" },
        .{ .src = "var myErrorFunc = ''; try {myErrorUnion.funcWithError()} catch (error) {myErrorFunc = error}; myErrorFunc", .ex = "Error: MyError" },
    };
    try tests.checkCases(js_env, &error_union);

    var exception = [_]tests.Case{
        .{ .src = "MyException.prototype.__proto__ === Error.prototype", .ex = "true" },
        .{ .src = "let myTypeWithException = new MyTypeWithException();", .ex = "undefined" },
        .{ .src = "myTypeWithException.withoutError()", .ex = "undefined" },
        .{ .src = "var myCustomError = ''; try {myTypeWithException.withError()} catch (error) {myCustomError = error}", .ex = "MyCustomError: Some custom message." },
        .{ .src = "myCustomError instanceof MyException", .ex = "true" },
        .{ .src = "myCustomError instanceof Error", .ex = "true" },
        .{ .src = "var mySuperError = ''; try {myTypeWithException.superSetError()} catch (error) {mySuperError = error}", .ex = "MyCustomError: Some custom message." },
        .{ .src = "var oomError = ''; try {myTypeWithException.outOfMemory()} catch (error) {oomError = error}; oomError", .ex = "Error: OutOfMemory" },
    };
    try tests.checkCases(js_env, &exception);
}
