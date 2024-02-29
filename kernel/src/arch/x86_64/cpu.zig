const int = @import("int.zig");
const gdt = @import("gdt.zig");

pub inline fn halt() noreturn {
    while (true) hlt();
}

pub inline fn hlt() void {
    asm volatile ("hlt");
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

pub inline fn outb(port: u16, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [data] "{al}" (data),
          [port] "N{dx}" (port),
    );
}

pub inline fn outw(port: u16, data: u16) void {
    asm volatile ("outw %[data], %[port]"
        :
        : [data] "{ax}" (data),
          [port] "N{dx}" (port),
    );
}

pub inline fn lidt(idtd: *const int.Idtd) void {
    asm volatile ("lidt (%%rax)"
        :
        : [idtd] "{rax}" (idtd),
    );
}

pub inline fn lgdt(gdtd: *const gdt.Gdtd) void {
    asm volatile ("lgdt (%%rax)"
        :
        : [gdtd] "{rax}" (gdtd),
    );
}

pub inline fn ltr(selector: u16) void {
    asm volatile ("ltr %[selector]"
        :
        : [selector] "r" (selector),
    );
}

pub const CpuidResult = struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
};

pub inline fn cpuid(rax_in: u64) CpuidResult {
    var rax_out: u64 = undefined;
    var rbx_out: u64 = undefined;
    var rcx_out: u64 = undefined;
    var rdx_out: u64 = undefined;

    asm volatile ("cpuid"
        : [rax_out] "=%[rax]" (rax_out),
          [rbx_out] "=%[rbx]" (rbx_out),
          [rcx_out] "=%[rcx]" (rcx_out),
          [rdx_out] "=%[rdx]" (rdx_out),
        : [rax_in] "{rax}" (rax_in),
    );

    return .{
        .rax = rax_out,
        .rbx = rbx_out,
        .rcx = rcx_out,
        .rdx = rdx_out,
    };
}

pub const Cr3 = struct {
    pub inline fn write(value: usize) void {
        asm volatile ("mov %[value], %cr3"
            :
            : [value] "r" (value),
        );
    }

    pub inline fn read() usize {
        return asm volatile ("mov %cr3, %[res]"
            : [res] "=r" (-> usize),
        );
    }
};

pub const Msr = struct {
    pub const Register = enum(u32) {
        EFER = 0xC000_0080,
        STAR = 0xC000_0081,
        LSTAR = 0xC000_0082,
        CSTAR = 0xC000_0083,
        SF_MASK = 0xC000_0084,
    };

    pub inline fn write(register: Register, value: usize) void {
        const value_low: u32 = @truncate(value);
        const value_high: u32 = @truncate(value >> 32);

        asm volatile ("wrmsr"
            :
            : [register] "{ecx}" (@intFromEnum(register)),
              [value_low] "{eax}" (value_low),
              [value_high] "{edx}" (value_high),
        );
    }

    pub inline fn read(register: Register) usize {
        var value_low: u32 = undefined;
        var value_high: u32 = undefined;

        asm volatile ("rdmsr"
            : [value_low] "={eax}" (value_low),
              [value_high] "={edx}" (value_high),
            : [register] "{ecx}" (@intFromEnum(register)),
        );

        return (@as(usize, value_high) << 32) | value_low;
    }
};
