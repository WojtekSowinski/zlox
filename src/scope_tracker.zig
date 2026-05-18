const std = @import("std");
const GarbageCollector = @import("gc.zig");
const GlobalVarStore = @import("vm.zig").GlobalVarStore;
const Stack = @import("stack.zig").Stack;
const OOM = std.mem.Allocator.Error;
const LoxFunction = @import("functions.zig").LoxFunction;

pub const ScopeTracker = struct {
    function: *LoxFunction,
    context: Context,
    locals: [256]Local,
    locals_count: u9,
    scope_depth: isize,
    enclosing: ?*ScopeTracker,
    up_values: [256]UpValue,

    const SearchResult = union(enum) {
        local: usize,
        up_value: usize,
        not_in_scope,
        self_referencial,
    };

    pub fn init(
        gc: *GarbageCollector,
        context: Context,
        name: ?[]const u8,
        enclosing: ?*ScopeTracker,
    ) OOM!ScopeTracker {
        const fun = try gc.newFunction(name);
        var result: ScopeTracker = .{
            .function = fun,
            .context = context,
            .scope_depth = 0,
            .enclosing = enclosing,
            .up_values = undefined,
            .locals = undefined,
            .locals_count = 1,
        };
        result.locals[0] = .{ .depth = 0, .name = "" };
        return result;
    }

    pub fn reset(self: *ScopeTracker) void {
        self.locals_count = 0;
        self.scope_depth = 0;
    }

    pub fn deinit(self: *ScopeTracker) void {
        _ = self;
    }

    pub fn enterScope(self: *ScopeTracker) void {
        self.scope_depth += 1;
    }

    pub fn exitScope(self: *ScopeTracker) usize {
        self.scope_depth -= 1;
        var vars_popped: usize = 0;
        while (self.locals_count > 0 and self.locals[self.locals_count - 1].depth > self.scope_depth) {
            vars_popped += 1;
            self.locals_count -= 1;
        }
        return vars_popped;
    }

    pub fn addLocal(self: *ScopeTracker, name: []const u8) usize {
        if (self.locals_count < 256)
            self.locals[self.locals_count] = .{ .name = name, .depth = -1 };
        self.locals_count += 1;
        return self.locals_count - 1;
    }

    pub fn markInitialized(self: *ScopeTracker) void {
        if (self.isGlobal()) return;
        self.locals[self.locals_count - 1].depth = self.scope_depth;
    }

    pub fn isNameTaken(self: ScopeTracker, name: []const u8) bool {
        for (0..self.locals_count) |i| {
            const local = self.locals[self.locals_count - 1 - i];
            if (local.depth != -1 and local.depth < self.scope_depth) return false;
            if (std.mem.eql(u8, local.name, name)) return true;
        }
        return false;
    }

    pub fn resolveLocal(self: *ScopeTracker, name: []const u8) SearchResult {
        for (0..self.locals_count) |i| {
            const index = self.locals_count - 1 - i;
            const local = self.locals[index];
            if (std.mem.eql(u8, local.name, name)) {
                if (local.depth == -1) return .self_referencial;
                return .{ .local = index };
            }
        }
        return self.resolveUpValue(name);
    }

    fn resolveUpValue(self: *ScopeTracker, name: []const u8) SearchResult {
        if (self.enclosing == null) return .not_in_scope;
        const enclosing = self.enclosing.?;
        const result_from_enclosing = enclosing.resolveLocal(name);
        return switch (result_from_enclosing) {
            .local => |index| .{ .up_value = self.addUpValue(index, true) },
            .up_value => |index| .{ .up_value = self.addUpValue(index, false) },
            else => result_from_enclosing,
        };
    }

    fn addUpValue(self: *ScopeTracker, index: usize, is_local: bool) usize {
        const up_value_count = self.function.up_value_count;
        for (self.up_values[0..up_value_count], 0..) |up_value, i| {
            if (up_value.index == index and up_value.is_local == is_local) return i;
        }
        self.up_values[up_value_count] = .{ .index = index, .is_local = is_local };
        self.function.up_value_count += 1;
        return up_value_count;
    }

    pub fn isLocal(self: ScopeTracker) bool {
        return self.scope_depth > 0;
    }

    pub fn isGlobal(self: ScopeTracker) bool {
        return self.scope_depth <= 0;
    }
};

const Local = struct {
    name: []const u8,
    depth: isize,
};

pub const UpValue = struct {
    index: usize,
    is_local: bool,
};

pub const Context = enum {
    function,
    script,
};
