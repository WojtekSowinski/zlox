const std = @import("std");
const objects = @import("object.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const VM = vm.VM;
const values = @import("value.zig");
const Value = values.Value;
const String = objects.String;

pub const LoxFunction = struct {
    obj: objects.Obj,
    arity: u8,
    chunk: bytecode.Chunk,
    name: ?[]const u8,
    up_value_count: u9,
};

pub const Closure = struct {
    obj: objects.Obj,
    function: *LoxFunction,
};

pub const NativeFunction = struct {
    obj: objects.Obj,
    apply: *const NativeFn,
};

pub const NativeFn = fn (*VM, []Value) anyerror!Value;

pub fn clock(machine: *VM, args: []Value) !Value {
    _ = args;
    return .{ .number = @floatFromInt(std.Io.Timestamp.now(machine.io, .cpu_process).toSeconds()) };
}

pub fn max(machine: *VM, args: []Value) !Value {
    var result: f64 = 0;
    for (args) |arg| {
        switch (arg) {
            .number => |n| if (n > result) {
                result = n;
            },
            else => {
                try machine.reportRuntimeError("Arguments to max must be numbers.", .{});
                return error.TypeError;
            },
        }
    }
    return .{ .number = result };
}

pub fn str(machine: *VM, args: []Value) !Value {
    if (args.len != 1) {
        try machine.reportRuntimeError("Expected 1 argument but got {d}.", .{args.len});
        return error.IncorrectArity;
    }
    var string_builder = std.Io.Writer.Allocating.init(machine.gc.allocator());
    defer string_builder.deinit();
    try args[0].print(&string_builder.writer);
    const result = try machine.gc.copyString(string_builder.written());
    return .{ .object = &result.obj };
}

pub fn input(machine: *VM, args: []Value) !Value {
    if (args.len != 1) {
        try machine.reportRuntimeError("Expected 1 argument but got {d}.", .{args.len});
        return error.IncorrectArity;
    }
    if (!args[0].isString()) {
        try machine.reportRuntimeError("Input prompt must be a string.", .{});
        return error.TypeError;
    }
    try args[0].print(machine.output_writer);
    try machine.output_writer.flush();
    var string_builder = std.Io.Writer.Allocating.init(machine.gc.allocator());
    defer string_builder.deinit();
    _ = try machine.input_reader.streamDelimiterEnding(&string_builder.writer, '\n');
    _ = try machine.input_reader.discardShort(1);
    const result = try machine.gc.copyString(string_builder.written());
    return .{ .object = &result.obj };
}

pub fn num(machine: *VM, args: []Value) !Value {
    if (args.len != 1) {
        try machine.reportRuntimeError("Expected 1 argument but got {d}.", .{args.len});
        return error.IncorrectArity;
    }
    if (!args[0].isString()) {
        try machine.reportRuntimeError("Input prompt must be a string.", .{});
        return error.TypeError;
    }
    const arg = args[0].object.as(String);
    const result = std.fmt.parseFloat(f64, arg.text) catch return .nil;
    return .{ .number = result };
}
