// Copyright 2023-2024 Lightpanda (Selecy SAS)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

const public = @import("../api.zig");
const tests = public.test_utils;

pub const Other = struct {
    val: u8,

    fn init(val: u8) Other {
        return .{ .val = val };
    }

    pub fn _val(self: Other) u8 {
        return self.val;
    }
};

pub const OtherUnion = union(enum) {
    Other: Other,
    Bool: bool,
};

pub const MyObject = struct {
    val: bool,

    pub fn constructor(do_set: bool) MyObject {
        return .{ .val = do_set };
    }

    pub fn postAttach(self: *MyObject, js_obj: public.JSObject, _: std.mem.Allocator) !void {
        if (self.val) try js_obj.set("a", @as(u8, 1));
    }

    pub fn get_val(self: MyObject) bool {
        return self.val;
    }

    pub fn set_val(self: *MyObject, val: bool) void {
        self.val = val;
    }

    pub fn _other(_: MyObject, js_obj: public.JSObject, val: u8) !void {
        try js_obj.set("b", Other{ .val = val });
    }

    pub fn _otherUnion(_: MyObject, js_obj: public.JSObject, val: ?u8) !void {
        if (val) |v| {
            const other = Other{ .val = v };
            try js_obj.set("c", OtherUnion{ .Other = other });
        } else {
            try js_obj.set("d", OtherUnion{ .Bool = true });
        }
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

pub const Types = .{
    Other,
    MyObject,
    MyAPI,
};

// exec tests
pub fn exec(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
) anyerror!void {

    // start JS env
    try js_env.start();
    defer js_env.stop();

    // const o = Other{ .val = 4 };
    // try js_env.addObject(apis, o, "other");

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
        // setting a user-defined object
        .{ .src = "myObj.other(3)", .ex = "undefined" },
        .{ .src = "myObj.b.__proto__ === Other.prototype", .ex = "true" },
        .{ .src = "myObj.b.val()", .ex = "3" },
        // setting an union
        .{ .src = "myObj.otherUnion(4)", .ex = "undefined" },
        .{ .src = "myObj.c.__proto__ === Other.prototype", .ex = "true" },
        .{ .src = "myObj.c.val()", .ex = "4" },
        .{ .src = "myObj.otherUnion()", .ex = "undefined" },
        .{ .src = "myObj.d", .ex = "true" },
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
