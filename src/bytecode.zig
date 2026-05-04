const std = @import("std");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const String = @import("object.zig").String;
const RunLengthArray = @import("run-length-encoding.zig").RunLengthArray;
const HashTable = @import("hash_table.zig").HashTable;

pub const OpCode = std.meta.Tag(Instruction);

pub const Instruction = union(enum) {
    constant: u8,
    long_constant: u24,

    def_global: u8,
    get_global: u8,
    set_global: u8,

    long_def_global: u24,
    long_get_global: u24,
    long_set_global: u24,

    negate,
    add,
    multiply,
    subtract,
    divide,
    not,

    nil,
    true,
    false,

    equal,
    not_equal,
    less_than,
    greater_than,
    less_or_equal,
    greater_or_equal,

    print,
    pop,
    ret,

    const Self = @This();

    pub fn size(self: Instruction) usize {
        return switch (self) {
            .constant, .def_global, .get_global, .set_global => 2,
            .long_constant, .long_def_global, .long_get_global, .long_set_global => 4,
            else => 1,
        };
    }

    pub fn readFrom(ptr: [*]const u8) Self {
        const opcode: OpCode = @enumFromInt(ptr[0]);
        switch (opcode) {
            inline .long_constant, .long_def_global, .long_get_global, .long_set_global => |tag| {
                const index = std.mem.bytesToValue(u24, ptr[1..4]);
                return @unionInit(Self, @tagName(tag), index);
            },
            inline .constant, .def_global, .get_global, .set_global => |tag| {
                const index = ptr[1];
                return @unionInit(Self, @tagName(tag), index);
            },
            inline else => |tag| {
                return @unionInit(Self, @tagName(tag), {});
            },
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
        var code = try CodeArray.initCapacity(allocator, 8);
        errdefer code.deinit(allocator);
        const lines = try Lines.init(allocator);
        return Chunk{
            .allocator = allocator,
            .code = code,
            .constants = ValueArray.empty,
            .lines = lines,
        };
    }

    pub fn deinit(self: *Self) void {
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
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
            .constant, .def_global, .get_global, .set_global => |index| {
                try self.write(index);
                errdefer self.pop();
            },
            .long_constant, .long_def_global, .long_get_global, .long_set_global => |index| {
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
        try self.code.append(self.allocator, byte);
    }

    fn writeMany(self: *Self, bytes: []const u8) !void {
        try self.code.appendSlice(self.allocator, bytes);
    }

    fn pop(self: *Self) void {
        _ = self.code.pop();
    }

    pub fn addConstant(self: *Self, value: Value) !usize {
        for (self.constants.items, 0..) |item, i| {
            if (item.equals(value)) return i;
        }
        try self.constants.append(self.allocator, value);
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
