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

pub const Result = struct {
    duration: u64,

    alloc_nb: usize,
    realloc_nb: usize,
    alloc_size: usize,
};

pub fn call(
    func: anytype,
    args: anytype,
    comptime iter: comptime_int,
    comptime warmup: ?comptime_int,
) !u64 {
    var total: u64 = 0;
    var i: usize = 0;
    var is_error_union = false;

    while (i < iter) {
        var start: std.time.Instant = undefined;
        if (warmup != null and i > warmup.?) {
            start = try std.time.Instant.now();
        }

        const res = @call(.auto, func, args);
        if (i == 0) {
            // TODO: handle more return cases
            const info = @typeInfo(@TypeOf(res));
            if (info == .ErrorUnion) {
                is_error_union = true;
            }
        }
        if (is_error_union) {
            _ = try res;
        }

        if (warmup != null and i > warmup.?) {
            const end = try std.time.Instant.now();
            const elapsed = std.time.Instant.since(end, start);
            total += elapsed;
        }
        i += 1;
    }
    var res: u64 = undefined;
    if (warmup != null) {
        res = total / (iter - warmup.?);
    } else {
        res = total / iter;
    }
    return total / iter;
}

pub const Allocator = struct {
    parent_allocator: std.mem.Allocator,

    alloc_nb: usize = 0,
    realloc_nb: usize = 0,
    free_nb: usize = 0,
    size: usize = 0,

    const Stats = struct {
        alloc_nb: usize,
        realloc_nb: usize,
        alloc_size: usize,
    };

    fn init(parent_allocator: std.mem.Allocator) Allocator {
        return .{
            .parent_allocator = parent_allocator,
        };
    }

    pub fn stats(self: *Allocator) Stats {
        return .{
            .alloc_nb = self.alloc_nb,
            .realloc_nb = self.realloc_nb,
            .alloc_size = self.size,
        };
    }

    pub fn allocator(self: *Allocator) std.mem.Allocator {
        return std.mem.Allocator{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        } };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        log2_ptr_align: u8,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawAlloc(len, log2_ptr_align, return_address);
        self.alloc_nb += 1;
        self.size += len;
        return result;
    }

    fn resize(
        ctx: *anyopaque,
        old_mem: []u8,
        log2_old_align: u8,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawResize(old_mem, log2_old_align, new_len, ra);
        self.realloc_nb += 1; // TODO: only if result is not null?
        return result;
    }

    fn free(
        ctx: *anyopaque,
        old_mem: []u8,
        log2_old_align: u8,
        ra: usize,
    ) void {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        self.parent_allocator.rawFree(old_mem, log2_old_align, ra);
        self.free_nb += 1;
    }
};

pub fn allocator(parent_allocator: std.mem.Allocator) Allocator {
    return Allocator.init(parent_allocator);
}
