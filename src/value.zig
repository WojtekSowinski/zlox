const std = @import("std");
const object = @import("object.zig");

// TODO: Reimplement values using NaN boxing instead of tagged unions.
//       Enable NaN boxing based on target architecture or a build flag.

pub const LoxType = enum {
    number,
    boolean,
    nil,
    object,
};

pub const Value = union(LoxType) {
    number: f64,
    boolean: bool,
    nil,
    object: *object.Obj,

    const Self = @This();

    pub inline fn isNumber(self: Self) bool {
        return std.meta.activeTag(self) == .number;
    }

    pub inline fn isBoolean(self: Self) bool {
        return std.meta.activeTag(self) == .boolean;
    }

    pub inline fn isNil(self: Self) bool {
        return std.meta.activeTag(self) == .nil;
    }

    pub inline fn isObject(self: Self) bool {
        return std.meta.activeTag(self) == .object;
    }

    pub inline fn isString(self: Self) bool {
        return self.isObject() and self.object.isString();
    }

    pub inline fn isFalsey(self: Self) bool {
        return self == .nil or (self.isBoolean() and !self.boolean);
    }

    pub inline fn equals(self: Self, other: Self) bool {
        if (self.isString() and other.isString()) {
            return std.mem.eql(u8, getSlice(self), getSlice(other));
        }
        return std.meta.eql(self, other);
    }

    inline fn getSlice(value: Value) []const u8 {
        return value.object.as(object.String).text;
    }

    pub inline fn print(self: Self) void {
        switch (self) {
            .number => |n| std.debug.print("{d}", .{n}),
            .boolean => |b| std.debug.print("{s}", .{if (b) "true" else "false"}),
            .nil => std.debug.print("nil", .{}),
            .object => |obj| obj.print(),
        }
    }
};
