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
        return std.mem.Allocator.init(self, alloc, resize, free);
    }

    fn alloc(
        self: *Allocator,
        len: usize,
        ptr_align: u29,
        len_align: u29,
        ra: usize,
    ) error{OutOfMemory}![]u8 {
        const result = try self.parent_allocator.rawAlloc(len, ptr_align, len_align, ra);
        self.alloc_nb += 1;
        self.size += len;
        return result;
    }

    fn resize(
        self: *Allocator,
        buf: []u8,
        buf_align: u29,
        new_len: usize,
        len_align: u29,
        ra: usize,
    ) ?usize {
        const result = self.parent_allocator.rawResize(buf, buf_align, new_len, len_align, ra);
        self.realloc_nb += 1; // TODO: only if result is not null?
        return result;
    }

    fn free(
        self: *Allocator,
        buf: []u8,
        buf_align: u29,
        ra: usize,
    ) void {
        self.parent_allocator.rawFree(buf, buf_align, ra);
        self.free_nb += 1;
    }
};

pub fn allocator(parent_allocator: std.mem.Allocator) Allocator {
    return Allocator.init(parent_allocator);
}
