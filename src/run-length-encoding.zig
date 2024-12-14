const std = @import("std");

pub fn RunLengthArray(T: type) type {
    return struct {
        const Self = @This();

        count: usize,
        items: []T,
        run_lengths: []usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const initCapacity = 1;
            const items = try allocator.alloc(T, initCapacity);
            errdefer allocator.free(items);
            const run_lengths = try allocator.alloc(usize, initCapacity);
            return .{
                .count = 0,
                .items = items,
                .run_lengths = run_lengths,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.allocator.free(self.run_lengths);
        }

        pub fn append(self: *Self, item: T, run_length: usize) !void {
            if (self.count > 0 and std.meta.eql(item, self.items[self.count - 1])) {
                self.run_lengths[self.count - 1] += run_length;
                return;
            }
            if (self.count == self.run_lengths.len) {
                self.items = try self.allocator.realloc(self.items, self.items.len * 2);
                self.run_lengths = try self.allocator.realloc(self.run_lengths, self.items.len * 2);
            }
            self.items[self.count] = item;
            self.run_lengths[self.count] = run_length;
            self.count += 1;
        }

        pub fn get(self: Self, index: usize) !T {
            var run_total: usize = 0;
            for (0..self.count) |i| {
                run_total += self.run_lengths[i];
                if (run_total > index) return self.items[i];
            }
            return error.OutOfBounds;
        }
    };
}

test "storing values of a primitive type" {
    var array = try RunLengthArray(isize).init(std.testing.allocator);
    defer array.deinit();
    try array.append(-42, 1);
    try array.append(-42, 1);
    try std.testing.expectEqual(2, array.run_lengths[0]);
}

test "storing values of a non-primitive type" {
    var array = try RunLengthArray(struct { x: u64, y: i32 }).init(std.testing.allocator);
    defer array.deinit();
    try array.append(.{ .x = 1, .y = -3 }, 1);
    try array.append(.{ .x = 1, .y = -3 }, 1);
    try std.testing.expectEqual(2, array.run_lengths[0]);
}
