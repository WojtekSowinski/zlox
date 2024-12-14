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
                debug.printStack(self.*);
                debug.disassembleInstruction(instruction, self.chunk.*);
            }
            self.ip += instruction.size();
            switch (instruction) {
                .ret => {
                    value.print(self.stack.pop());
                    return .ok;
                },
                .constant => |index| {
                    const constant: Value = self.readConstant(index);
                    self.stack.push(constant);
                },
                .long_con => |index| {
                    const constant: Value = self.readConstant(index);
                    self.stack.push(constant);
                },
                .negate => self.stack.push(-self.stack.pop()),
                .add => self.runBinaryOp(add),
                .subtract => self.runBinaryOp(subtract),
                .multiply => self.runBinaryOp(multiply),
                .divide => self.runBinaryOp(divide),
            }
        }
    }

    inline fn readConstant(self: Self, index: usize) Value {
        return self.chunk.constants.items[index];
    }

    inline fn runBinaryOp(self: *Self, op: fn (Value, Value) callconv(.Inline) Value) void {
        const right = self.stack.pop();
        const left = self.stack.pop();
        self.stack.push(op(left, right));
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

inline fn add(x: Value, y: Value) Value {
    return x + y;
}

inline fn subtract(x: Value, y: Value) Value {
    return x + y;
}

inline fn multiply(x: Value, y: Value) Value {
    return x + y;
}

inline fn divide(x: Value, y: Value) Value {
    return x + y;
}
