const std = @import("std");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const debug = @import("debug.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1) {
        try repl(allocator);
    } else if (args.len == 2) {
        try runFile(args[1], allocator);
    } else {
        std.debug.print("Usage: zlox [path]\n", .{});
        std.process.exit(64);
    }
}

fn repl(allocator: std.mem.Allocator) !void {
    const stdout_file = std.io.getStdOut().writer();
    var stdout_bw = std.io.bufferedWriter(stdout_file);
    const stdout = stdout_bw.writer();

    const stdin = std.io.getStdIn().reader();
    var line_buffer: [1024]u8 = undefined;

    var replVM = try vm.VM.init(allocator, stdin.any(), stdout.any(), null);
    defer replVM.deinit();

    while (true) {
        try stdout.writeAll("> ");
        try stdout_bw.flush();
        const line = stdin.readUntilDelimiter(&line_buffer, '\n') catch {
            try stdout.writeAll("\n");
            try stdout_bw.flush();
            break;
        };
        _ = replVM.interpret(line);
    }
}

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    const content = try file.readToEndAlloc(allocator, size);
    return content;
}

fn runFile(path: []const u8, allocator: std.mem.Allocator) !void {
    const source = try readFile(path, allocator);

    var machine = try vm.VM.init(allocator, null, null, null);
    defer machine.deinit();

    const result = machine.interpret(source);
    allocator.free(source);
    if (result == .compile_error) std.process.exit(65);
    if (result == .runtime_error) std.process.exit(70);
}

test {
    std.testing.refAllDecls(@This());
}
