const std = @import("std");
const v8 = @import("v8");

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
    // TODO: better way to handle that ? If not better allocator ?
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

pub fn loadAPI(isolate: v8.Isolate, globals: v8.ObjectTemplate) void {
    personAPI(isolate, globals);
}
