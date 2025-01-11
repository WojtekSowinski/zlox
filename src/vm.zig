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
const object = @import("object.zig");

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

pub const VM = struct {
    chunk: *Chunk = undefined,
    ip: [*]u8 = undefined,
    stack: Stack(Value) = undefined,
    input_reader: AnyReader = empty_reader,
    output_writer: AnyWriter = null_writer,
    error_writer: AnyWriter = null_writer,
    gc: LoxGarbageCollector = undefined,

    const Self = @This();

    pub fn init(
        self: *Self,
        allocator: std.mem.Allocator,
    ) !void {
        self.gc = try LoxGarbageCollector.init(allocator);
        errdefer self.gc.deinit();
        self.stack = try Stack(Value).init(self.gc.allocator(), 256);
    }

    pub fn interpret(self: *Self, source_code: []const u8) !void {
        var chunk = try Chunk.init(self.gc.allocator());
        defer chunk.deinit();
        var compiler = Compiler.init(&chunk, self.error_writer, &self.gc);
        try compiler.compile(source_code);
        self.chunk = &chunk;
        self.ip = chunk.code.items.ptr;
        try self.run();
    }

    fn run(self: *Self) !void {
        while (true) {
            const instruction = Instruction.readFrom(self.ip);
            if (config.trace_execution) {
                debug.printStack(self.*);
                debug.disassembleInstruction(instruction, self.chunk.*);
            }
            self.ip += instruction.size();
            switch (instruction) {
                .ret => {
                    return;
                },
                .print => {
                    self.stack.pop().print();
                    std.debug.print("\n", .{});
                },
                .pop => _ = self.stack.pop(),
                .true => try self.stack.push(.{ .boolean = true }),
                .false => try self.stack.push(.{ .boolean = false }),
                .nil => try self.stack.push(.nil),
                .constant => |index| {
                    const constant: Value = self.readConstant(index);
                    try self.stack.push(constant);
                },
                .long_con => |index| {
                    const constant: Value = self.readConstant(index);
                    try self.stack.push(constant);
                },
                .negate => {
                    switch (self.stack.peek(0)) {
                        .number => |n| self.stack.swap(.{ .number = -n }),
                        else => {
                            try self.reportRuntimeError("Operand must be a number", .{});
                            return error.TypeError;
                        },
                    }
                },
                .not => self.stack.swap(.{ .boolean = self.stack.peek(0).isFalsey() }),
                .add => {
                    const right = self.stack.peek(0);
                    const left = self.stack.peek(1);
                    if (left.isNumber() and right.isNumber()) {
                        _ = self.stack.pop();
                        self.stack.swap(.{ .number = left.number + right.number });
                    } else if (left.isString() and right.isString()) {
                        _ = self.stack.pop();
                        const newString = try self.concatenate(left, right);
                        self.stack.swap(newString);
                    } else {
                        try self.reportRuntimeError("Operands must be numbers or strings.", .{});
                        return error.TypeError;
                    }
                },
                .subtract => try self.runBinaryOp(.number, subtract),
                .multiply => try self.runBinaryOp(.number, multiply),
                .divide => try self.runBinaryOp(.number, divide),
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
                .less_than => try self.runBinaryOp(.boolean, less),
                .greater_than => try self.runBinaryOp(.boolean, greater),
                .less_or_equal => try self.runBinaryOp(.boolean, less_eq),
                .greater_or_equal => try self.runBinaryOp(.boolean, greater_eq),
            }
        }
    }

    inline fn readConstant(self: Self, index: usize) Value {
        return self.chunk.constants.items[index];
    }

    fn concatenate(self: *Self, left: Value, right: Value) !Value {
        const str1 = left.object.as(object.String).text;
        const str2 = right.object.as(object.String).text;
        const new_text = try self.gc.allocator().alloc(u8, str1.len + str2.len);
        @memcpy(new_text[0..str1.len], str1);
        @memcpy(new_text[str1.len..], str2);
        const new_str = try self.gc.takeString(new_text);
        return .{ .object = &(new_str.obj) };
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
            try self.reportRuntimeError("Operands must be numbers.", .{});
            return error.TypeError;
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
        self.gc.deinit();
    }

    fn reportRuntimeError(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try std.fmt.format(self.error_writer, fmt, args);
        const instruction_index = @intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr) - 1;
        const line = try self.chunk.lines.get(instruction_index);
        try std.fmt.format(self.error_writer, "\n[line {d}] in script\n", .{line});
        self.stack.clear();
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
