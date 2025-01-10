const std = @import("std");

pub const Obj = struct {
    type: ObjectType,
    next: ?*Obj,

    const Self = @This();

    pub inline fn as(self: *Self, comptime T: type) *T {
        return @fieldParentPtr("obj", self);
    }

    pub inline fn is(self: Self, obj_type: ObjectType) bool {
        return self.type == obj_type;
    }

    pub inline fn isString(self: Self) bool {
        return self.is(.const_string) or self.is(.owned_string);
    }

    pub inline fn print(self: *Self) void {
        switch (self.type) {
            .const_string,
            .owned_string,
            => std.debug.print("{s}", .{self.as(String).text}),
        }
    }
};

pub const ObjectType = enum {
    const_string,
    owned_string,
};

pub const String = struct {
    obj: Obj,
    hash: u32,
    text: []const u8,
};
