const std = @import("std");
const bytecode = @import("bytecode.zig");
const Chunk = bytecode.Chunk;
const Instruction = bytecode.Instruction;
const value = @import("value.zig");
const Value = value.Value;
const LoxType = value.LoxType;
const config = @import("build_config");
const debug = @import("debug.zig");
const Stack = @import("stack.zig").Stack;
const Compiler = @import("compiler.zig");
const AnyReader = std.io.AnyReader;
const AnyWriter = std.io.AnyWriter;
const LoxGarbageCollector = @import("gc.zig");

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
    gc: LoxGarbageCollector,

    const Self = @This();

    pub inline fn init(
        // INFO: init() is inlined to prevent vm.gc.allocator().ptr from
        // being invalidated when init() returns.
        allocator: std.mem.Allocator,
    ) !Self {
        var vm = Self{ .gc = undefined, .stack = undefined };
        vm.gc = LoxGarbageCollector.init(allocator);
        vm.stack = try Stack(Value).init(vm.gc.allocator(), 256);
        return vm;
    }

    pub fn interpret(self: *Self, source_code: []const u8) InterpretResult {
        var chunk = Chunk.init(self.gc.allocator()) catch return .compile_error;
        defer chunk.deinit();
        var compiler = Compiler.init(&chunk, self.error_writer, &self.gc);
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
                .true => self.stack.push(.{ .boolean = true }),
                .false => self.stack.push(.{ .boolean = false }),
                .nil => self.stack.push(.nil),
                .constant => |index| {
                    const constant: Value = self.readConstant(index);
                    self.stack.push(constant);
                },
                .long_con => |index| {
                    const constant: Value = self.readConstant(index);
                    self.stack.push(constant);
                },
                .negate => {
                    switch (self.stack.peek(0)) {
                        .number => |n| self.stack.swap(.{ .number = -n }),
                        else => self.runtimeError("Operand must be a number", .{}) catch return .runtime_error,
                    }
                },
                .not => self.stack.swap(.{ .boolean = self.stack.peek(0).isFalsey() }),
                .add => self.runBinaryOp(.number, add) catch return .runtime_error,
                .subtract => self.runBinaryOp(.number, subtract) catch return .runtime_error,
                .multiply => self.runBinaryOp(.number, multiply) catch return .runtime_error,
                .divide => self.runBinaryOp(.number, divide) catch return .runtime_error,
                .equal => {
                    const right = self.stack.pop();
                    const left = self.stack.peek(0);
                    self.stack.swap(.{ .boolean = left.equals(right) });
                },
                .not_equal => {
                    const right = self.stack.pop();
                    const left = self.stack.peek(0);
                    self.stack.swap(.{ .boolean = !left.equals(right) });
                },
                .less_than => self.runBinaryOp(.boolean, less) catch return .runtime_error,
                .greater_than => self.runBinaryOp(.boolean, greater) catch return .runtime_error,
                .less_or_equal => self.runBinaryOp(.boolean, less_eq) catch return .runtime_error,
                .greater_or_equal => self.runBinaryOp(.boolean, greater_eq) catch return .runtime_error,
            }
        }
    }

    inline fn readConstant(self: Self, index: usize) Value {
        return self.chunk.constants.items[index];
    }

    inline fn runBinaryOp(
        self: *Self,
        comptime return_type: LoxType,
        op: fn (f64, f64) callconv(.Inline) std.meta.TagPayload(Value, return_type),
    ) !void {
        const right = self.stack.peek(0);
        const left = self.stack.peek(1);
        if (left.isNumber() and right.isNumber()) {
            _ = self.stack.pop();
            self.stack.swap(@unionInit(
                Value,
                std.enums.tagName(LoxType, return_type).?,
                op(left.number, right.number),
            ));
        } else {
            try self.runtimeError("Operands must be numbers.", .{});
        }
    }

    inline fn readByte(self: *Self) u8 {
        const ret = self.ip.*;
        self.ip += 1;
        return ret;
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
        self.gc.deleteObjects();
    }

    fn runtimeError(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try std.fmt.format(self.error_writer, fmt, args);
        const instruction_index = @intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr) - 1;
        const line = try self.chunk.lines.get(instruction_index);
        try std.fmt.format(self.error_writer, "\n[line {d}] in script\n", .{line});
        self.resetStack();
    }

    inline fn resetStack(self: *Self) void {
        self.stack.top = self.stack.items.ptr;
    }
};

inline fn add(x: f64, y: f64) f64 {
    return x + y;
}

inline fn subtract(x: f64, y: f64) f64 {
    return x - y;
}

inline fn multiply(x: f64, y: f64) f64 {
    return x * y;
}

inline fn divide(x: f64, y: f64) f64 {
    return x / y;
}

inline fn less(x: f64, y: f64) bool {
    return x < y;
}

inline fn greater(x: f64, y: f64) bool {
    return x > y;
}

inline fn less_eq(x: f64, y: f64) bool {
    return x <= y;
}

inline fn greater_eq(x: f64, y: f64) bool {
    return x >= y;
}
