const std = @import("std");
const bytecode = @import("bytecode.zig");
const Chunk = bytecode.Chunk;
const Instruction = bytecode.Instruction;
const value = @import("value.zig");
const Value = value.Value;
const config = @import("build_config");
const debug = @import("debug.zig");
const Stack = @import("stack.zig").Stack;
const Compiler = @import("compiler.zig");
const AnyReader = std.io.AnyReader;
const AnyWriter = std.io.AnyWriter;

const null_writer = std.io.null_writer.any();

fn emptyRead(context: *const anyopaque, buffer: []u8) !usize {
    _ = context;
    _ = buffer;
    return 0;
}

const empty_reader = AnyReader{
    .context = undefined,
    .readFn = emptyRead,
};

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

pub const VM = struct {
    chunk: *Chunk = undefined,
    ip: [*]u8 = undefined,
    stack: Stack(Value),
    input_reader: AnyReader = empty_reader,
    output_writer: AnyWriter = null_writer,
    error_writer: AnyWriter = null_writer,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
    ) !Self {
        return Self{
            .stack = try Stack(Value).init(allocator, 256),
        };
    }

    pub fn interpret(self: *Self, source_code: []const u8) InterpretResult {
        var chunk = Chunk.init(self.stack.allcator) catch return .compile_error;
        defer chunk.deinit();
        var compiler = Compiler.init(&chunk, self.error_writer);
        compiler.compile(source_code) catch return .compile_error;
        self.chunk = &chunk;
        self.ip = chunk.code.items.ptr;
        return self.run();
    }

    fn run(self: *Self) InterpretResult {
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
                    std.debug.print("\n", .{});
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
    return x - y;
}

inline fn multiply(x: Value, y: Value) Value {
    return x * y;
}

inline fn divide(x: Value, y: Value) Value {
    return x / y;
}
