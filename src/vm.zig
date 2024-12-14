const std = @import("std");
const bytecode = @import("chunk.zig");
const Chunk = bytecode.Chunk;
const Instruction = bytecode.Instruction;
const value = @import("value.zig");
const Value = value.Value;
const config = @import("build_config");
const debug = @import("debug.zig");
const Stack = @import("stack.zig").Stack;

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

pub const VM = struct {
    chunk: *Chunk,
    ip: [*]u8,
    stack: Stack(Value),

    const Self = @This();

    pub fn init(chunk: *Chunk, allocator: std.mem.Allocator) !Self {
        return Self{
            .chunk = chunk,
            .ip = chunk.code.items.ptr,
            .stack = try Stack(Value).init(allocator, 256),
        };
    }

    pub fn run(self: *Self) InterpretResult {
        while (true) {
            const instruction = Instruction.readFrom(self.ip);
            if (config.trace_execution) {
                debug.disassembleInstruction(instruction, self.chunk);
            }
            self.ip += instruction.size();
            switch (instruction) {
                .ret => return .ok,
                .con => |index| {
                    const constant: Value = self.readConstant(index);
                    value.print(constant);
                    std.debug.print("\n", .{});
                },
                .long_con => |index| {
                    const constant: Value = self.readConstant(index);
                    value.print(constant);
                    std.debug.print("\n", .{});
                },
            }
        }
    }

    inline fn readConstant(self: Self, index: usize) Value {
        return self.chunk.constants.items[index];
    }

    inline fn readByte(self: *Self) u8 {
        const ret = self.ip.*;
        self.ip += 1;
        return ret;
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
    }
};
