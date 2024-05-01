const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const hal = @import("hal.zig");
const smp = @import("smp.zig");
const pmm = @import("mm/pmm.zig");
const acpi = @import("acpi.zig");
const vfs = @import("fs/vfs.zig");
const devfs = @import("fs/devfs.zig");
const initrd = @import("initrd.zig");
const crofs = @import("fs/crofs.zig");
const framebuffer = @import("framebuffer.zig");
const tty = @import("tty.zig");
const task = @import("task.zig");

pub const os = @import("os.zig");

const log = std.log.scoped(.core);

const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/start.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};

comptime {
    if (!builtin.is_test) {
        @export(arch._start, .{ .name = "_start" });
    }
}

// TODO: Fix GPA
//var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true, .MutexType = smp.SpinLock }){};
//const allocator = gpa.allocator();
const allocator = std.heap.page_allocator;

var init_done: bool = false;

var log_lock = smp.SpinLock{};

pub fn logFn(comptime message_level: std.log.Level, comptime scope: @Type(.EnumLiteral), comptime format: []const u8, args: anytype) void {
    log_lock.lock();
    defer log_lock.unlock();

    const prefix = "\x1b[90m(\x1b[1m{d}\x1b[0m\x1b[90m)\x1b[0m" ++ switch (message_level) {
        .info => "\x1b[34m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
        .debug => "\x1b[90m",
    } ++ "[" ++ @tagName(message_level) ++ "]\x1b[0m (" ++ @tagName(scope) ++ ")";

    const DebugconWriter = struct {
        pub fn writeFn(_: *const anyopaque, bytes: []const u8) error{}!usize {
            for (bytes) |char| {
                hal.debugcon(char);
                if (char == '\n') {
                    for (0..prefix.len - 34) |_| hal.debugcon(' ');
                    hal.debugcon('|');
                    hal.debugcon(' ');
                }
            }

            return bytes.len;
        }
    };

    const debugcon_writer = DebugconWriter{};

    const writer = std.io.AnyWriter{ .context = &debugcon_writer, .writeFn = DebugconWriter.writeFn };

    std.fmt.format(writer, prefix ++ " " ++ format, .{smp.cpuid()} ++ args) catch unreachable;

    hal.debugcon('\n');
}

pub const std_options = .{
    .logFn = logFn,
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);

    log.err(
        \\PANIC: {s}
        \\Core {d} panicked at 0x{x}
    , .{ msg, smp.cpuid(), ret_addr orelse @returnAddress() });

    hal.halt();
}

pub fn start() noreturn {
    log.info("Booting chain (v{})", .{options.version});
    smp.init(startCpu);
}

fn startCpu() callconv(.C) noreturn {
    init() catch |e| switch (e) {
        inline else => |err| @panic("Error: " ++ @errorName(err)),
    };
    deinit();
    hal.halt();
}

fn init() !void {
    hal.disableInterrupts();

    if (smp.cpuid() == 0) {
        arch.initCpuBarebones();
        pmm.init();
        try acpi.init();
        try arch.initCpu(allocator);

        try vfs.init(allocator);
        try devfs.init(allocator);
        try initrd.init(allocator);
        try crofs.init();
        try vfs.mountDevice("/dev/initrd", "/");
        try arch.initDevices(allocator);
        try framebuffer.init(allocator);
        try tty.init();
        try task.init(allocator);
        log.debug("Initalization used {} pages", .{pmm.countUsed()});

        try task.addRoot("/bin/init");

        init_done = true;
    } else {
        while (!init_done) {}
    }

    if (smp.cpuid() != 0) {
        log.debug("Initializing core {d}...", .{smp.cpuid()});
        defer log.debug("Core {d} initialization done", .{smp.cpuid()});
        arch.initCpuBarebones();
        try arch.initCpu(allocator);
    }

    hal.enableInterrupts();

    task.start();
}

fn deinit() void {
    log.debug("Deinitializing...", .{});
    defer log.debug("Deinitialization done", .{});

    if (smp.cpuid() == 0) {
        task.deinit();
        tty.deinit();
        framebuffer.deinit();
        vfs.unmountNode("/") catch unreachable;
        initrd.deinit();
        devfs.deinit();
        vfs.deinit();
        arch.deinit();
    }

    log.debug("Checking for memory leaks", .{});

    if (smp.cpuid() == 0) {
        // TODO: Fix GPA
        //switch (gpa.deinit()) {
        //    .ok => log.debug("No memory leaked", .{}),
        //    .leak => log.err("Memory leaked", .{}),
        //}
    }
}
