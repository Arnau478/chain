const builtin = @import("builtin");

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/hal.zig"),
    .aarch64 => @import("arch/aarch64/hal.zig"),
    else => |other| @compileError("Unimplemented for " ++ @tagName(other)),
};
