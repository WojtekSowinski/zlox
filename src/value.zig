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

    pub fn isNumber(self: Self) bool {
        return std.meta.activeTag(self) == .number;
    }

    pub fn isBoolean(self: Self) bool {
        return std.meta.activeTag(self) == .boolean;
    }

    pub fn isObject(self: Self) bool {
        return std.meta.activeTag(self) == .object;
    }

    pub fn isFalsey(self: Self) bool {
        return self == .nil or (self.isBoolean() and !self.boolean);
    }

    pub fn equals(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
    }
};

pub inline fn print(value: Value) void {
    switch (value) {
        .number => |n| std.debug.print("{d}", .{n}),
        .boolean => |b| std.debug.print("{s}", .{if (b) "true" else "false"}),
        .nil => std.debug.print("nil", .{}),
        .object => |obj| switch (obj.type) {
            .const_string,
            .owned_string,
            => std.debug.print("{s}", .{obj.as(object.String).text}),
        },
    }
}
