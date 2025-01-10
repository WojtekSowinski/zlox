const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn HashTable(Key: type, Value: type, hash: fn (Key) u32, eq: fn (Key, Key) bool) type {
    return struct {
        const TombstoneData = std.bit_set.DynamicBitSetUnmanaged;

        keys: []?Key,
        values: []Value,
        count: usize = 0,
        tombstones: TombstoneData,

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            return initCapacity(allocator, 8);
        }

        fn initCapacity(allocator: Allocator, capacity: usize) !Self {
            const keys = try allocator.alloc(?Key, capacity);
            errdefer allocator.free(keys);
            const values = try allocator.alloc(Value, capacity);
            errdefer allocator.free(values);
            const tombstones = try TombstoneData.initEmpty(allocator, capacity);
            for (keys, 0..) |_, i| keys[i] = null;
            return .{ .keys = keys, .values = values, .tombstones = tombstones };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.keys);
            allocator.free(self.values);
            self.tombstones.deinit(allocator);
        }

        pub fn put(self: *Self, key: Key, value: Value, allocator: Allocator) !void {
            if (self.count >= self.maxLoad()) try self.grow(allocator);
            const index = self.findIndex(key);
            self.insertAt(key, value, index);
        }

        pub fn get(self: Self, key: Key) ?Value {
            const index = self.findIndex(key);
            return if (self.keys[index]) |_| self.values[index] else null;
        }

        pub fn delete(self: *Self, key: Key) bool {
            const index = self.findIndex(key);
            if (self.keys[index] == null) return false;
            self.keys[index] = null;
            self.tombstones.set(index);
            return true;
        }

        fn grow(self: *Self, allocator: Allocator) !void {
            var new_table = try initCapacity(allocator, self.keys.len * 2);
            self.copyAll(&new_table);
            self.deinit(allocator);
            self.* = new_table;
        }

        fn copyAll(from: Self, to: *Self) void {
            for (from.keys, from.values) |key, value| {
                if (key) |k| to.insertAt(k, value, to.findIndex(k));
            }
        }

        pub fn insertAt(self: *Self, key: Key, value: Value, index: usize) void {
            if (self.keys[index] == null and !self.tombstones.isSet(index)) self.count += 1;
            self.keys[index] = key;
            self.values[index] = value;
            self.tombstones.unset(index);
        }

        pub fn findIndex(self: Self, key: Key) usize {
            var index = hash(key) & (self.keys.len - 1);
            var last_tombstone: ?usize = null;
            while (true) {
                const current_key = self.keys[index];
                if (current_key == null) {
                    if (self.tombstones.isSet(index)) {
                        last_tombstone = last_tombstone orelse index;
                    } else {
                        return last_tombstone orelse index;
                    }
                } else if (eq(current_key.?, key)) return index;
                index = (index + 1) & (self.keys.len - 1);
            }
        }

        inline fn maxLoad(self: Self) usize {
            return (self.keys.len / 4) * 3;
        }
    };
}
