const objects = @import("object.zig");
const bytecode = @import("bytecode.zig");

pub const Function = struct {
    obj: objects.Obj,
    arity: u8,
    chunk: bytecode.Chunk,
    name: ?[]const u8,
};
