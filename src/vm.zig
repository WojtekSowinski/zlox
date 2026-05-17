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
const LoxGarbageCollector = @import("gc.zig");
const object = @import("object.zig");
const String = object.String;
const HashTable = @import("hash_table.zig").HashTable;
const functions = @import("functions.zig");
const LoxFunction = functions.LoxFunction;
const NativeFunction = functions.NativeFunction;
const NativeFn = functions.NativeFn;

fn emptyRead(context: *const anyopaque, buffer: []u8) !usize {
    _ = context;
    _ = buffer;
    return 0;
}

const CallFrame = struct {
    function: *LoxFunction,
    ip: usize,
    base_index: usize,
};

pub const GlobalVarStore = struct {
    values: std.ArrayList(Value),
    names: std.ArrayList(*String),
    is_assigned: std.bit_set.DynamicBitSetUnmanaged,
    allocator: std.mem.Allocator,

    const Self = @This();
    const Table = HashTable(*String, usize, String.getHash, String.equals);

    pub fn init(allocator: std.mem.Allocator) !Self {
        const capacity = 256;
        var values = try std.ArrayList(Value).initCapacity(allocator, capacity);
        errdefer values.deinit(allocator);
        var names = try std.ArrayList(*String).initCapacity(allocator, capacity);
        errdefer names.deinit(allocator);
        const is_assigned = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, capacity);
        return .{ .names = names, .values = values, .is_assigned = is_assigned, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.names.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.is_assigned.deinit(self.allocator);
    }

    pub fn getIndexOrCreate(self: *Self, key: *String) !usize {
        for (self.names.items, 0..) |name, i| if (key == name) return i;

        const new_index = self.values.items.len;
        try self.values.append(self.allocator, .nil);
        errdefer _ = self.values.pop();
        try self.names.append(self.allocator, key);
        errdefer _ = self.names.pop();
        if (self.values.capacity > self.is_assigned.capacity()) {
            try self.is_assigned.resize(self.allocator, self.values.capacity, false);
        }

        return new_index;
    }

    pub fn getValueAt(self: Self, i: usize) ?Value {
        return if (self.is_assigned.isSet(i)) self.values.items[i] else null;
    }

    pub fn assignValue(self: *Self, i: usize, val: Value) void {
        self.values.items[i] = val;
        self.is_assigned.set(i);
    }

    pub fn getNameAt(self: Self, i: usize) *String {
        return self.names.items[i];
    }
};

pub const VM = struct {
    stack: Stack(Value),
    globals: GlobalVarStore,
    frames: Stack(CallFrame),

    io: std.Io,
    input_reader: *std.Io.Reader,
    output_writer: *std.Io.Writer,
    error_writer: *std.Io.Writer,

    gc: LoxGarbageCollector,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        input_source: *std.Io.Reader,
        output_sink: *std.Io.Writer,
        error_sink: *std.Io.Writer,
    ) !Self {
        var gc = try LoxGarbageCollector.init(allocator);
        errdefer gc.deinit();
        var globals = try GlobalVarStore.init(allocator);
        errdefer globals.deinit();
        var stack = try Stack(Value).init(allocator, 256);
        errdefer stack.deinit();
        const frames = try Stack(CallFrame).init(allocator, 64);
        var vm: Self = .{
            .gc = gc,
            .globals = globals,
            .stack = stack,
            .frames = frames,
            .io = io,
            .input_reader = input_source,
            .output_writer = output_sink,
            .error_writer = error_sink,
        };
        try vm.defineNativeFunction("clock", functions.clock);
        try vm.defineNativeFunction("max", functions.max);
        try vm.defineNativeFunction("str", functions.str);
        try vm.defineNativeFunction("input", functions.input);
        try vm.defineNativeFunction("num", functions.num);
        return vm;
    }

    pub fn interpret(self: *Self, source_code: []const u8) !void {
        var compiler = try Compiler.init(self.error_writer, &self.gc, &self.globals);
        defer compiler.deinit();
        const function = try compiler.compile(source_code);

        try self.stack.push(.{ .object = &function.obj });
        try self.callLoxFunction(function, 0);
        try self.run();
        //_ = self.stack.pop();
    }

    fn run(self: *Self) !void {
        var frame = self.frames.getRef(0);
        while (true) {
            const instruction = frame.function.chunk.readInstruction(frame.ip);
            if (config.trace_execution) {
                debug.logStack(self.*);
                std.debug.print("{d:0>4} : ", .{frame.ip});
                debug.disassembleInstruction(instruction, frame.function.chunk);
            }
            frame.ip += instruction.size();
            switch (instruction) {
                .print => {
                    try self.stack.pop().print(self.output_writer);
                    try self.output_writer.writeByte('\n');
                },

                .pop => _ = self.stack.pop(),
                .pop_many, .long_pop_many => |amount| {
                    self.stack.shrinkBy(amount);
                },

                .true => try self.stack.push(.{ .boolean = true }),
                .false => try self.stack.push(.{ .boolean = false }),
                .nil => try self.stack.push(.nil),

                .constant, .long_constant => |index| {
                    const constant: Value = self.readConstant(index);
                    try self.stack.push(constant);
                },

                .def_global, .long_def_global => |index| {
                    self.globals.assignValue(index, self.stack.pop());
                },

                .get_global, .long_get_global => |index| {
                    if (self.globals.getValueAt(index)) |val| {
                        try self.stack.push(val);
                    } else {
                        const name = self.globals.getNameAt(index);
                        try self.reportRuntimeError("Undefined variable '{s}'", .{name.text});
                        return error.UndefinedVariable;
                    }
                },

                .set_global, .long_set_global => |index| {
                    if (self.globals.getValueAt(index)) |_| {
                        self.globals.assignValue(index, self.stack.peek(0));
                    } else {
                        const name = self.globals.getNameAt(index);
                        try self.reportRuntimeError("Undefined variable '{s}'", .{name.text});
                        return error.UndefinedVariable;
                    }
                },

                .get_local, .long_get_local => |index| {
                    try self.stack.push(self.stack.array[frame.base_index + index]);
                },

                .set_local, .long_set_local => |index| {
                    self.stack.array[frame.base_index + index] = self.stack.peek(0);
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

                .jump => |distance| frame.ip += distance,
                .jump_back => |distance| frame.ip -= distance,
                .jump_if_falsey => |distance| {
                    if (self.stack.peek(0).isFalsey()) frame.ip += distance;
                },
                .jump_if_truthy => |distance| {
                    if (self.stack.peek(0).isTruthy()) frame.ip += distance;
                },

                .call => |arg_count| {
                    try self.callValue(self.stack.peek(arg_count), arg_count);
                    frame = self.frames.getRef(0);
                },
                .ret => {
                    const result = self.stack.pop();
                    _ = self.frames.pop();
                    if (self.frames.count == 0) {
                        _ = self.stack.pop();
                        return;
                    }
                    self.stack.shrinkTo(frame.base_index);
                    try self.stack.push(result);
                    frame = self.frames.getRef(0);
                },
            }
        }
    }

    inline fn readConstant(self: Self, index: usize) Value {
        return self.frames.peek(0).function.chunk.constants.items[index];
    }

    inline fn readString(self: Self, index: usize) *String {
        return self.readConstant(index).object.as(String);
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
        op: fn (f64, f64) callconv(.@"inline") @FieldType(Value, @tagName(return_type)),
    ) !void {
        const right = self.stack.peek(0);
        const left = self.stack.peek(1);
        if (left.isNumber() and right.isNumber()) {
            _ = self.stack.pop();
            self.stack.swap(@unionInit(
                Value,
                @tagName(return_type),
                op(left.number, right.number),
            ));
        } else {
            try self.reportRuntimeError("Operands must be numbers.", .{});
            return error.TypeError;
        }
    }

    fn callValue(self: *Self, callee: Value, arg_count: u8) !void {
        if (callee.isObject()) {
            const obj = callee.object;
            switch (obj.type) {
                .lox_function => return self.callLoxFunction(obj.as(LoxFunction), arg_count),
                .native_function => {
                    const args = self.stack.topN(arg_count);
                    const result = try obj.as(NativeFunction).apply(self, args);
                    self.stack.shrinkBy(arg_count);
                    self.stack.swap(result);
                    return;
                },
                else => {},
            }
        }
        return error.TypeError;
    }

    pub fn defineNativeFunction(self: *Self, name: []const u8, function: *const NativeFn) !void {
        const name_str = try self.gc.copyString(name);
        try self.stack.push(.{ .object = &name_str.obj });
        const function_object = try self.gc.newNative(function);
        try self.stack.push(.{ .object = &function_object.obj });
        const index = try self.globals.getIndexOrCreate(name_str);
        self.globals.assignValue(index, self.stack.peek(0));
        self.stack.shrinkBy(2);
    }

    fn callLoxFunction(self: *Self, fun: *LoxFunction, arg_count: u8) !void {
        if (arg_count != fun.arity) {
            try self.reportRuntimeError("Expected {d} arguments but got {d}.", .{ fun.arity, arg_count });
            return error.IncorrectArity;
        }

        try self.frames.push(.{
            .function = fun,
            .ip = 0,
            .base_index = self.stack.count - arg_count - 1,
        });
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
        self.globals.deinit();
        self.frames.deinit();
        self.gc.deleteObjects();
        self.gc.deinit();
    }

    pub fn reportRuntimeError(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.error_writer.print("\nRuntime error: ", .{});
        try self.error_writer.print(fmt, args);

        try self.error_writer.writeByte('\n');
        for (0..self.frames.count) |i| {
            const frame = self.frames.peek(i);
            const function = frame.function;
            const instruction_index = frame.ip - 1;
            const line = try function.chunk.lines.get(instruction_index);
            const name = function.name orelse "script";
            try self.error_writer.print("[line {d}] in {s}()\n", .{ line, name });
        }

        self.stack.clear();
        self.frames.clear();
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
