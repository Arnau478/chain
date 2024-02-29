const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const int = @import("int.zig");
const paging = @import("paging.zig");
const pmm = @import("../../mm/pmm.zig");
const acpi = @import("../../acpi.zig");
const vfs = @import("../../fs/vfs.zig");
const devfs = @import("../../fs/devfs.zig");
const initrd = @import("../../initrd.zig");
const crofs = @import("../../fs/crofs.zig");
const framebuffer = @import("../../framebuffer.zig");
const tss = @import("tss.zig");
const syscall = @import("syscall.zig");

const log = std.log.scoped(.core);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

comptime {
    if (!builtin.is_test) {
        @export(_start, .{ .name = "_start" });
    }
}

fn _start() callconv(.C) noreturn {
    cpu.cli();

    for (0..4) |_| cpu.outb(0xE9, '\n');

    init() catch |e| switch (e) {
        inline else => |err| @panic("Error: " ++ @errorName(err)),
    };
    deinit();

    switch (gpa.deinit()) {
        .ok => log.debug("No memory leaked", .{}),
        .leak => log.err("Memory leaked", .{}),
    }

    cpu.halt();
}

fn init() !void {
    log.info("Booting chain (v{})", .{options.version});

    gdt.init();
    int.init();
    paging.init();
    pmm.init();
    try tss.init(allocator);
    syscall.init();
    try acpi.init();
    try vfs.init(allocator);
    try devfs.init(allocator);
    try initrd.init(allocator);
    try crofs.init();
    try vfs.mountDevice("/dev/initrd", "/");
    try framebuffer.init(allocator);

    {
        const motd = try vfs.openPath("/etc/motd");
        defer motd.close();
        var buffer = try allocator.alloc(u8, motd.length);
        defer allocator.free(buffer);
        const read_bytes = motd.read(0, buffer);
        log.debug("MOTD: \"{s}\"", .{buffer[0..read_bytes]});
    }

    log.debug("Initalization used {} pages", .{pmm.countUsed()});

    log.info("Hello from chain", .{});

    asm volatile ("sysretq"
        :
        : [fun] "{ecx}" (&user_fun),
          [flags] "{r11}" (0x202),
    );
}

fn user_fun() callconv(.Naked) void {
    while (true) {}
}

fn deinit() void {
    log.debug("Deinitializing...", .{});
    defer log.debug("Deinitialization done", .{});

    framebuffer.deinit();
    vfs.unmountNode("/") catch unreachable;
    initrd.deinit();
    devfs.deinit();
    vfs.deinit();
}

test {
    _ = std.testing.refAllDeclsRecursive(int);
    _ = std.testing.refAllDeclsRecursive(paging);
}
