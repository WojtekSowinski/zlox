const std = @import("std");

pub const Scanner = struct {
    start: [*]const u8,
    current: [*]const u8,
    end: [*]const u8,
    line: usize,

    const Self = @This();

    pub fn init(source_code: []const u8) Self {
        return .{
            .start = source_code.ptr,
            .current = source_code.ptr,
            .end = source_code.ptr + source_code.len,
            .line = 1,
        };
    }

    pub fn next(self: *Self) Token {
        self.skipWhitespace();
        self.start = self.current;
        if (self.isAtEnd()) return self.makeToken(.eof);

        const c = self.advance();
        if (isAlpha(c)) return self.identifier();
        if (isDigit(c)) return self.number();
        switch (c) {
            '(', ')', '{', '}', ';', ',', '.', '-', '+', '/', '*' => {
                return self.makeToken(@enumFromInt(c));
            },
            '!' => {
                const token_type: TokenType = if (self.match('=')) .bang_equal else .bang;
                return self.makeToken(token_type);
            },
            '=' => {
                const token_type: TokenType = if (self.match('=')) .equal_equal else .equal;
                return self.makeToken(token_type);
            },
            '<' => {
                const token_type: TokenType = if (self.match('=')) .less_equal else .less;
                return self.makeToken(token_type);
            },
            '>' => {
                const token_type: TokenType = if (self.match('=')) .greater_equal else .greater;
                return self.makeToken(token_type);
            },
            '"' => {
                return self.string();
            },
            else => {
                return self.errorToken("Unexpected character.");
            },
        }
    }

    fn identifier(self: *Self) Token {
        while (isAlpha(self.peek()) or isDigit(self.peek())) _ = self.advance();
        return self.makeToken(recogniseKeyword(self.currentLexeme()));
    }

    fn number(self: *Self) Token {
        while (isDigit(self.peek())) _ = self.advance();
        if (self.peek() == '.' and isDigit(self.peekNext())) {
            _ = self.advance();
            while (isDigit(self.peek())) _ = self.advance();
        }
        return self.makeToken(.number);
    }

    fn string(self: *Self) Token {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }
        if (self.isAtEnd()) return self.errorToken("Unterminated string.");
        _ = self.advance();
        return self.makeToken(.string);
    }

    inline fn makeToken(self: Self, token_type: TokenType) Token {
        return .{
            .type = token_type,
            .lexeme = self.currentLexeme(),
            .line = self.line,
        };
    }

    inline fn errorToken(self: Self, err_msg: []const u8) Token {
        return .{
            .type = .scanning_error,
            .lexeme = err_msg,
            .line = self.line,
        };
    }

    fn skipWhitespace(self: *Self) void {
        while (!self.isAtEnd()) {
            switch (self.peek()) {
                ' ', '\r', '\t' => _ = self.advance(),
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                },
                '/' => if (self.peekNext() == '/') {
                    while (self.peek() != '\n' and !self.isAtEnd()) _ = self.advance();
                },
                else => return,
            }
        }
    }

    inline fn peek(self: Self) u8 {
        return self.current[0];
    }

    inline fn peekNext(self: Self) u8 {
        return if (self.isAtEnd()) 0 else self.current[1];
    }

    inline fn advance(self: *Self) u8 {
        self.current += 1;
        return (self.current - 1)[0];
    }

    fn match(self: *Self, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.current[0] != expected) return false;
        self.current += 1;
        return true;
    }

    inline fn isAtEnd(self: Self) bool {
        return self.current == self.end;
    }

    inline fn currentLexeme(self: Self) []const u8 {
        return self.start[0..@intFromPtr(self.current - @intFromPtr(self.start))];
    }
};

pub const TokenType = enum(u8) {
    left_paren = '(',
    right_paren = ')',
    left_brace = '{',
    right_brace = '}',
    comma = ',',
    dot = '.',
    minus = '-',
    plus = '+',
    semicolon = ';',
    slash = '/',
    star = '*',

    bang = 0,
    bang_equal,
    equal,
    equal_equal,
    greater,
    greater_equal,
    less,
    less_equal,

    identifier,
    string,
    number,

    kw_and,
    kw_class,
    kw_else,
    kw_false,
    kw_for,
    kw_fun,
    kw_if,
    kw_nil,
    kw_or,
    kw_print,
    kw_return,
    kw_super,
    kw_this,
    kw_true,
    kw_var,
    kw_while,

    scanning_error,
    eof,
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
};

inline fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

inline fn isAlpha(char: u8) bool {
    return (char >= 'a' and char <= 'z') or
        (char >= 'A' and char <= 'Z') or
        char == '_';
}

fn recogniseKeyword(word: []const u8) TokenType {
    switch (word[0]) {
        'a' => return checkKeyword(word[1..], "nd", .kw_and),
        'c' => return checkKeyword(word[1..], "lass", .kw_class),
        'e' => return checkKeyword(word[1..], "lse", .kw_else),
        'f' => {
            if (word.len == 1) return .identifier;
            switch (word[1]) {
                'a' => return checkKeyword(word[2..], "lse", .kw_false),
                'o' => return checkKeyword(word[2..], "r", .kw_for),
                'u' => return checkKeyword(word[2..], "n", .kw_fun),
                else => return .identifier,
            }
        },
        'i' => return checkKeyword(word[1..], "f", .kw_if),
        'n' => return checkKeyword(word[1..], "il", .kw_nil),
        'o' => return checkKeyword(word[1..], "r", .kw_or),
        'p' => return checkKeyword(word[1..], "rint", .kw_print),
        'r' => return checkKeyword(word[1..], "eturn", .kw_return),
        's' => return checkKeyword(word[1..], "uper", .kw_super),
        't' => {
            if (word.len == 1) return .identifier;
            switch (word[1]) {
                'h' => return checkKeyword(word[2..], "is", .kw_this),
                'r' => return checkKeyword(word[2..], "ue", .kw_true),
                else => return .identifier,
            }
        },
        'v' => return checkKeyword(word[1..], "ar", .kw_var),
        'w' => return checkKeyword(word[1..], "hile", .kw_while),
        else => return .identifier,
    }
}

inline fn checkKeyword(
    input: []const u8,
    expected: []const u8,
    keyword: TokenType,
) TokenType {
    return if (std.mem.eql(u8, input, expected)) keyword else .identifier;
}
