const std = @import("std");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const String = @import("object.zig").String;
const RunLengthArray = @import("run-length-encoding.zig").RunLengthArray;
const HashTable = @import("hash_table.zig").HashTable;

pub const OpCode = std.meta.Tag(Instruction);

pub const ShortIndex = u8;
pub const LongIndex = u24;
pub const MAX_SHORT_INDEX = std.math.maxInt(ShortIndex);
pub const MAX_LONG_INDEX = std.math.maxInt(LongIndex);

pub const JumpDistance = u16;
pub const JUMP_DISTANCE_SIZE = 2;
pub const MAX_JUMP = std.math.maxInt(JumpDistance);

pub const Instruction = union(enum) {
    constant: ShortIndex,
    long_constant: LongIndex,

    def_global: ShortIndex,
    get_global: ShortIndex,
    set_global: ShortIndex,
    long_def_global: LongIndex,
    long_get_global: LongIndex,
    long_set_global: LongIndex,

    set_local: ShortIndex,
    get_local: ShortIndex,
    long_set_local: LongIndex,
    long_get_local: LongIndex,

    jump: JumpDistance,
    jump_back: JumpDistance,
    jump_if_falsey: JumpDistance,
    jump_if_truthy: JumpDistance,

    pop,
    pop_many: ShortIndex,
    long_pop_many: LongIndex,

    call: u8,

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
    ret,

    const Self = @This();

    pub fn size(self: Instruction) usize {
        return switch (self) {
            .constant,
            .def_global,
            .get_global,
            .set_global,
            .get_local,
            .set_local,
            .pop_many,
            .call,
            => 2,
            .long_constant,
            .long_def_global,
            .long_get_global,
            .long_set_global,
            .long_get_local,
            .long_set_local,
            .long_pop_many,
            => 4,
            .jump,
            .jump_back,
            .jump_if_falsey,
            .jump_if_truthy,
            => 3,
            else => 1,
        };
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

    pub inline fn readInstruction(self: Self, offset: usize) Instruction {
        const ptr: [*]const u8 = (@ptrFromInt(@intFromPtr(self.code.items.ptr) + offset));
        const opcode: OpCode = @enumFromInt(ptr[0]);
        switch (opcode) {
            inline .long_constant,
            .long_def_global,
            .long_get_global,
            .long_set_global,
            .long_get_local,
            .long_set_local,
            .long_pop_many,
            => |tag| {
                const index = (@as(LongIndex, ptr[1]) << 16) | (@as(LongIndex, ptr[2]) << 8) | ptr[3];
                return @unionInit(Instruction, @tagName(tag), index);
            },
            inline .constant,
            .def_global,
            .get_global,
            .set_global,
            .get_local,
            .set_local,
            .pop_many,
            .call,
            => |tag| {
                const index = ptr[1];
                return @unionInit(Instruction, @tagName(tag), index);
            },
            inline .jump,
            .jump_back,
            .jump_if_falsey,
            .jump_if_truthy,
            => |tag| {
                const distance = (@as(JumpDistance, ptr[1]) << 8) | ptr[2];
                return @unionInit(Instruction, @tagName(tag), distance);
            },
            inline else => |tag| {
                return @unionInit(Instruction, @tagName(tag), {});
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
            .constant,
            .def_global,
            .get_global,
            .set_global,
            .get_local,
            .set_local,
            .pop_many,
            .call,
            => |index| {
                try self.write(index);
            },
            .long_constant,
            .long_def_global,
            .long_get_global,
            .long_set_global,
            .long_get_local,
            .long_set_local,
            .long_pop_many,
            => |index| {
                const new_bytes = try self.code.addManyAsArray(self.allocator, 3);
                new_bytes[0] = @truncate(index >> 16);
                new_bytes[1] = @truncate(index >> 8);
                new_bytes[2] = @truncate(index);
            },
            .jump,
            .jump_back,
            .jump_if_falsey,
            .jump_if_truthy,
            => |index| {
                const new_bytes = try self.code.addManyAsArray(self.allocator, 2);
                new_bytes[0] = @truncate(index >> 8);
                new_bytes[1] = @truncate(index);
            },
            else => {},
        }
        errdefer self.code.shrinkRetainingCapacity(instruction.size() - 1);
        try self.lines.append(line, instruction.size());
    }

    fn write(self: *Self, byte: u8) !void {
        try self.code.append(self.allocator, byte);
    }

    pub fn patchJump(self: *Self, jump_location: usize, distance: JumpDistance) void {
        std.debug.assert(distance <= MAX_JUMP);
        self.code.items[jump_location] = @truncate(distance >> 8);
        self.code.items[jump_location + 1] = @truncate(distance);
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
