const std = @import("std");
const v8 = @import("v8");
const engine = @import("engine.zig");
const refl = @import("reflect.zig");
const gen = @import("generate.zig");
const data = @import("data.zig");

pub fn main() !void {
    const person_refl = comptime refl.reflectStruct(data.Person);
    const person_api = comptime gen.generateAPI(data.Person, person_refl);

    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // create v8 vm
    var vm = engine.VM.init();
    defer vm.deinit();

    // create v8 isolate
    var iso = engine.Isolate.init(alloc);
    defer iso.deinit(alloc);
    var isolate = iso.isolate;

    // create a v8 ObjectTemplate for the global namespace
    var globals = v8.ObjectTemplate.initDefault(isolate);

    // load API, before creating context
    person_api.load(isolate, globals);

    // create v8 context
    var context = iso.initContext(globals);
    defer iso.deinitContext(context);

    // javascript script
    const script =
        \\let p = new Person(40);
        \\p.age === 40;
        \\p.otherAge(10) === 40;
    ;

    // exec javascript in context
    var res = try engine.jsExecScript(alloc, isolate, context, script, "main.js");
    defer res.deinit();

    // javascript result
    if (res.success) {
        std.log.info("{s}", .{res.result.?});
    }
}
