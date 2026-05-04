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
const GlobalVarStore = @import("vm.zig").GlobalVarStore;
const Stack = @import("stack.zig").Stack;
const WriterError = std.Io.Writer.Error;

const CompilerError = error{
    WriteFailed,
    OutOfMemory,
};

const OOM = std.mem.Allocator.Error;

error_writer: *std.Io.Writer,
compilingChunk: *bytecode.Chunk,
tokens: Scanner,
parser: Parser,
gc: *GarbageCollector,
globals: *GlobalVarStore,
scope_tracker: ScopeTracker,

const ScopeTracker = struct {
    locals: Stack(Local),
    scope_depth: isize,

    const SearchResult = union(enum) {
        found: usize,
        not_in_scope,
        self_referencial,
    };

    pub fn init(allocator: std.mem.Allocator) OOM!ScopeTracker {
        const locals = try Stack(Local).init(allocator, 256);
        return .{ .locals = locals, .scope_depth = 0 };
    }

    pub fn reset(self: *ScopeTracker) void {
        self.locals.clear();
        self.scope_depth = 0;
    }

    pub fn deinit(self: *ScopeTracker) void {
        self.locals.deinit();
    }

    pub fn enterScope(self: *ScopeTracker) void {
        self.scope_depth += 1;
    }

    pub fn exitScope(self: *ScopeTracker) usize {
        self.scope_depth -= 1;
        var vars_popped: usize = 0;
        while (self.locals.count > 0 and self.locals.peek(0).depth > self.scope_depth) {
            vars_popped += 1;
            _ = self.locals.pop();
        }
        return vars_popped;
    }

    pub fn addLocal(self: *ScopeTracker, name: Token) OOM!usize {
        try self.locals.push(.{ .name = name, .depth = -1 });
        return self.locals.count - 1;
    }

    pub fn markInitialized(self: *ScopeTracker) void {
        const latestLocal = self.locals.peek(0);
        self.locals.swap(.{ .name = latestLocal.name, .depth = self.scope_depth });
    }

    pub fn isNameTaken(self: ScopeTracker, name: Token) bool {
        for (0..self.locals.count) |i| {
            const local = self.locals.peek(i);
            if (local.depth != -1 and local.depth < self.scope_depth) return false;
            if (std.mem.eql(u8, local.name.lexeme, name.lexeme)) return true;
        }
        return false;
    }

    pub fn resolveLocal(self: ScopeTracker, name: Token) SearchResult {
        for (0..self.locals.count) |i| {
            const local = self.locals.peek(i);
            if (std.mem.eql(u8, local.name.lexeme, name.lexeme)) {
                if (local.depth == -1) return .self_referencial;
                return .{ .found = self.locals.count - 1 - i };
            }
        }
        return .not_in_scope;
    }

    pub fn isLocal(self: ScopeTracker) bool {
        return self.scope_depth > 0;
    }
};

const Local = struct {
    name: Token,
    depth: isize,
};

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
    prefix: ?*const fn (*Self, bool) CompilerError!void,
    infix: ?*const fn (*Self, bool) CompilerError!void,
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
    globals: *GlobalVarStore,
) OOM!Self {
    const scope_tracker = try ScopeTracker.init(gc.allocator());
    return Self{
        .globals = globals,
        .gc = gc,
        .error_writer = error_writer,
        .compilingChunk = chunk,
        .parser = Parser{},
        .tokens = undefined,
        .scope_tracker = scope_tracker,
    };
}

pub fn deinit(self: *Self) void {
    self.scope_tracker.deinit();
}

pub fn compile(self: *Self, source_code: []const u8) error{ WriteFailed, OutOfMemory, InvalidCode }!void {
    self.tokens = Scanner.init(source_code);
    try self.advance();
    while (!try self.match(.eof)) try self.statement();
    try self.endCompilation();
    self.scope_tracker.reset();
    if (self.parser.had_error) return error.InvalidCode;
}

fn advance(self: *Self) WriterError!void {
    self.parser.previous = self.parser.current;
    while (true) {
        self.parser.current = self.tokens.next();
        if (self.parser.current.type != .scanning_error) break;
        try self.errorAtCurrent(self.parser.current.lexeme);
    }
}

fn match(self: *Self, token_type: TokenType) WriterError!bool {
    if (!self.checkFor(token_type)) return false;
    try self.advance();
    return true;
}

inline fn checkFor(self: Self, token_type: TokenType) bool {
    return self.parser.current.type == token_type;
}

fn errorAtPrevious(self: *Self, message: []const u8) WriterError!void {
    try self.errorAt(self.parser.previous, message);
}

fn errorAtCurrent(self: *Self, message: []const u8) WriterError!void {
    try self.errorAt(self.parser.current, message);
}

fn errorAt(self: *Self, token: Token, message: []const u8) WriterError!void {
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

fn errPrint(self: Self, comptime fmt: []const u8, args: anytype) WriterError!void {
    try self.error_writer.print(fmt, args);
}

inline fn currentChunk(self: Self) *bytecode.Chunk {
    return self.compilingChunk;
}

fn consume(self: *Self, expected: TokenType, err_msg: []const u8) WriterError!void {
    if (self.parser.current.type == expected) {
        try self.advance();
        return;
    }
    try self.errorAtCurrent(err_msg);
}

fn synchronize(self: *Self) WriterError!void {
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

inline fn emitInstructionWithIndex(
    self: *Self,
    comptime short: OpCode,
    comptime long: OpCode,
    index: usize,
) OOM!void {
    std.debug.assert(index <= std.math.maxInt(u24));
    const instruction = if (index <= std.math.maxInt(u8))
        @unionInit(Instruction, @tagName(short), @intCast(index))
    else
        @unionInit(Instruction, @tagName(long), @intCast(index));

    try self.emitInstruction(instruction, self.parser.previous.line);
}

fn statement(self: *Self) CompilerError!void {
    if (try self.match(.kw_var)) {
        try self.varDeclaration();
    } else {
        try self.command();
    }

    if (self.parser.panic_mode) try self.synchronize();
}

fn command(self: *Self) CompilerError!void {
    if (try self.match(.semicolon)) return;

    if (try self.match(.kw_print)) {
        try self.printStatement();
    } else if (try self.match(.left_brace)) {
        self.scope_tracker.enterScope();
        try self.block();
        const locals_to_pop = self.scope_tracker.exitScope();
        for (0..locals_to_pop) |_| try self.emitInstruction(.pop, self.parser.previous.line);
    } else {
        try self.expressionStatement();
    }
}

fn block(self: *Self) CompilerError!void {
    while (!self.checkFor(.right_brace) and !self.checkFor(.eof)) {
        try self.statement();
    }
    try self.consume(.right_brace, "Expected '}' after block.");
}

fn varDeclaration(self: *Self) CompilerError!void {
    const id = try self.parseIdentifier("Expected variable name.");
    if (try self.match(.equal)) {
        try self.expression();
    } else {
        try self.emitInstruction(.nil, self.parser.previous.line);
    }

    try self.consume(.semicolon, "Expected ';' after variable declaration.");
    try self.defineVariable(id);
}

fn parseIdentifier(self: *Self, err_msg: []const u8) CompilerError!usize {
    try self.consume(.identifier, err_msg);

    if (self.scope_tracker.isLocal()) {
        try self.declareLocal();
        return 0;
    }

    return self.makeIdentifier(self.parser.previous);
}

fn declareLocal(self: *Self) CompilerError!void {
    const name = self.parser.previous;
    if (self.scope_tracker.isNameTaken(name)) {
        try self.errorAtPrevious("Already a variable with this name in this scope");
    }
    const index = try self.scope_tracker.addLocal(name);
    if (index > std.math.maxInt(u24)) try self.errorAtPrevious("Too many local variables.");
}

fn makeIdentifier(self: *Self, token: Token) OOM!usize {
    const str = try self.gc.copyString(token.lexeme);
    return self.globals.getIndexOrCreate(str);
}

fn defineVariable(self: *Self, id_index: usize) OOM!void {
    if (self.scope_tracker.isLocal()) {
        self.scope_tracker.markInitialized();
    } else {
        try self.emitInstructionWithIndex(.def_global, .long_def_global, id_index);
    }
}

fn printStatement(self: *Self) CompilerError!void {
    try self.expression();
    try self.consume(.semicolon, "Expected ';' after a print statement.");
    try self.emitInstruction(.print, self.parser.previous.line);
}

fn expressionStatement(self: *Self) CompilerError!void {
    try self.expression();
    try self.consume(.semicolon, "Expected ';' after an expression.");
    try self.emitInstruction(.pop, self.parser.previous.line);
}

fn expression(self: *Self) CompilerError!void {
    try self.parsePrecedence(.assignment);
}

fn parsePrecedence(self: *Self, precedence: Precedence) CompilerError!void {
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

fn unary(self: *Self, can_assign: bool) CompilerError!void {
    _ = can_assign;
    const operator = self.parser.previous;

    try self.parsePrecedence(.unary);

    switch (operator.type) {
        .minus => try self.emitInstruction(.negate, operator.line),
        .bang => try self.emitInstruction(.not, operator.line),
        else => unreachable,
    }
}

fn binary(self: *Self, can_assign: bool) CompilerError!void {
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

fn literal(self: *Self, can_assign: bool) OOM!void {
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

fn variable(self: *Self, can_assign: bool) CompilerError!void {
    try self.emitVariable(self.parser.previous, can_assign);
}

fn emitVariable(self: *Self, name: Token, can_assign: bool) CompilerError!void {
    const localIndex = self.scope_tracker.resolveLocal(name);
    switch (localIndex) {
        .found => |arg| {
            if (arg > std.math.maxInt(u24)) try self.errorAtPrevious("Too many global variables.");
            try self.emitSetOrGetAtIndex(
                [_]OpCode{ .set_local, .long_set_local, .get_local, .long_get_local },
                arg,
                can_assign,
            );
        },
        .not_in_scope => {
            const arg = try self.makeIdentifier(name);
            if (arg > std.math.maxInt(u24)) try self.errorAtPrevious("Too many global variables.");
            try self.emitSetOrGetAtIndex(
                [_]OpCode{ .set_global, .long_set_global, .get_global, .long_get_global },
                arg,
                can_assign,
            );
        },
        .self_referencial => try self.errorAtPrevious("Can't read local variable in its own initializer."),
    }
}

fn emitSetOrGetAtIndex(
    self: *Self,
    comptime opcodes: [4]OpCode,
    arg: usize,
    can_assign: bool,
) CompilerError!void {
    std.debug.assert(arg <= std.math.maxInt(u24));
    if (can_assign and try self.match(.equal)) {
        try self.expression();
        try self.emitInstructionWithIndex(opcodes[0], opcodes[1], arg);
    } else {
        try self.emitInstructionWithIndex(opcodes[2], opcodes[3], arg);
    }
}

fn string(self: *Self, can_assign: bool) CompilerError!void {
    _ = can_assign;
    const lexeme = self.parser.previous.lexeme;
    const text = lexeme[1 .. lexeme.len - 1];
    const obj = &((try self.gc.borrowString(text)).obj);
    errdefer self.gc.deleteObject(obj);
    try self.emitConstant(.{ .object = obj });
}

fn number(self: *Self, can_assign: bool) CompilerError!void {
    _ = can_assign;
    const value = std.fmt.parseFloat(f64, self.parser.previous.lexeme) catch unreachable;
    try self.emitConstant(.{ .number = value });
}

fn makeConstant(self: *Self, value: Value) CompilerError!usize {
    const index = try self.currentChunk().addConstant(value);
    if (index > std.math.maxInt(u24)) try self.errorAtPrevious("Too many constants in one chunk.");
    return index;
}

fn emitConstant(self: *Self, value: Value) CompilerError!void {
    const index = try self.makeConstant(value);
    return try self.emitInstructionWithIndex(.constant, .long_constant, index);
}

fn grouping(self: *Self, can_assign: bool) CompilerError!void {
    _ = can_assign;
    try self.expression();
    try self.consume(.right_paren, "Expected ')' after expression.");
}

inline fn endCompilation(self: *Self) OOM!void {
    try self.emitReturn();
    if (config.disassemble) debug.disassembleChunk(self.currentChunk().*, "code");
}

inline fn emitReturn(self: *Self) OOM!void {
    try self.emitInstruction(.ret, self.parser.previous.line);
}

inline fn emitInstruction(
    self: *Self,
    instruction: Instruction,
    line: usize,
) OOM!void {
    try self.currentChunk().writeInstruction(instruction, line);
}
