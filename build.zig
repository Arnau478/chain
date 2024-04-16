const std = @import("std");

const version = std.SemanticVersion.parse("0.1.0-dev") catch unreachable;

pub fn getKernelTarget(b: *std.Build, arch: std.Target.Cpu.Arch) !std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = switch (arch) {
            .x86_64 => blk: {
                var features = std.Target.Cpu.Feature.Set.empty;
                features.addFeature(@intFromEnum(std.Target.x86.Feature.soft_float));
                break :blk features;
            },
            else => return error.UnsupportedArch,
        },
        .cpu_features_sub = switch (arch) {
            .x86_64 => blk: {
                var features = std.Target.Cpu.Feature.Set.empty;
                features.addFeature(@intFromEnum(std.Target.x86.Feature.mmx));
                features.addFeature(@intFromEnum(std.Target.x86.Feature.sse));
                features.addFeature(@intFromEnum(std.Target.x86.Feature.sse2));
                features.addFeature(@intFromEnum(std.Target.x86.Feature.avx));
                features.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));
                break :blk features;
            },
            else => return error.UnsupportedArch,
        },
    });
}

pub fn build(b: *std.Build) !void {
    const build_options = .{
        .arch = b.option(std.Target.Cpu.Arch, "arch", "The architecture to build for") orelse b.host.result.cpu.arch,
    };

    const kernel_target = try getKernelTarget(b, build_options.arch);

    const optimize = b.standardOptimizeOption(.{});

    var tools = std.StringHashMap(*std.Build.Step.Compile).init(b.allocator);
    defer tools.deinit();
    const tools_dir = try b.build_root.handle.openDir("tools", .{ .iterate = true });
    var tools_iter = tools_dir.iterate();
    while (try tools_iter.next()) |tool| {
        const name = std.fs.path.stem(tool.name);
        const exe = b.addExecutable(.{
            .name = name,
            .target = b.host,
            .root_source_file = .{ .path = b.fmt("tools/{s}.zig", .{name}) },
            .optimize = .ReleaseSafe,
        });

        const exe_step = b.step(name, b.fmt("Build {s}", .{name}));
        exe_step.dependOn(&exe.step);

        try tools.put(name, exe);

        const run_cmd = b.addRunArtifact(exe);

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name}));
        run_step.dependOn(&run_cmd.step);
    }

    const limine_zig = b.dependency("limine_zig", .{}).module("limine");

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "kernel/src/main.zig" },
        .target = kernel_target,
        .optimize = optimize,
        .single_threaded = true,
        .code_model = .kernel,
        .pic = true,
    });
    kernel.root_module.addImport("limine", limine_zig);
    kernel.setLinkerScript(.{ .path = b.fmt("kernel/linker-{s}.ld", .{@tagName(build_options.arch)}) });

    const kernel_options = b.addOptions();
    kernel_options.addOption(std.SemanticVersion, "version", version);
    kernel.root_module.addOptions("options", kernel_options);

    const kernel_step = b.step("kernel", "Build the kernel");
    kernel_step.dependOn(&b.addInstallArtifact(kernel, .{}).step);

    const initrd_dir = b.addWriteFiles();
    {
        const base_dir = try b.build_root.handle.openDir("base", .{ .iterate = true });
        var walker = try base_dir.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                _ = initrd_dir.addCopyFile(.{ .path = try base_dir.realpathAlloc(b.allocator, entry.path) }, entry.path);
            }
        }
    }
    const initrd_cmd = b.addRunArtifact(tools.get("crofs-utils").?);
    initrd_cmd.addArg("create");
    const initrd = initrd_cmd.addOutputFileArg("initrd");
    initrd_cmd.addDirectoryArg(initrd_dir.getDirectory());
    var initrd_file_list = std.ArrayList([]const u8).init(b.allocator);
    defer initrd_file_list.deinit();
    {
        const base_dir = try b.build_root.handle.openDir("base", .{ .iterate = true });
        var walker = try base_dir.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                try initrd_file_list.append(try base_dir.realpathAlloc(b.allocator, entry.path));
            }
        }
    }
    initrd_cmd.extra_file_dependencies = try initrd_file_list.toOwnedSlice();

    const initrd_step = b.step("initrd", "Build the initrd");
    initrd_step.dependOn(&b.addInstallFile(initrd, "initrd").step);

    const apps_dir = try b.build_root.handle.openDir("user/apps", .{ .iterate = true });
    var apps_iter = apps_dir.iterate();
    while (try apps_iter.next()) |app_entry| {
        const name = std.fs.path.stem(app_entry.name);

        const exe = b.addExecutable(.{
            .name = name,
            .target = b.resolveTargetQuery(.{
                .cpu_arch = build_options.arch,
                .os_tag = .other,
                .abi = .none,
            }),
            .optimize = .ReleaseSmall,
            .root_source_file = .{ .path = b.fmt("user/apps/{s}/main.zig", .{name}) },
        });

        const objcopy = b.addObjCopy(exe.getEmittedBin(), .{
            .format = .bin,
        });

        _ = initrd_dir.addCopyFile(objcopy.getOutput(), b.fmt("bin/{s}", .{name}));
    }

    const limine = b.dependency("limine", .{});

    const limine_exe = b.addExecutable(.{
        .name = "limine",
        .target = b.host,
        .optimize = .ReleaseSafe,
    });
    limine_exe.addCSourceFile(.{ .file = limine.path("limine.c"), .flags = &[_][]const u8{"-std=c99"} });
    limine_exe.linkLibC();
    const limine_exe_run = b.addRunArtifact(limine_exe);

    const iso_tree = b.addWriteFiles();
    _ = iso_tree.addCopyFile(kernel.getEmittedBin(), "kernel.elf");
    _ = iso_tree.addCopyFile(initrd, "initrd");
    _ = iso_tree.addCopyFile(.{ .path = "limine.cfg" }, "limine.cfg");
    _ = iso_tree.addCopyFile(limine.path("limine-bios.sys"), "limine-bios.sys");
    _ = iso_tree.addCopyFile(limine.path("limine-bios-cd.bin"), "limine-bios-cd.bin");
    _ = iso_tree.addCopyFile(limine.path("limine-uefi-cd.bin"), "limine-uefi-cd.bin");
    _ = iso_tree.addCopyFile(limine.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = iso_tree.addCopyFile(limine.path("BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");

    const iso_cmd = b.addSystemCommand(&.{"xorriso"});
    iso_cmd.addArg("-as");
    iso_cmd.addArg("mkisofs");
    iso_cmd.addArg("-b");
    iso_cmd.addArg("limine-bios-cd.bin");
    iso_cmd.addArg("-no-emul-boot");
    iso_cmd.addArg("-boot-load-size");
    iso_cmd.addArg("4");
    iso_cmd.addArg("-boot-info-table");
    iso_cmd.addArg("--efi-boot");
    iso_cmd.addArg("limine-uefi-cd.bin");
    iso_cmd.addArg("-efi-boot-part");
    iso_cmd.addArg("--efi-boot-image");
    iso_cmd.addArg("--protective-msdos-label");
    iso_cmd.addDirectoryArg(iso_tree.getDirectory());
    iso_cmd.addArg("-o");
    const xorriso_iso_output = iso_cmd.addOutputFileArg("chain.iso");

    limine_exe_run.addArg("bios-install");
    limine_exe_run.addFileArg(xorriso_iso_output);

    const iso_output_dir = b.addWriteFiles();
    iso_output_dir.step.dependOn(&limine_exe_run.step);
    const iso_output = iso_output_dir.addCopyFile(xorriso_iso_output, "chain.iso");

    const iso_step = b.step("iso", "Create an ISO image");
    iso_step.dependOn(&b.addInstallFile(iso_output, "chain.iso").step);
    b.default_step = iso_step;

    const qemu_cmd = b.addSystemCommand(&.{switch (build_options.arch) {
        .x86_64 => "qemu-system-x86_64",
        else => return error.UnsupportedArch,
    }});

    switch (build_options.arch) {
        .x86_64 => {
            qemu_cmd.addArgs(&.{ "-M", "q35" });
            qemu_cmd.addArgs(&.{ "-m", "2G" });
            qemu_cmd.addArg("-cdrom");
            qemu_cmd.addFileArg(iso_output);
            qemu_cmd.addArgs(&.{ "-boot", "d" });
            qemu_cmd.addArgs(&.{ "-debugcon", "stdio" });
        },
        else => return error.UnsupportedArch,
    }

    const qemu_step = b.step("qemu", "Run in QEMU");
    qemu_step.dependOn(&qemu_cmd.step);
}
