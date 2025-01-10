const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const Obj = object.Obj;
const String = object.String;
const ObjectType = object.ObjectType;
const HashTable = @import("hash_table.zig").HashTable;

base_allocator: Allocator,
objects: ?*Obj,
string_pool: StringPool,

const Self = @This();
const StringPool = HashTable([]const u8, *String, hashString, compareStrings);

pub fn makeObject(self: *Self, obj_type: ObjectType) !*Obj {
    var obj: *Obj = undefined;
    switch (obj_type) {
        .const_string,
        .owned_string,
        => {
            const str = try self.allocator().create(object.String);
            obj = &(str.obj);
        },
    }
    obj.type = obj_type;
    obj.next = self.objects;
    self.objects = obj;
    return obj;
}

fn hashString(text: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (text) |char| {
        hash ^= char;
        hash *%= 16777619;
    }
    return hash;
}

fn compareStrings(str1: []const u8, str2: []const u8) bool {
    return std.mem.eql(u8, str1, str2);
}

pub fn takeString(self: *Self, text: []const u8) !*String {
    if (self.string_pool.get(text)) |interned| {
        self.allocator().free(text);
        return interned;
    }
    const obj = try self.makeObject(.owned_string);
    errdefer self.deleteObject(obj);
    const string: *String = @fieldParentPtr("obj", obj);
    string.text = text;
    string.hash = hashString(text);
    try self.string_pool.put(text, string, self.base_allocator);
    return string;
}

pub fn borrowString(self: *Self, text: []const u8) !*String {
    if (self.string_pool.get(text)) |interned| return interned;
    const obj = try self.makeObject(.const_string);
    errdefer self.deleteObject(obj);
    const string: *String = @fieldParentPtr("obj", obj);
    string.text = text;
    string.hash = hashString(text);
    try self.string_pool.put(text, string, self.base_allocator);
    return string;
}

pub fn deleteObjects(self: *Self) void {
    var objects = self.objects;
    while (objects) |obj| {
        objects = obj.next;
        self.deleteObject(obj);
    }
    self.objects = null;
}

pub fn deleteObject(self: *Self, obj: *Obj) void {
    switch (obj.type) {
        .const_string => {
            const str = obj.as(String);
            self.allocator().destroy(str);
        },
        .owned_string => {
            const str = obj.as(String);
            self.allocator().free(str.text);
            self.allocator().destroy(str);
        },
    }
}

pub fn init(base_allocator: Allocator) !Self {
    const string_pool = try StringPool.init(base_allocator);
    return Self{
        .base_allocator = base_allocator,
        .objects = null,
        .string_pool = string_pool,
    };
}

pub fn deinit(self: *Self) void {
    self.string_pool.deinit(self.base_allocator);
}

fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.base_allocator.rawAlloc(len, ptr_align, ret_addr);
}

fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.base_allocator.rawResize(buf, buf_align, new_len, ret_addr);
}

fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.base_allocator.rawFree(buf, buf_align, ret_addr);
}

pub fn allocator(self: *Self) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = allocFn,
            .free = freeFn,
            .resize = resizeFn,
        },
    };
}
