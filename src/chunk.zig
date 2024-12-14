const std = @import("std");
const Value = @import("value.zig").Value;
const rle = @import("run-length-encoding.zig");

pub const OpCode = enum(u8) {
    ret,
    con,
};

pub const Instruction = union(OpCode) {
    ret: void,
    con: u8,

    pub fn size(self: Instruction) usize {
        switch (self) {
            .ret => return 1,
            .con => return 2,
        }
    }
};

pub const Chunk = struct {
    const Self = @This();
    const CodeArray = std.ArrayList(u8);
    const ValueArray = std.ArrayList(Value);
    const Lines = rle.RunLengthArray(usize);

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

    pub fn readInstruction(self: *Self, index: usize) Instruction {
        const opcode: OpCode = @enumFromInt(self.code.items[index]);
        switch (opcode) {
            .ret => return .ret,
            .con => {
                const valIndex = self.code.items[index + 1];
                return .{ .con = valIndex };
            },
        }
    }

    pub fn writeInstruction(
        self: *Self,
        instruction: Instruction,
        line: usize,
    ) !void {
        try self.write(@intFromEnum(instruction));
        errdefer self.pop();
        switch (instruction) {
            .con => |index| {
                try self.write(index);
                errdefer self.pop();
            },
            else => {},
        }
        try self.lines.append(line, instruction.size());
    }

    fn write(self: *Self, byte: u8) !void {
        try self.code.append(byte);
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
    try chunk.writeInstruction(.ret);
    try std.testing.expectEqual(@intFromEnum(Instruction.ret), chunk.code[0]);
}

test "reading a one-byte instruction from a chunk" {
    var chunk = try Chunk.init(std.testing.allocator);
    defer chunk.deinit();
    try chunk.writeInstruction(.ret);
    try std.testing.expectEqual(.ret, chunk.readInstruction(0));
}
