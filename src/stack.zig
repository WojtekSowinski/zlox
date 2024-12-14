const std = @import("std");

pub fn Stack(T: type) type {
    return struct {
        items: []T,
        top: *T,
        allcator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allcator: std.mem.Allocator, capacity: usize) !Self {
            const items = try allcator.alloc(T, capacity);
            return .{
                .items = items,
                .top = @ptrCast(items.ptr),
                .allcator = allcator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allcator.free(self.items);
        }
    };
}
