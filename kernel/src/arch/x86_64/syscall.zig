const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");

const log = std.log.scoped(.syscall);

pub fn init() void {
    log.debug("Initializing...", .{});
    defer log.debug("Initialization done", .{});

    comptime {
        std.debug.assert(gdt.selectors.kdata_64 == gdt.selectors.kcode_64 + 8);
        std.debug.assert(gdt.selectors.ucode_64 == gdt.selectors.udata_64 + 8);
    }

    cpu.Msr.write(.STAR, (gdt.selectors.kcode_64 << 32) | ((gdt.selectors.udata_64 - 8) << 48));
    cpu.Msr.write(.LSTAR, @intFromPtr(&syscallEntry));
    cpu.Msr.write(.EFER, cpu.Msr.read(.EFER) | 1);
    cpu.Msr.write(.SF_MASK, 0b1111110111111111010101);
}

fn syscallEntry() callconv(.Naked) void {
    cpu.halt();
}
