const std = @import("std");

pub const Value = f64;

pub inline fn print(value: Value) void {
    std.debug.print("{d}", .{value});
}
