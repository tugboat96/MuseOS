const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        },
    });

    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------------------
    // 1. Kernel Bootloader & Low-Level Assembly Objects
    // ------------------------------------------------------------------------
    const kernel_elf = b.addExecutable(.{
        .name = "museos-kernel.elf",
        .target = target,
        .optimize = optimize,
    });

    // Multiboot2 entry & paging assembly
    kernel_elf.addAssemblyFile(b.path("kernel/asm/boot/boot.S"));
    // Copy-on-Write bitmap scanning assembly loop
    kernel_elf.addAssemblyFile(b.path("kernel/asm/cow_allocator/block_scan.S"));

    kernel_elf.setLinkerScript(b.path("kernel/linker.ld"));

    b.installArtifact(kernel_elf);

    // ------------------------------------------------------------------------
    // 2. System Services (Zig)
    // ------------------------------------------------------------------------

    // Copy-on-Write Filesystem Daemon / FFI Module
    const fs_cow_module = b.addModule("fs_cow", .{
        .root_source_file = b.path("system_services/fs_cow/src/asm_bindings.zig"),
        .target = target,
        .optimize = optimize,
    });

    // RMO Name Resolver System Daemon
    const name_resolver = b.addExecutable(.{
        .name = "name_resolver_daemon",
        .root_source_file = b.path("system_services/name_resolver/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    name_resolver.root_module.addImport("fs_cow", fs_cow_module);

    b.installArtifact(name_resolver);

    // ------------------------------------------------------------------------
    // 3. User-Space Rust Crates Integration
    // ------------------------------------------------------------------------
    const cargo_build = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--target",
        "x86_64-unknown-none",
        "--release",
        "--manifest-path",
        "user_space/Cargo.toml",
    });

    // Ensure rust components build prior to final OS image bundling
    const rust_step = b.step("user_space", "Build user-space Rust applications & Vulkan compositor");
    rust_step.dependOn(&cargo_build.step);

    // ------------------------------------------------------------------------
    // 4. QEMU Emulation Runner
    // ------------------------------------------------------------------------
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-kernel",
        b.pathJoin(&.{ b.install_path, "bin", "museos-kernel.elf" }),
        "-m",
        "2G",
        "-serial",
        "stdio",
        "-display",
        "none",
    });
    qemu_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run MuseOS kernel inside QEMU x86_64 emulator");
    run_step.dependOn(&qemu_cmd.step);

    // Master meta-step to trigger full OS build
    const all_step = b.step("all", "Build all MuseOS kernel, daemons, and Rust user-space crates");
    all_step.dependOn(b.getInstallStep());
    all_step.dependOn(&cargo_build.step);
}
