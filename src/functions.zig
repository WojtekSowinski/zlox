const objects = @import("object.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const values = @import("value.zig");
const Value = values.Value;

pub const LoxFunction = struct {
    obj: objects.Obj,
    arity: u8,
    chunk: bytecode.Chunk,
    name: ?[]const u8,
};

pub const NativeFunction = struct {
    obj: objects.Obj,
    apply: *const NativeFn,
};

pub const NativeFn = fn (*vm.VM, []Value) Value;

pub fn clock(machine: *vm.VM, args: []Value) Value {
    _ = machine;
    _ = args;
    return .{ .number = 42 }; // TODO: implement an actual clock (vm may need to store an io instance);
}

pub fn sum(machine: *vm.VM, args: []Value) Value {
    _ = machine;
    var total: f64 = 0;
    for (args) |arg| {
        switch (arg) {
            .number => |n| total += n,
            else => {}, // TODO: allow native functions to return errors;
        }
    }
    return .{ .number = total };
}

// TODO: implement the following native functions:
// - str() converts argument to a string
// - input() prints argument (without line break), reads a line of input
// - num() parses a number from a string
