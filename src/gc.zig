const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const Obj = object.Obj;
const ObjectType = object.ObjectType;

base_allocator: Allocator,
objects: ?*Obj,

const Self = @This();

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

pub fn deleteObjects(self: *Self) void {
    var objects = self.objects;
    while (objects) |obj| {
        objects = obj.next;
        self.deleteObject(obj);
    }
    self.objects = null;
}

fn deleteObject(self: *Self, obj: *Obj) void {
    switch (obj.type) {
        .const_string => {
            const str = obj.as(object.String);
            self.allocator().destroy(str);
        },
        .owned_string => {
            const str = obj.as(object.String);
            self.allocator().free(str.text);
            self.allocator().destroy(str);
        },
    }
}

pub fn init(base_allocator: Allocator) Self {
    return Self{ .base_allocator = base_allocator, .objects = null };
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
