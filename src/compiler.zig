const std = @import("std");
const scan = @import("scanner.zig");
const Scanner = scan.Scanner;
const Token = scan.Token;
const TokenType = scan.TokenType;
const bytecode = @import("bytecode.zig");
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const GarbageCollector = @import("gc.zig");
const object = @import("object.zig");

error_writer: std.io.AnyWriter,
compilingChunk: *bytecode.Chunk,
tokens: Scanner,
parser: Parser,
gc: *GarbageCollector,

const Parser = struct {
    previous: Token = undefined,
    current: Token = undefined,
    panic_mode: bool = false,
    had_error: bool = false,
};

const Precedence = enum {
    none,
    assignment,
    disjunction,
    conjunction,
    equality,
    comparison,
    sum,
    product,
    unary,
    call,
    primary,

    inline fn isGreaterThan(self: Precedence, other: Precedence) bool {
        return @intFromEnum(self) <= @intFromEnum(other);
    }
};

const ParserRule = struct {
    prefix: ?*const fn (*Self) anyerror!void,
    infix: ?*const fn (*Self) anyerror!void,
    precedence: Precedence,
};

inline fn getRule(token_type: TokenType) ParserRule {
    const number_of_tokens = @typeInfo(TokenType).Enum.fields.len;
    comptime var rules: [number_of_tokens]ParserRule = undefined;
    comptime {
        for (std.enums.values(TokenType)) |token| {
            const rule = switch (token) {
                .left_paren => .{ grouping, null, .none },
                .minus => .{ unary, binary, .sum },
                .plus => .{ null, binary, .sum },
                .slash => .{ null, binary, .product },
                .star => .{ null, binary, .product },
                .number => .{ number, null, .none },
                .string => .{ string, null, .none },
                .kw_nil => .{ literal, null, .none },
                .kw_true => .{ literal, null, .none },
                .kw_false => .{ literal, null, .none },
                .bang => .{ unary, null, .none },
                .equal_equal => .{ null, binary, .equality },
                .bang_equal => .{ null, binary, .equality },
                .less => .{ null, binary, .comparison },
                .greater => .{ null, binary, .comparison },
                .less_equal => .{ null, binary, .comparison },
                .greater_equal => .{ null, binary, .comparison },
                else => .{ null, null, .none },
            };
            rules[@intFromEnum(token)] = .{
                .prefix = rule.@"0",
                .infix = rule.@"1",
                .precedence = rule.@"2",
            };
        }
    }
    return rules[@intFromEnum(token_type)];
}

const Self = @This();

pub fn init(
    chunk: *bytecode.Chunk,
    error_writer: std.io.AnyWriter,
    gc: *GarbageCollector,
) Self {
    return Self{
        .gc = gc,
        .error_writer = error_writer,
        .compilingChunk = chunk,
        .parser = Parser{},
        .tokens = undefined,
    };
}

pub fn compile(self: *Self, source_code: []const u8) !void {
    self.tokens = Scanner.init(source_code);
    try self.advance();
    try self.expression();
    try self.consume(.eof, "Expected end of expression.");
    try self.endCompilation();
}

fn advance(self: *Self) !void {
    self.parser.previous = self.parser.current;
    while (true) {
        self.parser.current = self.tokens.next();
        if (self.parser.current.type != .scanning_error) break;
        try self.errorAtCurrent(self.parser.current.lexeme);
    }
}

fn errorAtPrevious(self: *Self, message: []const u8) !void {
    try self.errorAt(self.parser.previous, message);
}

fn errorAtCurrent(self: *Self, message: []const u8) !void {
    try self.errorAt(self.parser.current, message);
}

fn errorAt(self: *Self, token: Token, message: []const u8) !void {
    if (self.parser.panic_mode) return;
    try self.errPrint("[line {d}] Error", .{token.line});

    if (token.type == .eof) {
        try self.errPrint(" at end", .{});
    } else if (token.type == .scanning_error) {} else {
        try self.errPrint(" at '{s}'", .{token.lexeme});
    }

    try self.errPrint(": {s}\n", .{message});
    self.parser.had_error = true;
}

fn errPrint(self: Self, comptime fmt: []const u8, args: anytype) !void {
    try std.fmt.format(self.error_writer, fmt, args);
}

inline fn currentChunk(self: Self) *bytecode.Chunk {
    return self.compilingChunk;
}

fn consume(self: *Self, expected: TokenType, err_msg: []const u8) !void {
    if (self.parser.current.type == expected) {
        try self.advance();
        return;
    }
    try self.errorAtCurrent(err_msg);
}

fn expression(self: *Self) !void {
    try self.parsePrecedence(.assignment);
}

fn parsePrecedence(self: *Self, precedence: Precedence) !void {
    try self.advance();
    const prefix_rule = getRule(self.parser.previous.type).prefix;
    if (prefix_rule == null) {
        try self.errorAtPrevious("Expected expression.");
        return;
    }

    try prefix_rule.?(self);

    while (precedence.isGreaterThan(getRule(self.parser.current.type).precedence)) {
        try self.advance();
        const infix_rule = getRule(self.parser.previous.type).infix;
        try infix_rule.?(self);
    }
}

fn unary(self: *Self) !void {
    const operator = self.parser.previous;

    try self.parsePrecedence(.unary);

    switch (operator.type) {
        .minus => try self.emitInstruction(.negate, operator.line),
        .bang => try self.emitInstruction(.not, operator.line),
        else => unreachable,
    }
}

fn binary(self: *Self) !void {
    const operator = self.parser.previous;
    const rule = getRule(operator.type);
    try self.parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));
    const instruction: bytecode.Instruction = switch (operator.type) {
        .plus => .add,
        .minus => .subtract,
        .star => .multiply,
        .slash => .divide,
        .equal_equal => .equal,
        .bang_equal => .not_equal,
        .less => .less_than,
        .greater => .greater_than,
        .less_equal => .less_or_equal,
        .greater_equal => .greater_or_equal,
        else => unreachable,
    };
    try self.emitInstruction(instruction, operator.line);
}

fn literal(self: *Self) !void {
    const token = self.parser.previous;
    const opcode: bytecode.Instruction = switch (token.type) {
        .kw_nil => .nil,
        .kw_true => .true,
        .kw_false => .false,
        else => unreachable,
    };
    try self.emitInstruction(opcode, token.line);
}

fn string(self: *Self) !void {
    const lexeme = self.parser.previous.lexeme;
    const text = lexeme[1 .. lexeme.len - 1];
    const obj = try self.gc.makeObject(.const_string);
    obj.as(object.String).text = text;
    try self.emitConstant(.{ .object = obj });
}

fn number(self: *Self) !void {
    const value = std.fmt.parseFloat(f64, self.parser.previous.lexeme) catch unreachable;
    try self.emitConstant(.{ .number = value });
}

fn emitConstant(self: *Self, value: Value) !void {
    const index = try self.currentChunk().addConstant(value);
    if (index > std.math.maxInt(u24)) {
        try self.errorAtPrevious("Too many constants in one chunk.");
    } else if (index > std.math.maxInt(u8)) {
        try self.emitInstruction(.{ .long_con = @intCast(index) }, self.parser.previous.line);
    } else {
        try self.emitInstruction(.{ .constant = @intCast(index) }, self.parser.previous.line);
    }
}

fn grouping(self: *Self) !void {
    try self.expression();
    try self.consume(.right_paren, "Expected ')' after expression.");
}

inline fn endCompilation(self: *Self) !void {
    try self.emitReturn();
    debug.disassembleChunk(self.currentChunk().*, "code");
}

inline fn emitReturn(self: *Self) !void {
    try self.emitInstruction(.ret, self.parser.previous.line);
}

inline fn emitInstruction(
    self: *Self,
    instruction: bytecode.Instruction,
    line: usize,
) !void {
    try self.currentChunk().writeInstruction(instruction, line);
}
