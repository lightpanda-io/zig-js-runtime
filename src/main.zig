const std = @import("std");
const v8 = @import("v8");

const engine = @import("engine.zig");
const utils = @import("utils.zig");
const refs = @import("refs.zig");
const Store = @import("store.zig");
const bench = @import("bench.zig");

const proto = @import("proto_test.zig");
const primitive_types = @import("types_primitives_test.zig");

pub fn main() !void {

    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    utils.allocator = gpa.allocator();

    // refs map
    refs.map = refs.Map{};
    defer refs.map.deinit(utils.allocator);

    // store
    Store.default = Store.init(utils.allocator);
    defer Store.default.deinit(utils.allocator);

    // create v8 vm
    const vm = engine.VM.init();
    defer vm.deinit();

    // generate APIs
    const apis = proto.generate();

    // benchmark
    const iter = 1000;
    try bench.withIsolate(iter, proto.exec, apis);
    try bench.withoutIsolate(iter, proto.exec, apis);
}

test {
    // allocator
    utils.allocator = std.testing.allocator;

    // refs map
    refs.map = refs.Map{};
    defer refs.map.deinit(utils.allocator);

    // store
    Store.default = Store.init(utils.allocator);
    defer Store.default.deinit(utils.allocator);

    // create v8 vm
    const vm = engine.VM.init();
    defer vm.deinit();

    // end to end test
    const proto_apis = proto.generate();
    try engine.Load(proto.exec, proto_apis);

    // unit test
    const primitives_apis = primitive_types.generate();
    try engine.Load(primitive_types.exec, primitives_apis);
}
