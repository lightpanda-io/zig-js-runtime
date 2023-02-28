const std = @import("std");

const jsruntime = @import("../jsruntime.zig");

const tests = jsruntime.test_utils;

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

    pub fn constructor(alloc: std.mem.Allocator) Car {
        var brand_name: []const u8 = "Renault";
        const brand = Brand{ .name = brand_name };
        var brand_ptr = alloc.create(Brand) catch unreachable;
        brand_ptr.* = Brand{ .name = brand_name };
        return .{ .brand = brand, .brand_ptr = brand_ptr };
    }

    // return <Struct> as getter
    pub fn get_brand(self: Car) Brand {
        return self.brand;
    }

    // return *<Struct> as getter
    pub fn get_brandPtr(self: Car) *Brand {
        return self.brand_ptr;
    }

    // return ?<Struct> as getter
    pub fn get_brandOpt(self: Car) ?Brand {
        return self.brand;
    }

    // return ?*<Struct> as getter
    pub fn get_brandPtrOpt(self: Car) ?*Brand {
        return self.brand_ptr;
    }

    // return ?<Struct> null as getter
    pub fn get_brandOptNull(_: Car) ?Brand {
        return null;
    }

    // return ?*<Struct> null as getter
    pub fn get_brandPtrOptNull(_: Car) ?*Brand {
        return null;
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

const Country = struct {
    stats: Stats,

    pub const Stats = struct {
        population: u32,
        pib: []const u8,
    };

    pub fn constructor(stats: Stats) Country {
        return .{ .stats = stats };
    }

    pub fn get_population(self: Country) u32 {
        return self.stats.population;
    }

    pub fn get_pib(self: Country) []const u8 {
        return self.stats.pib;
    }

    // optional
    pub fn _changeStats(self: *Country, stats: ?Stats) void {
        if (stats) |s| {
            self.stats = s;
        }
    }

    // pointer (ie. *Stats) is not supported by design
};

// generate API, comptime
pub fn generate() []jsruntime.API {
    return jsruntime.compile(.{ Brand, Car, Country });
}

// exec tests
pub fn exec(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
    comptime _: []jsruntime.API,
) !void {

    // start JS env
    js_env.start();
    defer js_env.stop();

    var native_arg = [_]tests.Case{
        .{ .src = "let stats = {'pib': '322Mds', 'population': 80}; let country = new Country(stats);", .ex = "undefined" },
        .{ .src = "country.population;", .ex = "80" },
        .{ .src = "let stats2 = {'pib': '342Mds', 'population': 80}; country.changeStats(stats2);", .ex = "undefined" },
        .{ .src = "country.pib;", .ex = "342Mds" },
    };
    try tests.checkCases(js_env, &native_arg);

    var cases = [_]tests.Case{
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

        // null test
        .{ .src = "let brand_opt = car.brandOpt", .ex = "undefined" },
        .{ .src = "brand_opt.name", .ex = "Renault" },
        .{ .src = "let brand_ptr_opt = car.brandPtrOpt", .ex = "undefined" },
        .{ .src = "brand_ptr_opt.name", .ex = "Citroën" },
        .{ .src = "car.brandOptNull", .ex = "null" },
        .{ .src = "car.brandPtrOptNull", .ex = "null" },
    };
    try tests.checkCases(js_env, &cases);
}
