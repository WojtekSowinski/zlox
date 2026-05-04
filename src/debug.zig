const std = @import("std");
const bytecode = @import("bytecode.zig");
const Value = @import("value.zig").Value;
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

        inline .constant,
        .long_constant,
        => |index, tag| {
            const opName = comptime toUpper(@tagName(tag));
            std.debug.print(opName ++ (" " ** (21 - opName.len)) ++ "{d:0>4} '", .{index});
            logValue(chunk.constants.items[index]);
            std.debug.print("'\n", .{});
        },

        inline .def_global,
        .get_global,
        .set_global,
        .get_local,
        .set_local,
        .long_def_global,
        .long_get_global,
        .long_set_global,
        .long_get_local,
        .long_set_local,
        => |index, tag| {
            const opName = comptime toUpper(@tagName(tag));
            std.debug.print(opName ++ (" " ** (21 - opName.len)) ++ "{d:0>4}\n", .{index});
        },

        inline else => |_, tag| {
            const opName = comptime toUpper(@tagName(tag));
            std.debug.print(opName ++ "\n", .{});
        },
    }
}

fn toUpper(comptime str: []const u8) [str.len]u8 {
    comptime var upper: [str.len]u8 = undefined;
    for (str, 0..) |char, i| {
        upper[i] = if ('a' <= char and char <= 'z') (char - 32) else char;
    }
    return upper;
}

pub fn logStack(vm: VM) void {
    for (vm.stack.array[0..vm.stack.count]) |val| {
        std.debug.print("[ ", .{});
        logValue(val);
        std.debug.print(" ]", .{});
    }
    std.debug.print("\n", .{});
}

fn logValue(value: Value) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    value.print(&stderr.file_writer.interface) catch return;
}
