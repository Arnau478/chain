const std = @import("std");
const gdt = @import("gdt.zig");

pub const Entry = packed struct(u832) {
    rsv_a: u32 = undefined,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    rsv_b: u64 = undefined,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    rsv_c: u80 = undefined,
    iopb: u16 = 0,
};

const log = std.log.scoped(.tss);

var allocator: std.mem.Allocator = undefined;

var tss: Entry = .{};

var syscall_stack: []u8 = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    allocator = alloc;

    syscall_stack = try allocator.alloc(u8, 4096 * 16);
    tss.rsp0 = @intFromPtr(&syscall_stack[syscall_stack.len - 1]);
    log.debug("Writing TSS entry", .{});
    gdt.setTss(&tss);
}
