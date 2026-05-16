const std = @import("std");
const GarbageCollector = @import("gc.zig");
const GlobalVarStore = @import("vm.zig").GlobalVarStore;
const Stack = @import("stack.zig").Stack;
const OOM = std.mem.Allocator.Error;
const Function = @import("functions.zig").Function;

pub const ScopeTracker = struct {
    function: *Function,
    context: Context,
    locals: Stack(Local),
    scope_depth: isize,

    const SearchResult = union(enum) {
        found: usize,
        not_in_scope,
        self_referencial,
    };

    pub fn init(gc: *GarbageCollector, context: Context) OOM!ScopeTracker {
        var locals = try Stack(Local).init(gc.allocator(), 256);
        locals.push(.{ .depth = 0, .name = "" }) catch unreachable;
        errdefer locals.deinit();
        const fun = try gc.newFunction();
        return .{
            .function = fun,
            .context = context,
            .locals = locals,
            .scope_depth = 0,
        };
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

    pub fn addLocal(self: *ScopeTracker, name: []const u8) OOM!usize {
        try self.locals.push(.{ .name = name, .depth = -1 });
        return self.locals.count - 1;
    }

    pub fn markInitialized(self: *ScopeTracker) void {
        if (self.isGlobal()) return;
        const latestLocal = self.locals.peek(0);
        self.locals.swap(.{ .name = latestLocal.name, .depth = self.scope_depth });
    }

    pub fn isNameTaken(self: ScopeTracker, name: []const u8) bool {
        for (0..self.locals.count) |i| {
            const local = self.locals.peek(i);
            if (local.depth != -1 and local.depth < self.scope_depth) return false;
            if (std.mem.eql(u8, local.name, name)) return true;
        }
        return false;
    }

    pub fn resolveLocal(self: ScopeTracker, name: []const u8) SearchResult {
        for (0..self.locals.count) |i| {
            const local = self.locals.peek(i);
            if (std.mem.eql(u8, local.name, name)) {
                if (local.depth == -1) return .self_referencial;
                return .{ .found = self.locals.count - 1 - i };
            }
        }
        return .not_in_scope;
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

pub const Context = enum {
    function,
    script,
};
