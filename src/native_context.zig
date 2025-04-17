// Copyright 2023-2024 Lightpanda (Selecy SAS)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

const Loop = @import("api.zig").Loop;
const UserContext = @import("api.zig").UserContext;

pub const NativeContext = struct {
    alloc: std.mem.Allocator,
    loop: *Loop,
    userctx: ?UserContext,

    default_js_objs: JSObjects,
    isolated_world_js_objs: JSObjects,
    default_nat_objs: NatObjects,
    isolated_world_nat_objs: NatObjects,

    // NOTE: DO NOT ACCESS DIRECTLY js_types
    // - use once loadTypes at startup to set them
    // - and then getType during execution to access them
    js_types: ?[]usize = null,

    pub const JSObjects = std.AutoHashMapUnmanaged(usize, usize);
    pub const NatObjects = @import("internal_api.zig").refs.Map;

    pub fn init(self: *NativeContext, alloc: std.mem.Allocator, loop: *Loop, userctx: ?UserContext) void {
        self.* = .{
            .alloc = alloc,
            .loop = loop,
            .userctx = userctx,
            .default_js_objs = JSObjects{},
            .isolated_world_js_objs = JSObjects{},
            .default_nat_objs = NatObjects{},
            .isolated_world_nat_objs = NatObjects{},
        };
    }

    pub fn stop(self: *NativeContext) void {
        self.default_js_objs.clearAndFree(self.alloc);
        self.isolated_world_js_objs.clearAndFree(self.alloc);
        self.default_nat_objs.clearAndFree(self.alloc);
        self.isolated_world_nat_objs.clearAndFree(self.alloc);
    }

    // loadTypes into the NativeContext
    // The caller holds the memory of the js_types slice,
    // no heap allocation is performed at the NativeContext level
    pub fn loadTypes(self: *NativeContext, js_types: []usize) void {
        std.debug.assert(self.js_types == null);
        self.js_types = js_types;
    }

    pub fn getType(self: *const NativeContext, comptime T: type, index: usize) *T {
        std.debug.assert(self.js_types != null);
        const t = self.js_types.?[index];
        return @as(*T, @ptrFromInt(t));
    }

    pub fn deinit(self: *NativeContext) void {
        self.stop();
        self.default_js_objs.deinit(self.alloc);
        self.isolated_world_js_objs.deinit(self.alloc);
        self.default_nat_objs.deinit(self.alloc);
        self.isolated_world_nat_objs.deinit(self.alloc);
        self.* = undefined;
    }
};
