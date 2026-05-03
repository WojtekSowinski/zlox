const std = @import("std");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const debug = @import("debug.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stderr_buff: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buff);
    var stderr = &stderr_writer.interface;

    var stdout_buff: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buff);
    var stdout = &stdout_writer.interface;

    var stdin_buff: [64]u8 = undefined;
    var repl_line_buff = std.Io.Writer.Allocating.init(init.gpa);
    defer repl_line_buff.deinit();
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buff);
    var stdin = &stdin_reader.interface;

    var mainVM = vm.VM{};
    try mainVM.init(init.gpa);
    defer mainVM.deinit();
    mainVM.input_reader = stdin;
    mainVM.output_writer = stdout;
    mainVM.error_writer = stderr;

    const a = init.minimal.args;
    const args = try a.toSlice(init.arena.allocator());

    if (args.len == 1) {
        while (true) {
            try stdout.writeAll("> ");
            try stdout.flush();

            const length = stdin.streamDelimiter(&repl_line_buff.writer, '\n') catch break;
            defer repl_line_buff.clearRetainingCapacity();
            stdin.toss(1);
            if (length == 0) continue;

            try repl_line_buff.writer.writeByte(';');
            _ = mainVM.interpret(repl_line_buff.written()) catch {};

            try stdout.flush();
            try stderr.flush();
        }
        try stdout.writeByte('\n');
    } else if (args.len == 2) {
        const source = try readFile(args[1], io, init.arena.allocator());
        const result = mainVM.interpret(source);
        try stdout.flush();
        try stderr.flush();
        if (result) |_| {} else |_| std.process.exit(65);
    } else {
        try stderr.writeAll("Usage: zlox [path]\n");
        try stderr.flush();
        std.process.exit(64);
    }
}

fn readFile(path: []const u8, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const size = (try file.stat(io)).size;
    const content = try reader.interface.readAlloc(allocator, size);
    return content;
}

test {
    std.testing.refAllDecls(@This());
}
