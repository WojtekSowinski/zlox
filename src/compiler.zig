const std = @import("std");
const scan = @import("scanner.zig");
const Scanner = scan.Scanner;
const Token = scan.Token;
const TokenType = scan.TokenType;
const bytecode = @import("bytecode.zig");
const OpCode = bytecode.OpCode;
const Instruction = bytecode.Instruction;
const Value = @import("value.zig").Value;
const debug = @import("debug.zig");
const GarbageCollector = @import("gc.zig");
const object = @import("object.zig");
const config = @import("build_config");

error_writer: *std.Io.Writer,
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
    prefix: ?*const fn (*Self, bool) anyerror!void,
    infix: ?*const fn (*Self, bool) anyerror!void,
    precedence: Precedence,
};

inline fn getRule(token_type: TokenType) ParserRule {
    const number_of_tokens = @typeInfo(TokenType).@"enum".fields.len;
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
                .identifier => .{ variable, null, .none },
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
    error_writer: *std.Io.Writer,
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
    while (!try self.match(.eof)) try self.statement();
    try self.endCompilation();
    if (self.parser.had_error) return error.CompilerError;
}

fn advance(self: *Self) !void {
    self.parser.previous = self.parser.current;
    while (true) {
        self.parser.current = self.tokens.next();
        if (self.parser.current.type != .scanning_error) break;
        try self.errorAtCurrent(self.parser.current.lexeme);
    }
}

fn match(self: *Self, token_type: TokenType) !bool {
    if (!self.checkFor(token_type)) return false;
    try self.advance();
    return true;
}

inline fn checkFor(self: Self, token_type: TokenType) bool {
    return self.parser.current.type == token_type;
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
    try self.error_writer.print(fmt, args);
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

fn synchronize(self: *Self) !void {
    self.parser.panic_mode = false;
    while (self.parser.current.type != .eof) {
        if (self.parser.previous.type == .semicolon) return;
        switch (self.parser.current.type) {
            .kw_class,
            .kw_fun,
            .kw_var,
            .kw_for,
            .kw_if,
            .kw_while,
            .kw_print,
            .kw_return,
            => return,
            else => continue,
        }
        try self.advance();
    }
}

inline fn useConstantsArray(self: *Self, comptime short: OpCode, comptime long: OpCode, index: usize) !void {
    std.debug.assert(index <= std.math.maxInt(u24));
    const instruction = if (index <= std.math.maxInt(u8))
        @unionInit(Instruction, @tagName(short), @intCast(index))
    else
        @unionInit(Instruction, @tagName(long), @intCast(index));
    try self.emitInstruction(instruction, self.parser.previous.line);
}

fn statement(self: *Self) !void {
    if (try self.match(.kw_var)) {
        try self.varDeclaration();
    } else {
        try self.command();
    }

    if (self.parser.panic_mode) try self.synchronize();
}

fn command(self: *Self) !void {
    if (try self.match(.semicolon)) return;

    if (try self.match(.kw_print)) {
        try self.printStatement();
    } else {
        try self.expressionStatement();
    }
}

fn varDeclaration(self: *Self) !void {
    const id = try self.parseIdentifier("Expected variable name.");
    if (try self.match(.equal)) {
        try self.expression();
    } else {
        try self.emitInstruction(.nil, self.parser.previous.line);
    }

    try self.consume(.semicolon, "Expected ';' after variable declaration.");
    try self.defineVariable(id);
}

fn parseIdentifier(self: *Self, err_msg: []const u8) !usize {
    try self.consume(.identifier, err_msg);
    return self.makeIdentifier(self.parser.previous);
}

fn makeIdentifier(self: *Self, token: Token) !usize {
    const str = try self.gc.copyString(token.lexeme);
    return self.makeConstant(.{ .object = &str.obj });
}

fn defineVariable(self: *Self, id_index: usize) !void {
    try self.useConstantsArray(.def_global, .long_def_global, id_index);
}

fn printStatement(self: *Self) !void {
    try self.expression();
    try self.consume(.semicolon, "Expected ';' after a print statement.");
    try self.emitInstruction(.print, self.parser.previous.line);
}

fn expressionStatement(self: *Self) !void {
    try self.expression();
    try self.consume(.semicolon, "Expected ';' after an expression.");
    try self.emitInstruction(.pop, self.parser.previous.line);
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

    const can_assign = precedence.isGreaterThan(.assignment);
    try prefix_rule.?(self, can_assign);

    while (precedence.isGreaterThan(getRule(self.parser.current.type).precedence)) {
        try self.advance();
        const infix_rule = getRule(self.parser.previous.type).infix;
        try infix_rule.?(self, can_assign);
    }

    if (can_assign and try self.match(.equal)) try self.errorAtPrevious("Invalid assignment target.");
}

fn unary(self: *Self, can_assign: bool) !void {
    _ = can_assign;
    const operator = self.parser.previous;

    try self.parsePrecedence(.unary);

    switch (operator.type) {
        .minus => try self.emitInstruction(.negate, operator.line),
        .bang => try self.emitInstruction(.not, operator.line),
        else => unreachable,
    }
}

fn binary(self: *Self, can_assign: bool) !void {
    _ = can_assign;
    const operator = self.parser.previous;
    const rule = getRule(operator.type);
    try self.parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));
    const instruction: Instruction = switch (operator.type) {
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

fn literal(self: *Self, can_assign: bool) !void {
    _ = can_assign;
    const token = self.parser.previous;
    const opcode: Instruction = switch (token.type) {
        .kw_nil => .nil,
        .kw_true => .true,
        .kw_false => .false,
        else => unreachable,
    };
    try self.emitInstruction(opcode, token.line);
}

fn variable(self: *Self, can_assign: bool) !void {
    try self.emitVariable(self.parser.previous, can_assign);
}

fn emitVariable(self: *Self, name: Token, can_assign: bool) !void {
    const arg = try self.makeIdentifier(name);
    if (can_assign and try self.match(.equal)) {
        try self.expression();
        try self.useConstantsArray(.set_global, .long_set_global, arg);
    } else {
        try self.useConstantsArray(.get_global, .long_get_global, arg);
    }
}

fn string(self: *Self, can_assign: bool) !void {
    _ = can_assign;
    const lexeme = self.parser.previous.lexeme;
    const text = lexeme[1 .. lexeme.len - 1];
    const obj = &((try self.gc.borrowString(text)).obj);
    errdefer self.gc.deleteObject(obj);
    try self.emitConstant(.{ .object = obj });
}

fn number(self: *Self, can_assign: bool) !void {
    _ = can_assign;
    const value = std.fmt.parseFloat(f64, self.parser.previous.lexeme) catch unreachable;
    try self.emitConstant(.{ .number = value });
}

fn makeConstant(self: *Self, value: Value) !usize {
    const index = try self.currentChunk().addConstant(value);
    if (index > std.math.maxInt(u24)) try self.errorAtPrevious("Too many constants in one chunk.");
    return index;
}

fn emitConstant(self: *Self, value: Value) !void {
    const index = try self.makeConstant(value);
    return try self.useConstantsArray(.constant, .long_constant, index);
}

fn grouping(self: *Self, can_assign: bool) !void {
    _ = can_assign;
    try self.expression();
    try self.consume(.right_paren, "Expected ')' after expression.");
}

inline fn endCompilation(self: *Self) !void {
    try self.emitReturn();
    if (config.disassemble) debug.disassembleChunk(self.currentChunk().*, "code");
}

inline fn emitReturn(self: *Self) !void {
    try self.emitInstruction(.ret, self.parser.previous.line);
}

inline fn emitInstruction(
    self: *Self,
    instruction: Instruction,
    line: usize,
) !void {
    try self.currentChunk().writeInstruction(instruction, line);
}
