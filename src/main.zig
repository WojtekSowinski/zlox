const std = @import("std");
const bytecode = @import("chunk.zig");
const vm = @import("vm.zig");
const debug = @import("debug.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var testChunk = try bytecode.Chunk.init(allocator);
    defer testChunk.deinit();

    const index: u8 = @truncate(try testChunk.addConstant(1.2));
    const long_index: u24 = @truncate(try testChunk.addConstant(-57));
    try testChunk.writeInstruction(.{ .con = index }, 123);
    try testChunk.writeInstruction(.{ .long_con = long_index }, 123);
    try testChunk.writeInstruction(.ret, 124);

    var mainVM = try vm.VM.init(&testChunk, allocator);
    defer mainVM.deinit();

    const result = mainVM.run();
    std.debug.assert(result == .ok);
}

test {
    std.testing.refAllDecls(@This());
}
