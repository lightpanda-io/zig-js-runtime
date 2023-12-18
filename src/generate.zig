const std = @import("std");

const internal = @import("internal_api.zig");
const refl = internal.refl;
const NativeContext = internal.NativeContext;

const API = @import("api.zig").API;

const loadFn = @import("private_api.zig").loadFn;

// Compile and loading mechanism
// -----------------------------

// NOTE:
// The mechanism is based on 2 steps
// 1. The compile step at comptime will produce a list of APIs
// At this step we:
// - reflect the native struct to obtain type information (T_refl)
// - generate a loading function containing corresponding JS callbacks functions
// (constructor, getters, setters, methods)
// 2. The loading step at runtime will product a list of TPLs
// At this step we call the loading function into the runtime v8 (Isolate and globals),
// generating corresponding V8 functions and objects templates.

// Compile native types to native APIs
// which can be later loaded in JS.
// This function is called at comptime.
pub fn compile(comptime types: anytype) []API {
    comptime {

        // call types reflection
        const all_T = refl.do(types) catch unreachable;

        // generate APIs
        var apis: [all_T.len]API = undefined;
        inline for (all_T, 0..) |T_refl, i| {
            const loader = loadFn(T_refl, all_T);
            apis[i] = API{ .T_refl = T_refl, .load = loader };
        }

        return &apis;
    }
}

// Load native APIs into a JS sandbox
// This function is called at runtime.
pub fn load(
    nat_ctx: *NativeContext,
    js_sandbox: anytype,
    js_globals: anytype,
    comptime apis: []API,
    comptime js_T: type,
    js_types: []js_T,
) !void {
    inline for (apis, 0..) |api, i| {
        if (api.T_refl.proto_index == null) {
            js_types[i] = try api.load(nat_ctx, js_sandbox, js_globals, null);
        } else {
            const proto = js_types[api.T_refl.proto_index.?]; // safe because apis are ordered from parent to child
            js_types[i] = try api.load(nat_ctx, js_sandbox, js_globals, proto);
        }
    }
}
