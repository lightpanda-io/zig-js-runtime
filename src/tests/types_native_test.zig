const std = @import("std");

const v8 = @import("v8");

const utils = @import("../utils.zig");
const gen = @import("../generate.zig");
const eng = @import("../engine.zig");
const Loop = @import("../loop.zig").SingleThreaded;

const tests = @import("test_utils.zig");

const Brand = struct {
    name: []const u8,

    pub fn get_name(self: Brand) []const u8 {
        return self.name;
    }
};

const Car = struct {
    brand: Brand,

    pub fn constructor() Car {
        var brand_name: []const u8 = "Renault";
        const brand = Brand{ .name = brand_name };
        return .{ .brand = brand };
    }

    // return <Struct> as getter
    pub fn get_brand(self: Car) Brand {
        return self.brand;
    }

    // return *<Struct> as getter
    pub fn get_brandPtr(self: Car) *Brand {
        var brand = utils.allocator.create(Brand) catch unreachable;
        brand.* = self.brand;
        return brand;
    }

    // return <Struct> as method
    pub fn _getBrand(self: Car) Brand {
        return self.get_brand();
    }

    // return *<Struct> as method
    pub fn _getBrandPtr(self: Car) *Brand {
        return self.get_brandPtr();
    }
};

// generate API, comptime
pub fn generate() []gen.API {
    return gen.compile(.{ Brand, Car });
}

// exec tests
pub fn exec(
    loop: *Loop,
    isolate: v8.Isolate,
    globals: v8.ObjectTemplate,
    _: []gen.ProtoTpl,
    comptime _: []gen.API,
) !eng.ExecRes {

    // create v8 context
    var context = v8.Context.init(isolate, globals, null);
    context.enter();
    defer context.exit();

    const res = "Renault";
    const cases = [_]tests.Case{
        .{ .src = "let car = new Car();", .ex = "undefined" },
        .{ .src = "car.brand.name", .ex = res },
        .{ .src = "car.brandPtr.name", .ex = res },
        .{ .src = "car.getBrand().name", .ex = res },
        .{ .src = "car.getBrandPtr().name", .ex = res },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases.len, cases);

    return eng.ExecOK;
}
