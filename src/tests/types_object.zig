const std = @import("std");

const public = @import("../api.zig");
const tests = public.test_utils;

pub const MyObject = struct {
    val: bool,

    pub fn constructor(do_set: bool) MyObject {
        return .{ .val = do_set };
    }

    pub fn postAttach(self: *MyObject, js_obj: public.JSObject) !void {
        if (self.val) try js_obj.set("a", @as(u8, 1));
    }

    pub fn get_val(self: MyObject) bool {
        return self.val;
    }

    pub fn set_val(self: *MyObject, val: bool) void {
        self.val = val;
    }
};

pub const MyAPI = struct {
    pub fn constructor() MyAPI {
        return .{};
    }

    pub fn _obj(_: MyAPI, _: public.JSObject) !MyObject {
        return MyObject.constructor(true);
    }
};

// generate API, comptime
pub fn generate() []public.API {
    return public.compile(.{
        MyObject,
        MyAPI,
    });
}

// exec tests
pub fn exec(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
    comptime apis: []public.API,
) !void {

    // start JS env
    try js_env.start(alloc, apis);
    defer js_env.stop();

    const ownBase = tests.engineOwnPropertiesDefault();
    const ownBaseStr = tests.intToStr(alloc, ownBase);
    defer alloc.free(ownBaseStr);

    var direct = [_]tests.Case{
        .{ .src = "Object.getOwnPropertyNames(MyObject).length;", .ex = ownBaseStr },
        .{ .src = "let myObj = new MyObject(true);", .ex = "undefined" },
        // check object property
        .{ .src = "myObj.a", .ex = "1" },
        .{ .src = "Object.getOwnPropertyNames(myObj).length;", .ex = "1" },
        // check if setter (pointer) still works
        .{ .src = "myObj.val", .ex = "true" },
        .{ .src = "myObj.val = false", .ex = "false" },
        .{ .src = "myObj.val", .ex = "false" },
        // check other object, same type, has no property
        .{ .src = "let myObj2 = new MyObject(false);", .ex = "undefined" },
        .{ .src = "myObj2.a", .ex = "undefined" },
        .{ .src = "Object.getOwnPropertyNames(myObj2).length;", .ex = "0" },
    };
    try tests.checkCases(js_env, &direct);

    var indirect = [_]tests.Case{
        .{ .src = "let myAPI = new MyAPI();", .ex = "undefined" },
        .{ .src = "let myObjIndirect = myAPI.obj();", .ex = "undefined" },
        // check object property
        .{ .src = "myObjIndirect.a", .ex = "1" },
        .{ .src = "Object.getOwnPropertyNames(myObjIndirect).length;", .ex = "1" },
    };
    try tests.checkCases(js_env, &indirect);
}