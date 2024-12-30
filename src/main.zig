const std = @import("std");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const debug = @import("debug.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stderr_file = std.io.getStdErr().writer();
    var err_bw = std.io.bufferedWriter(stderr_file);
    const stderr = err_bw.writer();

    const stdout_file = std.io.getStdOut().writer();
    var out_bw = std.io.bufferedWriter(stdout_file);
    const stdout = out_bw.writer();

    const stdin_file = std.io.getStdIn().reader();
    var in_bw = std.io.bufferedReader(stdin_file);
    const stdin = in_bw.reader();

    var mainVM = vm.VM{};
    try mainVM.init(allocator);
    defer mainVM.deinit();
    mainVM.input_reader = stdin.any();
    mainVM.output_writer = stdout.any();
    mainVM.error_writer = stderr.any();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1) {
        while (true) {
            try out_bw.flush();
            try err_bw.flush();
            try stdout_file.writeAll("> ");
            var line_buffer: [1024]u8 = undefined;
            const line = stdin.readUntilDelimiter(&line_buffer, '\n') catch {
                try stdout_file.writeByte('\n');
                break;
            };
            _ = mainVM.interpret(line) catch {};
        }
    } else if (args.len == 2) {
        const source = try readFile(args[1], allocator);
        const result = mainVM.interpret(source);
        allocator.free(source);
        try out_bw.flush();
        try err_bw.flush();
        if (result) |_| {} else |_| std.process.exit(65);
    } else {
        try stderr_file.writeAll("Usage: zlox [path]\n");
        std.process.exit(64);
    }
}

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    const content = try file.readToEndAlloc(allocator, size);
    return content;
}

test {
    std.testing.refAllDecls(@This());
}
