const std = @import("std");
const v8 = @import("v8");
const utils = @import("utils.zig");

pub const Script = struct {
    origin: []const u8,
    content: []const u8,
};

pub fn main() !void {
    // allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // javascript script
    const script = Script{
        .origin = "main.js",
        .content = 
        \\let p = new Person(40);
        \\p.age === 40;
        ,
    };

    // javascript exec
    var res: utils.ExecuteResult = undefined;
    defer res.deinit();
    jsExecScript(alloc, script, &res);

    // javascript result
    if (res.success) {
        std.log.info("{s}", .{res.result.?});
    } else {
        std.log.err("{s}", .{res.err.?});
        return error.v8Error;
    }
}

const Person = struct {
    age: i32,
};

fn constructor(raw_info: ?*const v8.C_FunctionCallbackInfo) callconv(.C) void {
    const info = v8.FunctionCallbackInfo.initFromV8(raw_info);
    const isolate = info.getIsolate();
    const ctx = isolate.getCurrentContext();

    // get the constructor argument (we expect an int)
    const arg1 = info.getArg(0);
    const arg1_val = arg1.toI32(ctx) catch 0; // TODO: throw exception

    // allocator, we need to put the zig object on the heap
    // otherwise on the stack it will be delete when the function returns
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    // create and allocate the zig object
    var obj_ptr = alloc.create(Person) catch unreachable;
    obj_ptr.* = .{
        .age = arg1_val,
    };

    // bind the zig object to it's javascript counterpart
    const external = v8.External.init(isolate, obj_ptr);
    const js_obj = info.getThis();
    js_obj.setInternalField(0, external);
}

fn getter(_: ?*const v8.Name, raw_info: ?*const v8.C_PropertyCallbackInfo) callconv(.C) void {
    const info = v8.PropertyCallbackInfo.initFromV8(raw_info);
    const isolate = info.getIsolate();

    // retrieve the zig object from it's javascript counterpart
    const js_obj = info.getThis();
    const external = js_obj.getInternalField(0).castTo(v8.External);
    const obj_ptr = @ptrCast(*Person, external.get());

    // return to javascript the corresponding zig object field
    info.getReturnValue().set(v8.Integer.initI32(isolate, obj_ptr.age));
}

fn personAPI(isolate: v8.Isolate, globals: v8.ObjectTemplate) void {
    // create a v8 FunctionTemplate for the Person constructor function,
    // with the corresponding zig callback,
    // and attach it to the global namespace
    var constructor_tpl = v8.FunctionTemplate.initCallback(isolate, constructor);
    const constructor_key = v8.String.initUtf8(isolate, "Person");
    globals.set(constructor_key, constructor_tpl, v8.PropertyAttribute.None);

    // get the v8 ObjectTemplate attached to the constructor
    // and set 1 internal field to bind the counterpart zig object
    const object_tpl = constructor_tpl.getInstanceTemplate();
    object_tpl.setInternalFieldCount(1);

    // set a getter form the v8 ObjectTemplate,
    // with the corresponding zig callback
    const age_key = v8.String.initUtf8(isolate, "age");
    object_tpl.setGetter(age_key, getter);
}

pub fn jsExecScript(alloc: std.mem.Allocator, script: Script, res: *utils.ExecuteResult) void {
    // init v8
    const platform = v8.Platform.initDefault(0, true);
    defer platform.deinit();
    v8.initV8Platform(platform);
    defer v8.deinitV8Platform();
    v8.initV8();
    defer _ = v8.deinitV8();

    // create a new v8 Isolate
    var params = v8.initCreateParams();
    params.array_buffer_allocator = v8.createDefaultArrayBufferAllocator();
    defer v8.destroyArrayBufferAllocator(params.array_buffer_allocator.?);
    var isolate = v8.Isolate.init(&params);
    defer isolate.deinit();
    isolate.enter();
    defer isolate.exit();

    // v8 handle scope
    var hscope: v8.HandleScope = undefined;
    hscope.init(isolate);
    defer hscope.deinit();

    // create a v8 ObjectTemplate for the global namespace
    var globals = v8.ObjectTemplate.initDefault(isolate);

    // load API
    personAPI(isolate, globals);

    // create a v8 Context, providing the globals namespace
    var context = v8.Context.init(isolate, globals, null);
    context.enter();
    defer context.exit();

    // javascript exec and result
    const origin = v8.String.initUtf8(isolate, script.origin);
    utils.executeString(alloc, isolate, context, script.content, origin, res);
}
