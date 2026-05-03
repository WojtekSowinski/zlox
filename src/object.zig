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

    pub inline fn print(self: *Self, writer: *std.Io.Writer) !void {
        switch (self.type) {
            .const_string,
            .owned_string,
            => try writer.print("{s}", .{self.as(String).text}),
        }
    }
};

pub const ObjectType = enum {
    const_string,
    owned_string,
};

pub const String = struct {
    const Self = @This();

    obj: Obj,
    hash: u32,
    text: []const u8,

    pub fn getHash(self: *const Self) u32 {
        return self.hash;
    }

    pub fn equals(self: *const Self, other: *const Self) bool {
        return self == other;
    }
};
