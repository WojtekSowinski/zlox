const std = @import("std");
const ch = @import("chunk.zig");
const val = @import("value.zig");

pub fn disassembleChunk(chunk: *ch.Chunk, name: []const u8) void {
    std.debug.print("== {s} ==\n", .{name});
    var offset: usize = 0;
    while (offset < chunk.length()) {
        std.debug.print("{d:0>4} ", .{offset});
        const line = chunk.lines.get(offset) catch unreachable;
        if (offset > 0 and line == chunk.lines.get(offset - 1) catch unreachable) {
            std.debug.print("   | ", .{});
        } else {
            std.debug.print("{d:>4} ", .{line});
        }
        const instruction = chunk.readInstruction(offset);
        disassembleInstruction(instruction, chunk);
        offset += instruction.size();
    }
}

fn disassembleInstruction(self: ch.Instruction, chunk: *ch.Chunk) void {
    switch (self) {
        .ret => std.debug.print("RETURN\n", .{}),
        .con => |index| {
            std.debug.print("CONSTANT        {d:0>4} '", .{index});
            printValue(chunk.constants.items[index]);
            std.debug.print("'\n", .{});
        },
        .long_con => |index| {
            std.debug.print("LONG_CONSTANT   {d:0>4} '", .{index});
            printValue(chunk.constants.items[index]);
            std.debug.print("'\n", .{});
        },
    }
}

fn printValue(value: val.Value) void {
    std.debug.print("{d}", .{value});
}
