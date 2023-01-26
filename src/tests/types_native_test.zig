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

    pub fn set_name(self: *Brand, name: []u8) void {
        self.name = name;
    }
};

const Car = struct {
    brand: Brand,
    brand_ptr: *Brand,

    pub fn constructor() Car {
        var brand_name: []const u8 = "Renault";
        const brand = Brand{ .name = brand_name };
        var brand_ptr = utils.allocator.create(Brand) catch unreachable;
        brand_ptr.* = Brand{ .name = brand_name };
        return .{ .brand = brand, .brand_ptr = brand_ptr };
    }

    // return <Struct> as getter
    pub fn get_brand(self: Car) Brand {
        return self.brand;
    }

    // return *<Struct> as getter
    pub fn get_brandPtr(self: Car) *Brand {
        // var brand = utils.allocator.create(Brand) catch unreachable;
        // brand.* = self.brand;
        return self.brand_ptr;
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

    const cases = [_]tests.Case{
        .{ .src = "let car = new Car();", .ex = "undefined" },

        // basic tests for getter
        .{ .src = "let brand1 = car.brand", .ex = "undefined" },
        .{ .src = "brand1.name", .ex = "Renault" },
        .{ .src = "let brand1Ptr = car.brandPtr", .ex = "undefined" },
        .{ .src = "brand1Ptr.name", .ex = "Renault" },

        // basic test for method
        .{ .src = "let brand2 = car.getBrand()", .ex = "undefined" },
        .{ .src = "brand2.name", .ex = "Renault" },
        .{ .src = "let brand2Ptr = car.getBrandPtr()", .ex = "undefined" },
        .{ .src = "brand2Ptr.name", .ex = "Renault" },

        // successive calls for getter value
        // check the set of a new name on brand1 (value) has no impact
        .{ .src = "brand1.name = 'Peugot'", .ex = "Peugot" },
        .{ .src = "let brand1_again = car.brand", .ex = "undefined" },
        .{ .src = "brand1_again.name", .ex = "Renault" },
        // check the set of a new name on brand1Ptr (pointer) has impact
        // ie. successive calls return the same pointer
        .{ .src = "brand1Ptr.name = 'Peugot'", .ex = "Peugot" },
        .{ .src = "let brand1Ptr_again = car.brandPtr", .ex = "undefined" },
        .{ .src = "brand1Ptr_again.name", .ex = "Peugot" },
        // and check back the set of a new name on brand1Ptr_agin in brand1Ptr
        .{ .src = "brand1Ptr_again.name = 'Citroën'", .ex = "Citroën" },
        .{ .src = "brand1Ptr.name", .ex = "Citroën" },
    };
    try tests.checkCases(loop, utils.allocator, isolate, context, cases.len, cases);

    return eng.ExecOK;
}
