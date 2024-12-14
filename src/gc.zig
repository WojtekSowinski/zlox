const std = @import("std");
const Allocator = std.mem.Allocator;

base_allocator: Allocator,

const Self = @This();

pub fn init(base_allocator: Allocator) Self {
    return Self{ .base_allocator = base_allocator };
}

fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.base_allocator.rawAlloc(len, ptr_align, ret_addr);
}

fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.base_allocator.rawResize(buf, buf_align, new_len, ret_addr);
}

fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.base_allocator.rawFree(buf, buf_align, ret_addr);
}

pub fn allocator(self: *Self) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = allocFn,
            .free = freeFn,
            .resize = resizeFn,
        },
    };
}
