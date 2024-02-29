const std = @import("std");
const cpu = @import("cpu.zig");
const tss = @import("tss.zig");

pub const Entry = packed struct(u64) {
    limit_a: u16,
    base_a: u24,
    access: Access,
    limit_b: u4,
    flags: Flags,
    base_b: u8,

    pub const Access = packed struct(u8) {
        accessed: bool = false,
        read_write: bool,
        direction_conforming: bool,
        executable: bool,
        type: Type,
        dpl: u2,
        present: bool,

        pub const Type = enum(u1) {
            system = 0,
            normal = 1,
        };
    };

    pub const Flags = packed struct(u4) {
        rsv: u1 = undefined,
        long_code: bool,
        size: bool,
        granularity: bool,
    };
};

pub const Gdtd = packed struct(u80) {
    size: u16,
    offset: u64,
};

const log = std.log.scoped(.gdt);

pub const selectors = .{
    .kcode_16 = 0x08,
    .kdata_16 = 0x10,
    .kcode_32 = 0x18,
    .kdata_32 = 0x20,
    .kcode_64 = 0x28,
    .kdata_64 = 0x30,
    .udata_64 = 0x38 | 0x03,
    .ucode_64 = 0x40 | 0x03,
    .tss = 0x48,
};

var gdt = [_]Entry{
    @bitCast(@as(u64, 0)), // Null descriptor
    .{
        .limit_a = 65535,
        .base_a = 0,
        .access = .{
            .read_write = true,
            .direction_conforming = false,
            .executable = true,
            .type = .normal,
            .dpl = 0,
            .present = true,
        },
        .limit_b = 0,
        .flags = .{
            .long_code = false,
            .size = false,
            .granularity = false,
        },
        .base_b = 0,
    },
    .{
        .limit_a = 65535,
        .base_a = 0,
        .access = .{
            .read_write = true,
            .direction_conforming = false,
            .executable = false,
            .type = .normal,
            .dpl = 0,
            .present = true,
        },
        .limit_b = 0,
        .flags = .{
            .long_code = false,
            .size = false,
            .granularity = false,
        },
        .base_b = 0,
    },
    .{
        .limit_a = 65535,
        .base_a = 0,
        .access = .{
            .read_write = true,
            .direction_conforming = false,
            .executable = true,
            .type = .normal,
            .dpl = 0,
            .present = true,
        },
        .limit_b = 15,
        .flags = .{
            .long_code = false,
            .size = true,
            .granularity = true,
        },
        .base_b = 0,
    },
    .{
        .limit_a = 65535,
        .base_a = 0,
        .access = .{
            .read_write = true,
            .direction_conforming = false,
            .executable = false,
            .type = .normal,
            .dpl = 0,
            .present = true,
        },
        .limit_b = 15,
        .flags = .{
            .long_code = false,
            .size = true,
            .granularity = true,
        },
        .base_b = 0,
    },
    .{
        .limit_a = 0,
        .base_a = 0,
        .access = .{
            .read_write = true,
            .direction_conforming = false,
            .executable = true,
            .type = .normal,
            .dpl = 0,
            .present = true,
        },
        .limit_b = 0,
        .flags = .{
            .long_code = true,
            .size = false,
            .granularity = false,
        },
        .base_b = 0,
    },
    .{
        .limit_a = 0,
        .base_a = 0,
        .access = .{
            .read_write = true,
            .direction_conforming = false,
            .executable = false,
            .type = .normal,
            .dpl = 0,
            .present = true,
        },
        .limit_b = 0,
        .flags = .{
            .long_code = false,
            .size = false,
            .granularity = false,
        },
        .base_b = 0,
    },
    .{
        .limit_a = 0,
        .base_a = 0,
        .access = .{
            .read_write = true,
            .direction_conforming = false,
            .executable = false,
            .type = .normal,
            .dpl = 3,
            .present = true,
        },
        .limit_b = 0,
        .flags = .{
            .long_code = false,
            .size = false,
            .granularity = false,
        },
        .base_b = 0,
    },
    .{
        .limit_a = 0,
        .base_a = 0,
        .access = .{
            .read_write = true,
            .direction_conforming = false,
            .executable = true,
            .type = .normal,
            .dpl = 3,
            .present = true,
        },
        .limit_b = 0,
        .flags = .{
            .long_code = true,
            .size = false,
            .granularity = false,
        },
        .base_b = 0,
    },
    // TSS
    @bitCast(@as(u64, 0)),
    @bitCast(@as(u64, 0)),
};

var gdtd: Gdtd = undefined;

pub fn init() void {
    log.debug("Initializing", .{});
    defer log.debug("Initialization done", .{});

    gdtd = .{
        .offset = @intFromPtr(&gdt),
        .size = @sizeOf(@TypeOf(gdt)) - 1,
    };

    log.debug("Loading GDT...", .{});
    cpu.lgdt(&gdtd);
    log.debug("GDT loaded", .{});
}

pub fn setTss(entry: *const tss.Entry) void {
    gdt[9] = @bitCast(((@sizeOf(tss.Entry) - 1) & 0xffff) | ((@intFromPtr(entry) & 0xffffff) << 16) | (0b1001 << 40) | (1 << 47) | (((@intFromPtr(entry) >> 24) & 0xff) << 56));
    gdt[10] = @bitCast(@intFromPtr(entry) >> 32);
    cpu.ltr(selectors.tss);
}
