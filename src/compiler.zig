const std = @import("std");
const scan = @import("scanner.zig");
const Scanner = scan.Scanner;
const Token = scan.Token;

pub fn compile(source_code: []const u8, error_writer: std.io.AnyWriter) !void {
    var tokens = Scanner.init(source_code);
    var line: usize = std.math.maxInt(usize);

    while (true) {
        const token = tokens.next();
        if (token.line != line) {
            std.debug.print("{d:>4} ", .{token.line});
            line = token.line;
        } else {
            std.debug.print("   | ", .{});
        }
        std.debug.print(" {s} '{s}'\n", .{
            std.enums.tagName(
                scan.TokenType,
                token.type,
            ).?,
            token.lexeme,
        });

        if (token.type == .scanning_error) {
            try std.fmt.format(
                error_writer,
                "Lexical error on line {d}: {s}\n",
                .{ token.line, token.lexeme },
            );
        }

        if (token.type == .eof) break;
    }
}
