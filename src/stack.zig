const std = @import("std");

pub fn Stack(T: type) type {
    return struct {
        items: []T,
        top: [*]T,
        bound: [*]T,
        allcator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allcator: std.mem.Allocator, capacity: usize) !Self {
            const items = try allcator.alloc(T, capacity);
            return .{
                .items = items,
                .top = items.ptr,
                .bound = items.ptr + items.len,
                .allcator = allcator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allcator.free(self.items);
        }

        pub fn peek(self: Self, distance: usize) T {
            return (self.top - distance - 1)[0];
        }

        pub fn swap(self: Self, item: T) void {
            (self.top - 1)[0] = item;
        }

        pub fn pop(self: *Self) T {
            self.top -= 1;
            return self.top[0];
        }

        pub fn push(self: *Self, item: T) void {
            if (self.top == self.bound) {
                const offset = self.items.len;
                self.items = self.allcator.realloc(self.items, self.items.len * 2) catch unreachable;
                self.bound = self.items.ptr + self.items.len;
                self.top = self.items.ptr + offset;
            }
            self.top[0] = item;
            self.top += 1;
        }
    };
}
