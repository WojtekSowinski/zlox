const std = @import("std");
const scan = @import("scanner.zig");
const Scanner = scan.Scanner;
const Token = scan.Token;
const TokenType = scan.TokenType;
const bytecode = @import("bytecode.zig");

error_writer: std.io.AnyWriter,
compilingChunk: *bytecode.Chunk,
tokens: Scanner,
parser: Parser,

const Parser = struct {
    previous: Token = undefined,
    current: Token = undefined,
    panic_mode: bool = false,
    had_error: bool = false,
};

const Self = @This();

pub fn init(chunk: *bytecode.Chunk, error_writer: std.io.AnyWriter) Self {
    return Self{
        .error_writer = error_writer,
        .compilingChunk = chunk,
        .parser = Parser{},
        .tokens = undefined,
    };
}

pub fn compile(self: *Self, source_code: []const u8) !void {
    self.tokens = Scanner.init(source_code);
    try self.advance();
    self.expression();
    try self.consume(.eof, "Expected end of expression.");
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

fn consume(self: *Self, expected: TokenType, err_msg: []const u8) !void {
    if (self.parser.current.type == expected) {
        try self.advance();
        return;
    }
    try self.errorAtCurrent(err_msg);
}

fn expression(self: *Self) void {
    _ = self;
}
