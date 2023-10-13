const std = @import("std");

const public = @import("../api.zig");

const tests = public.test_utils;

// Native types with separate APIs
// -------------------------------

const Brand = struct {
    name: []const u8,

    pub fn constructor(name: []const u8) Brand {
        return .{ .name = name };
    }

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

    // As argument
    // -----------

    // accept <Struct> in setter
    pub fn set_brand(self: *Car, brand: Brand) void {
        self.brand = brand;
    }

    // accept *<Struct> in setter
    pub fn set_brandPtr(self: *Car, brand_ptr: *Brand) void {
        self.brand_ptr = brand_ptr;
    }

    // accept <Struct> in method
    pub fn _changeBrand(self: *Car, brand: Brand) void {
        self.brand = brand;
    }

    // accept *<Struct> in method
    pub fn _changeBrandPtr(self: *Car, brand_ptr: *Brand) void {
        self.brand_ptr = brand_ptr;
    }

    // accept ?<Struct> in method
    pub fn _changeBrandOpt(self: *Car, brand: ?Brand) void {
        if (brand != null) {
            self.brand = brand.?;
        }
    }

    // accept ?*<Struct> in method
    pub fn _changeBrandOptPtr(self: *Car, brand_ptr: ?*Brand) void {
        if (brand_ptr != null) {
            self.brand_ptr = brand_ptr.?;
        }
    }

    // As return value
    // ---------------

    // return <Struct> in getter
    pub fn get_brand(self: Car) Brand {
        return self.brand;
    }

    // return *<Struct> in getter
    pub fn get_brandPtr(self: Car) *Brand {
        return self.brand_ptr;
    }

    // return ?<Struct> in getter
    pub fn get_brandOpt(self: Car) ?Brand {
        return self.brand;
    }

    // return ?*<Struct> in getter
    pub fn get_brandPtrOpt(self: Car) ?*Brand {
        return self.brand_ptr;
    }

    // return ?<Struct> null in getter
    pub fn get_brandOptNull(_: Car) ?Brand {
        return null;
    }

    // return ?*<Struct> null in getter
    pub fn get_brandPtrOptNull(_: Car) ?*Brand {
        return null;
    }

    // return <Struct> in method
    pub fn _getBrand(self: Car) Brand {
        return self.get_brand();
    }

    // return *<Struct> in method
    pub fn _getBrandPtr(self: Car) *Brand {
        return self.get_brandPtr();
    }
};

// Native types with nested APIs
// -----------------------------

const Country = struct {
    stats: Stats,

    // Nested type
    // -----------
    // NOTE: Nested types are objects litterals only supported as function argument,
    // typically for Javascript options.
    pub const Stats = struct {
        population: ?u32,
        pib: []const u8,
    };

    // As argument
    // -----------

    // <NestedStruct> in method arg
    pub fn constructor(stats: Stats) Country {
        return .{ .stats = stats };
    }

    pub fn get_population(self: Country) ?u32 {
        return self.stats.population;
    }

    pub fn get_pib(self: Country) []const u8 {
        return self.stats.pib;
    }

    // ?<NestedStruct> optional in method arg
    pub fn _changeStats(self: *Country, stats: ?Stats) void {
        if (stats) |s| {
            self.stats = s;
        }
    }

    // *<Struct> (ie. pointer) is not supported by design,
    // for a pointer use case, use a seperate Native API.

    // As return value
    // ---------------

    // return <NestedStruct> in getter
    pub fn get_stats(self: Country) Stats {
        return self.stats;
    }

    // return ?<NestedStruct> in method (null)
    pub fn _doStatsNull(_: Country) ?Stats {
        return null;
    }

    // return ?<NestedStruct> in method (non-null)
    pub fn _doStatsNotNull(self: Country) ?Stats {
        return self.stats;
    }
};

// generate API, comptime
pub fn generate() ![]public.API {
    return try public.compile(.{ Brand, Car, Country });
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

    var nested_arg = [_]tests.Case{
        .{ .src = "let stats = {'pib': '322Mds', 'population': 80}; let country = new Country(stats);", .ex = "undefined" },
        .{ .src = "country.population;", .ex = "80" },
        .{ .src = "let stats_without_population = {'pib': '342Mds'}; country.changeStats(stats_without_population)", .ex = "undefined" },
        .{ .src = "let stats2 = {'pib': '342Mds', 'population': 80}; country.changeStats(stats2);", .ex = "undefined" },
        .{ .src = "country.pib;", .ex = "342Mds" },
        .{ .src = "country.stats.pib;", .ex = "342Mds" },
        .{ .src = "country.doStatsNull();", .ex = "null" },
        .{ .src = "country.doStatsNotNull().pib;", .ex = "342Mds" },
    };
    try tests.checkCases(js_env, &nested_arg);

    var separate_cases = [_]tests.Case{
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

        // as argumemnt for setter
        .{ .src = "let brand3 = new Brand('Audi')", .ex = "undefined" },
        .{ .src = "var _ = (car.brand = brand3)", .ex = "undefined" },
        .{ .src = "car.brand.name === 'Audi'", .ex = "true" },
        .{ .src = "var _ = (car.brandPtr = brand3)", .ex = "undefined" },
        .{ .src = "car.brandPtr.name === 'Audi'", .ex = "true" },

        // as argumemnt for methods
        .{ .src = "let brand4 = new Brand('Tesla')", .ex = "undefined" },
        .{ .src = "car.changeBrand(brand4)", .ex = "undefined" },
        .{ .src = "car.brand.name === 'Tesla'", .ex = "true" },
        .{ .src = "car.changeBrandPtr(brand4)", .ex = "undefined" },
        .{ .src = "car.brandPtr.name === 'Tesla'", .ex = "true" },

        .{ .src = "let brand5 = new Brand('Audi')", .ex = "undefined" },
        .{ .src = "car.changeBrandOpt(brand5)", .ex = "undefined" },
        .{ .src = "car.brand.name === 'Audi'", .ex = "true" },
        .{ .src = "car.changeBrandOpt(null)", .ex = "undefined" },
        .{ .src = "car.brand.name === 'Audi'", .ex = "true" },

        .{ .src = "let brand6 = new Brand('Ford')", .ex = "undefined" },
        .{ .src = "car.changeBrandOptPtr(brand6)", .ex = "undefined" },
        .{ .src = "car.brandPtr.name === 'Ford'", .ex = "true" },
        .{ .src = "car.changeBrandOptPtr(null)", .ex = "undefined" },
        .{ .src = "car.brandPtr.name === 'Ford'", .ex = "true" },
    };
    try tests.checkCases(js_env, &separate_cases);
}
