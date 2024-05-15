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

const public = @import("api.zig");

const WindowTypes = @import("tests/cbk_test.zig").Types;

pub const Types = public.reflect(public.MergeTuple(.{
    .{public.Console},
    WindowTypes,
}));

pub fn main() !void {

    // create JS vm
    const vm = public.VM.init();
    defer vm.deinit();

    // alloc
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    // launch shell
    try public.shell(&arena, null, .{ .app_name = "zig-js-runtime-shell" });
}
