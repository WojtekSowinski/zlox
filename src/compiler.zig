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
const scope_tracking = @import("scope_tracker.zig");
const ScopeTracker = scope_tracking.ScopeTracker;
const functions = @import("functions.zig");
const LoxFunction = functions.LoxFunction;

pub const CompilationError = error{
    WriteFailed,
    OutOfMemory,
    InvalidCode,
};

const InternalError = error{
    WriteFailed,
    OutOfMemory,
};

const OOM = std.mem.Allocator.Error;

error_writer: *std.Io.Writer,
tokens: Scanner,
parser: Parser,
gc: *GarbageCollector,
globals: *GlobalVarStore,
scope_tracker: ScopeTracker,

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
    prefix: ?*const fn (*Self, bool) InternalError!void,
    infix: ?*const fn (*Self, bool) InternalError!void,
    precedence: Precedence,
};

inline fn getRule(token_type: TokenType) ParserRule {
    const number_of_tokens = @typeInfo(TokenType).@"enum".fields.len;
    comptime var rules: [number_of_tokens]ParserRule = undefined;
    comptime {
        for (std.enums.values(TokenType)) |token| {
            const rule = switch (token) {
                .left_paren => .{ grouping, call, .call },

                .minus => .{ unary, binary, .sum },
                .plus => .{ null, binary, .sum },
                .slash => .{ null, binary, .product },
                .star => .{ null, binary, .product },

                .equal_equal => .{ null, binary, .equality },
                .bang_equal => .{ null, binary, .equality },
                .less => .{ null, binary, .comparison },
                .greater => .{ null, binary, .comparison },
                .less_equal => .{ null, binary, .comparison },
                .greater_equal => .{ null, binary, .comparison },

                .bang => .{ unary, null, .none },
                .kw_and => .{ null, andOperator, .conjunction },
                .kw_or => .{ null, orOperator, .disjunction },

                .number => .{ number, null, .none },
                .string => .{ string, null, .none },
                .identifier => .{ variable, null, .none },
                .kw_nil => .{ literal, null, .none },
                .kw_true => .{ literal, null, .none },
                .kw_false => .{ literal, null, .none },
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
    error_writer: *std.Io.Writer,
    gc: *GarbageCollector,
    globals: *GlobalVarStore,
) OOM!Self {
    const scope_tracker = try ScopeTracker.init(gc, .script, null, null);
    return Self{
        .globals = globals,
        .gc = gc,
        .error_writer = error_writer,
        .parser = Parser{},
        .tokens = undefined,
        .scope_tracker = scope_tracker,
    };
}

pub fn deinit(self: *Self) void {
    self.scope_tracker.deinit();
}

pub fn compile(self: *Self, source_code: []const u8) CompilationError!*LoxFunction {
    self.tokens = Scanner.init(source_code);
    try self.advance();
    while (!try self.match(.eof)) try self.statement();
    const fun = self.endCompilation();
    self.scope_tracker.reset();
    return if (self.parser.had_error) error.InvalidCode else fun;
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
    return &self.scope_tracker.function.chunk;
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
    std.debug.assert(index <= bytecode.MAX_LONG_INDEX);
    const instruction = if (index <= bytecode.MAX_SHORT_INDEX)
        @unionInit(Instruction, @tagName(short), @intCast(index))
    else
        @unionInit(Instruction, @tagName(long), @intCast(index));

    try self.emitInstruction(instruction, self.parser.previous.line);
}

fn statement(self: *Self) InternalError!void {
    if (try self.match(.kw_fun)) {
        try self.funDeclaration();
    } else if (try self.match(.kw_var)) {
        try self.varDeclaration();
    } else {
        try self.command();
    }

    if (self.parser.panic_mode) try self.synchronize();
}

fn command(self: *Self) InternalError!void {
    if (try self.match(.semicolon)) return;

    if (try self.match(.kw_print)) {
        try self.printStatement();
    } else if (try self.match(.kw_if)) {
        try self.ifStatement();
    } else if (try self.match(.kw_while)) {
        try self.whileLoop();
    } else if (try self.match(.kw_for)) {
        try self.forLoop();
    } else if (try self.match(.left_brace)) {
        self.scope_tracker.enterScope();
        try self.block();
        try self.exitScope();
    } else if (try self.match(.kw_return)) {
        try self.returnStatement();
    } else {
        try self.expressionStatement();
    }
}

fn exitScope(self: *Self) OOM!void {
    const locals_to_pop = self.scope_tracker.exitScope();
    try switch (locals_to_pop) {
        0 => return,
        1 => self.emitInstruction(.pop, self.parser.previous.line),
        else => self.emitInstructionWithIndex(.pop_many, .long_pop_many, locals_to_pop),
    };
}

fn block(self: *Self) InternalError!void {
    while (!self.checkFor(.right_brace) and !self.checkFor(.eof)) {
        try self.statement();
    }
    try self.consume(.right_brace, "Expected '}' after block.");
}

fn emitJump(self: *Self, comptime opcode: OpCode) OOM!usize {
    const instruction = @unionInit(Instruction, @tagName(opcode), undefined);
    try self.emitInstruction(instruction, self.parser.previous.line);
    return self.currentChunk().length() - bytecode.JUMP_DISTANCE_SIZE;
}

fn patchJump(self: *Self, jump_location: usize) InternalError!void {
    const distance = self.currentChunk().length() - jump_location - bytecode.JUMP_DISTANCE_SIZE;
    if (distance > bytecode.MAX_JUMP) try self.errorAtPrevious("Too much code to jump over.");
    self.currentChunk().patchJump(jump_location, @intCast(distance));
}

fn emitLoopBackTo(self: *Self, target: usize) InternalError!void {
    const distance = self.currentChunk().length() - target + bytecode.JUMP_DISTANCE_SIZE + @sizeOf(OpCode);
    if (distance > bytecode.MAX_JUMP) try self.errorAtPrevious("Loop body too large.");
    try self.emitInstruction(.{ .jump_back = @intCast(distance) }, self.parser.previous.line);
}

fn ifStatement(self: *Self) InternalError!void {
    try self.consume(.left_paren, "Expected '(' after 'if'.");
    try self.expression();
    try self.consume(.right_paren, "Expected ')' after condition.");

    const then_jump = try self.emitJump(.jump_if_falsey);
    try self.emitInstruction(.pop, self.parser.previous.line);
    try self.command();

    const else_jump = try self.emitJump(.jump);
    try self.patchJump(then_jump);
    try self.emitInstruction(.pop, self.parser.previous.line);
    if (try self.match(.kw_else)) try self.command();
    try self.patchJump(else_jump);
}

fn whileLoop(self: *Self) InternalError!void {
    const loop_start = self.currentChunk().length();
    try self.consume(.left_paren, "Expected '(' after 'while'.");
    try self.expression();
    try self.consume(.right_paren, "Expected ')' after condition.");

    const exit_jump = try self.emitJump(.jump_if_falsey);
    try self.emitInstruction(.pop, self.parser.previous.line);
    try self.command();
    try self.emitLoopBackTo(loop_start);

    try self.patchJump(exit_jump);
    try self.emitInstruction(.pop, self.parser.previous.line);
}

fn forLoop(self: *Self) InternalError!void {
    self.scope_tracker.enterScope();

    try self.consume(.left_paren, "Expected '(' after 'for'.");

    if (try self.match(.semicolon)) {} else if (try self.match(.kw_var)) {
        try self.varDeclaration();
    } else {
        try self.expressionStatement();
    }

    const loop_start = self.currentChunk().length();
    var exit_jump: ?usize = null;
    if (!try self.match(.semicolon)) {
        try self.expression();
        try self.consume(.semicolon, "Expected ';' after loop condition.");
        exit_jump = try self.emitJump(.jump_if_falsey);
        try self.emitInstruction(.pop, self.parser.previous.line);
    }

    const jump_to_body = try self.emitJump(.jump);
    const increment_start = self.currentChunk().length();

    if (!try self.match(.right_paren)) {
        try self.expression();
        try self.consume(.right_paren, "Expected ')' after for clauses.");
        try self.emitInstruction(.pop, self.parser.previous.line);
        try self.emitLoopBackTo(loop_start);
    }

    try self.patchJump(jump_to_body);
    try self.command();
    try self.emitLoopBackTo(increment_start);
    if (exit_jump) |ej| {
        try self.patchJump(ej);
        try self.emitInstruction(.pop, self.parser.previous.line);
    }

    try self.exitScope();
}

fn returnStatement(self: *Self) InternalError!void {
    if (self.scope_tracker.context == .script) {
        try self.errorAtPrevious("Can't return from top-level code.");
    }

    if (try self.match(.semicolon)) {
        try self.emitReturn();
    } else {
        try self.expression();
        try self.consume(.semicolon, "Expected ';' after return value.");
        try self.emitInstruction(.ret, self.parser.previous.line);
    }
}

fn funDeclaration(self: *Self) InternalError!void {
    const id = try self.parseIdentifier("Expected function name.");
    self.scope_tracker.markInitialized();
    try self.function(.function);
    try self.defineVariable(id);
}

fn function(self: *Self, context: scope_tracking.Context) InternalError!void {
    const name = self.parser.previous.lexeme;
    var function_scope: ScopeTracker = try .init(self.gc, context, name, &self.scope_tracker);
    function_scope.enterScope();

    self.scope_tracker = function_scope;

    try self.consume(.left_paren, "Expected '(' after function name.");
    var arity: u8 = 0;
    while (!self.checkFor(.right_paren)) {
        if (arity == 255) try self.errorAtCurrent("Can't have more than 255 parameters.");
        arity += 1;
        const parameter = try self.parseIdentifier("Expected parameter name.");
        try self.defineVariable(parameter);
        if (!try self.match(.comma)) break;
    }
    self.scope_tracker.function.arity = arity;
    try self.consume(.right_paren, "Expected ')' after parameters.");

    try self.consume(.left_brace, "Expected '{' before function body.");
    try self.block();

    const new_function = try self.endCompilation();
    self.scope_tracker = function_scope.enclosing.?.*;
    function_scope.deinit();
    try self.emitClosure(new_function);
}

fn emitClosure(self: *Self, fun: *LoxFunction) InternalError!void {
    const index = try self.makeConstant(.{ .object = &fun.obj });
    return try self.emitInstructionWithIndex(.closure, .long_closure, index);
}

fn call(self: *Self, can_assign: bool) InternalError!void {
    _ = can_assign;
    const arg_count = try self.argumentList();
    try self.emitInstruction(.{ .call = arg_count }, self.parser.previous.line);
}

fn argumentList(self: *Self) InternalError!u8 {
    var arg_count: u8 = 0;
    while (!self.checkFor(.right_paren)) {
        try self.expression();
        if (arg_count == 255) try self.errorAtPrevious("Can't have more than 255 parameters.");
        arg_count += 1;
        if (!try self.match(.comma)) break;
    }
    try self.consume(.right_paren, "Expected ')' after arguments.");
    return arg_count;
}

fn varDeclaration(self: *Self) InternalError!void {
    const id = try self.parseIdentifier("Expected variable name.");
    if (try self.match(.equal)) {
        try self.expression();
    } else {
        try self.emitInstruction(.nil, self.parser.previous.line);
    }

    try self.consume(.semicolon, "Expected ';' after variable declaration.");
    try self.defineVariable(id);
}

fn parseIdentifier(self: *Self, err_msg: []const u8) InternalError!usize {
    try self.consume(.identifier, err_msg);

    if (self.scope_tracker.isLocal()) {
        try self.declareLocal();
        return 0;
    }

    return self.makeIdentifier(self.parser.previous);
}

fn declareLocal(self: *Self) InternalError!void {
    const name = self.parser.previous;
    if (self.scope_tracker.isNameTaken(name.lexeme)) {
        try self.errorAtPrevious("Already a variable with this name in this scope");
    }
    const index = try self.scope_tracker.addLocal(name.lexeme);
    if (index > bytecode.MAX_LONG_INDEX) try self.errorAtPrevious("Too many local variables.");
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

fn printStatement(self: *Self) InternalError!void {
    try self.expression();
    try self.consume(.semicolon, "Expected ';' after a print statement.");
    try self.emitInstruction(.print, self.parser.previous.line);
}

fn expressionStatement(self: *Self) InternalError!void {
    try self.expression();
    try self.consume(.semicolon, "Expected ';' after an expression.");
    try self.emitInstruction(.pop, self.parser.previous.line);
}

fn expression(self: *Self) InternalError!void {
    try self.parsePrecedence(.assignment);
}

fn parsePrecedence(self: *Self, precedence: Precedence) InternalError!void {
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

fn unary(self: *Self, can_assign: bool) InternalError!void {
    _ = can_assign;
    const operator = self.parser.previous;

    try self.parsePrecedence(.unary);

    switch (operator.type) {
        .minus => try self.emitInstruction(.negate, operator.line),
        .bang => try self.emitInstruction(.not, operator.line),
        else => unreachable,
    }
}

fn binary(self: *Self, can_assign: bool) InternalError!void {
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

fn variable(self: *Self, can_assign: bool) InternalError!void {
    try self.emitVariable(self.parser.previous, can_assign);
}

fn emitVariable(self: *Self, name: Token, can_assign: bool) InternalError!void {
    const localIndex = self.scope_tracker.resolveLocal(name.lexeme);
    switch (localIndex) {
        .local => |arg| {
            if (arg > bytecode.MAX_LONG_INDEX) try self.errorAtPrevious("Too many local variables.");
            try self.emitSetOrGetAtIndex(
                [_]OpCode{ .set_local, .long_set_local, .get_local, .long_get_local },
                arg,
                can_assign,
            );
        },
        .up_value => |arg| {
            if (arg > bytecode.MAX_SHORT_INDEX) try self.errorAtPrevious("Closure captures too many variables.");
            try self.emitUpValue(@intCast(arg));
        },
        .not_in_scope => {
            const arg = try self.makeIdentifier(name);
            if (arg > bytecode.MAX_LONG_INDEX) try self.errorAtPrevious("Too many global variables.");
            try self.emitSetOrGetAtIndex(
                [_]OpCode{ .set_global, .long_set_global, .get_global, .long_get_global },
                arg,
                can_assign,
            );
        },
        .self_referencial => try self.errorAtPrevious("Can't read local variable in its own initializer."),
    }
}

fn emitUpValue(self: *Self, index: u8) OOM!void {
    _ = self;
    _ = index; // TODO: emit upvalue instruction
}

fn emitSetOrGetAtIndex(
    self: *Self,
    comptime opcodes: [4]OpCode,
    arg: usize,
    can_assign: bool,
) InternalError!void {
    std.debug.assert(arg <= bytecode.MAX_LONG_INDEX);
    if (can_assign and try self.match(.equal)) {
        try self.expression();
        try self.emitInstructionWithIndex(opcodes[0], opcodes[1], arg);
    } else {
        try self.emitInstructionWithIndex(opcodes[2], opcodes[3], arg);
    }
}

fn andOperator(self: *Self, can_assign: bool) InternalError!void {
    _ = can_assign;
    const end_jump = try self.emitJump(.jump_if_falsey);
    try self.emitInstruction(.pop, self.parser.previous.line);
    try self.parsePrecedence(.conjunction);
    try self.patchJump(end_jump);
}

fn orOperator(self: *Self, can_assign: bool) InternalError!void {
    _ = can_assign;
    const end_jump = try self.emitJump(.jump_if_truthy);
    try self.emitInstruction(.pop, self.parser.previous.line);
    try self.parsePrecedence(.disjunction);
    try self.patchJump(end_jump);
}

fn string(self: *Self, can_assign: bool) InternalError!void {
    _ = can_assign;
    const lexeme = self.parser.previous.lexeme;
    const text = lexeme[1 .. lexeme.len - 1];
    const obj = &((try self.gc.borrowString(text)).obj);
    errdefer self.gc.deleteObject(obj);
    try self.emitConstant(.{ .object = obj });
}

fn number(self: *Self, can_assign: bool) InternalError!void {
    _ = can_assign;
    const value = std.fmt.parseFloat(f64, self.parser.previous.lexeme) catch unreachable;
    try self.emitConstant(.{ .number = value });
}

fn makeConstant(self: *Self, value: Value) InternalError!usize {
    const index = try self.currentChunk().addConstant(value);
    if (index > bytecode.MAX_LONG_INDEX) try self.errorAtPrevious("Too many constants in one chunk.");
    return index;
}

fn emitConstant(self: *Self, value: Value) InternalError!void {
    const index = try self.makeConstant(value);
    return try self.emitInstructionWithIndex(.constant, .long_constant, index);
}

fn grouping(self: *Self, can_assign: bool) InternalError!void {
    _ = can_assign;
    try self.expression();
    try self.consume(.right_paren, "Expected ')' after expression.");
}

inline fn endCompilation(self: *Self) OOM!*LoxFunction {
    try self.emitReturn();
    const fun = self.scope_tracker.function;
    if (config.disassemble) debug.disassembleFunction(fun.*);
    return fun;
}

inline fn emitReturn(self: *Self) OOM!void {
    try self.emitInstruction(.nil, self.parser.previous.line);
    try self.emitInstruction(.ret, self.parser.previous.line);
}

inline fn emitInstruction(
    self: *Self,
    instruction: Instruction,
    line: usize,
) OOM!void {
    try self.currentChunk().writeInstruction(instruction, line);
}
