const std = @import("std");
const bytecode = @import("chunk.zig");
const value = @import("value.zig");
const VM = @import("vm.zig").VM;

pub fn disassembleChunk(chunk: bytecode.Chunk, name: []const u8) void {
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

pub fn disassembleInstruction(instruction: bytecode.Instruction, chunk: bytecode.Chunk) void {
    switch (instruction) {
        .ret => std.debug.print("RETURN\n", .{}),
        .con => |index| {
            std.debug.print("CONSTANT        {d:0>4} '", .{index});
            value.print(chunk.constants.items[index]);
            std.debug.print("'\n", .{});
        },
        .long_con => |index| {
            std.debug.print("LONG_CONSTANT   {d:0>4} '", .{index});
            value.print(chunk.constants.items[index]);
            std.debug.print("'\n", .{});
        },
    }
}

pub fn printStack(vm: VM) void {
    std.debug.print(" " ** 10, .{});
    var ptr: [*]value.Value = vm.stack.items.ptr;
    while (ptr != vm.stack.top) : (ptr += 1) {
        std.debug.print("[ ", .{});
        value.print(ptr[0]);
        std.debug.print(" ]", .{});
    }
    std.debug.print("\n", .{});
}
