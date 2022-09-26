const std = @import("std");
const v8 = @import("v8");
const engine = @import("engine.zig");
const utils = @import("utils.zig");
const Store = @import("store.zig");
const reflect = @import("reflect.zig");
const generate = @import("generate.zig");
const data = @import("data.zig");

pub fn main() !void {

    // generate API
    const person_refl = comptime reflect.Struct(data.Person);
    const person_api = comptime generate.API(data.Person, person_refl);

    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    utils.allocator = alloc;

    // store
    Store.default = Store.init(utils.allocator);
    defer Store.default.deinit(utils.allocator);

    // create v8 vm
    const vm = engine.VM.init();
    defer vm.deinit();

    // create v8 isolate
    const iso = engine.Isolate.init(utils.allocator);
    defer iso.deinit(utils.allocator);
    const isolate = iso.isolate;

    // create a v8 ObjectTemplate for the global namespace
    const globals = v8.ObjectTemplate.initDefault(isolate);

    // load API, before creating context
    person_api.load(isolate, globals);

    // create v8 context
    const context = iso.initContext(globals);
    defer iso.deinitContext(context);

    // javascript script
    const script =
        \\let p = new Person("Francis", "Bouvier", 40);
        \\p.age === 40;
        \\p.fullName() === "Bouvier";
        \\p.age = 41;
        \\p.age === 41;
    ;

    // exec javascript in context
    var res = engine.jsExecScript(utils.allocator, isolate, context, script, "main.js");
    defer res.deinit();

    // javascript result
    if (!res.success) {
        std.debug.print("{s}\n", .{res.stack.?});
        return error.JavascriptError;
    }
    std.log.info("{s}", .{res.result});
}
