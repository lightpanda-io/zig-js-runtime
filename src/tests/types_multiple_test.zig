const std = @import("std");

const public = @import("../api.zig");
const tests = public.test_utils;

const Windows = struct {
    const manufacturer = "Microsoft";

    pub fn get_manufacturer(_: Windows) []const u8 {
        return manufacturer;
    }
};

const MacOS = struct {
    const manufacturer = "Apple";

    pub fn get_manufacturer(_: MacOS) []const u8 {
        return manufacturer;
    }
};

const Linux = struct {
    const manufacturer = "Linux Foundation";

    pub fn get_manufacturer(_: Linux) []const u8 {
        return manufacturer;
    }
};

const OSTag = enum {
    windows,
    macos,
    linux,
};

const OS = union(OSTag) {
    windows: Windows,
    macos: MacOS,
    linux: Linux,
};

const Computer = struct {
    os: OS,

    pub fn constructor(os_name: []u8) Computer {
        var os: OS = undefined;
        if (std.mem.eql(u8, os_name, "macos")) {
            os = OS{ .macos = MacOS{} };
        } else if (std.mem.eql(u8, os_name, "linux")) {
            os = OS{ .linux = Linux{} };
        } else {
            os = OS{ .windows = Windows{} };
        }
        return .{ .os = os };
    }

    pub fn get_os(self: Computer) OS {
        return self.os;
    }
};

// generate API, comptime
pub fn generate() []public.API {
    return public.compile(.{ Windows, MacOS, Linux, Computer });
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

    var cases = [_]tests.Case{
        .{ .src = "let linux_computer = new Computer('linux');", .ex = "undefined" },
        .{ .src = "let os = linux_computer.os;", .ex = "undefined" },
        .{ .src = "os.manufacturer", .ex = "Linux Foundation" },
    };
    try tests.checkCases(js_env, &cases);
}
