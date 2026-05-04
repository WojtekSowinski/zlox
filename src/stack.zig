const std = @import("std");

pub fn Stack(T: type) type {
    return struct {
        array: []T,
        count: usize,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const items = try allocator.alloc(T, capacity);
            return .{
                .array = items,
                .count = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.array);
        }

        pub inline fn peek(self: Self, distance: usize) T {
            return self.array[self.count - 1 - distance];
        }

        pub inline fn swap(self: *Self, item: T) void {
            self.array[self.count - 1] = item;
        }

        pub inline fn pop(self: *Self) T {
            self.count -= 1;
            return self.array[self.count];
        }

        pub fn push(self: *Self, item: T) !void {
            const index = self.count;
            if (self.count == self.array.len) {
                self.array = try self.allocator.realloc(self.array, self.array.len * 2);
            }
            self.array[index] = item;
            self.count += 1;
        }

        pub inline fn clear(self: *Self) void {
            self.count = 0;
        }
    };
}
