const std = @import("std");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const RunLengthArray = @import("run-length-encoding.zig").RunLengthArray;

pub const OpCode = std.meta.Tag(Instruction);

pub const Instruction = union(enum) {
    ret,
    constant: u8,
    long_con: u24,
    negate,
    add,
    multiply,
    subtract,
    divide,
    nil,
    true,
    false,
    not,
    equal,
    not_equal,
    less_than,
    greater_than,
    less_or_equal,
    greater_or_equal,
    print,
    pop,

    const Self = @This();

    pub fn size(self: Instruction) usize {
        return switch (self) {
            .constant => 2,
            .long_con => 4,
            else => 1,
        };
    }

    pub fn readFrom(ptr: [*]const u8) Self {
        const opcode: OpCode = @enumFromInt(ptr[0]);
        switch (opcode) {
            .constant => {
                const valIndex = ptr[1];
                return .{ .constant = valIndex };
            },
            .long_con => {
                const valIndex = std.mem.bytesToValue(u24, ptr[1..4]);
                return .{ .long_con = valIndex };
            },
            inline else => |tag| return std.enums.nameCast(Instruction, tag),
        }
    }
};

pub const Chunk = struct {
    const Self = @This();
    const CodeArray = std.ArrayList(u8);
    const ValueArray = std.ArrayList(Value);
    const Lines = RunLengthArray(usize);

    code: CodeArray,
    constants: ValueArray,
    lines: Lines,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Chunk {
        const code = try CodeArray.initCapacity(allocator, 8);
        errdefer code.deinit();
        const lines = try Lines.init(allocator);
        return Chunk{
            .allocator = allocator,
            .code = code,
            .constants = ValueArray.init(allocator),
            .lines = lines,
        };
    }

    pub fn deinit(self: *Self) void {
        self.code.deinit();
        self.constants.deinit();
        self.lines.deinit();
    }

    pub inline fn readInstruction(self: Self, index: usize) Instruction {
        return Instruction.readFrom(@ptrFromInt(@intFromPtr(self.code.items.ptr) + index));
    }

    pub fn writeInstruction(
        self: *Self,
        instruction: Instruction,
        line: usize,
    ) !void {
        try self.write(@intFromEnum(instruction));
        errdefer self.pop();
        switch (instruction) {
            .constant => |index| {
                try self.write(index);
                errdefer self.pop();
            },
            .long_con => |index| {
                const bytes = std.mem.toBytes(index);
                if (comptime builtin.cpu.arch.endian() == .little) {
                    try self.writeMany(bytes[0..3]);
                } else {
                    try self.writeMany(bytes[1..]);
                }
                errdefer for (0..3) |_| self.pop();
            },
            else => {},
        }
        try self.lines.append(line, instruction.size());
    }

    fn write(self: *Self, byte: u8) !void {
        try self.code.append(byte);
    }

    fn writeMany(self: *Self, bytes: []const u8) !void {
        try self.code.appendSlice(bytes);
    }

    fn pop(self: *Self) void {
        _ = self.code.pop();
    }

    pub fn addConstant(self: *Self, value: Value) !usize {
        try self.constants.append(value);
        return self.constants.items.len - 1;
    }

    pub inline fn length(self: Self) usize {
        return self.code.items.len;
    }
};

test "initializing and writing an opcode to a chunk" {
    var chunk = try Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    try chunk.writeInstruction(.ret, 1);
    try std.testing.expectEqual(@intFromEnum(Instruction.ret), chunk.code.items[0]);
}

test "reading a one-byte instruction from a chunk" {
    var chunk = try Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    try chunk.writeInstruction(.ret, 1);
    try std.testing.expectEqual(.ret, chunk.readInstruction(0));
}
