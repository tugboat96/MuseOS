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
    // Modules Definition for Kernel Imports
    // ------------------------------------------------------------------------
    const paging_mod = b.addModule("paging", .{
        .root_source_file = b.path("kernel/src/memory/paging.zig"),
        .target = target,
        .optimize = optimize,
    });
    const direct_storage_mod = b.addModule("direct_storage", .{
        .root_source_file = b.path("kernel/src/memory/direct_storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    const serial_mod = b.addModule("serial", .{
        .root_source_file = b.path("system_services/drivers/serial/serial_lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vga_mod = b.addModule("vga", .{
        .root_source_file = b.path("system_services/drivers/vga/vga_lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fs_cow_module = b.addModule("fs_cow", .{
        .root_source_file = b.path("system_services/fs_cow/src/asm_bindings.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ------------------------------------------------------------------------
    // 1. Kernel Executable (boot.S -> kernel_main.zig)
    // ------------------------------------------------------------------------
    const kernel_elf = b.addExecutable(.{
        .name = "museos-kernel.elf",
        .root_source_file = b.path("kernel/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Bare-metal AMD64 assembly objects
    kernel_elf.addAssemblyFile(b.path("kernel/asm/boot/boot.S"));
    kernel_elf.addAssemblyFile(b.path("kernel/asm/cow_allocator/block_scan.S"));
    kernel_elf.addAssemblyFile(b.path("kernel/asm/interrupts/idt.S"));

    // Add Kernel Memory & Driver Modules
    kernel_elf.root_module.addImport("paging", paging_mod);
    kernel_elf.root_module.addImport("direct_storage", direct_storage_mod);
    kernel_elf.root_module.addImport("serial", serial_mod);
    kernel_elf.root_module.addImport("vga", vga_mod);

    kernel_elf.setLinkerScript(b.path("kernel/linker.ld"));

    b.installArtifact(kernel_elf);

    // ------------------------------------------------------------------------
    // 2. System Services & Drivers Daemons (Standalone Freestanding Binaries)
    // ------------------------------------------------------------------------

    // Serial COM1 UART Driver Daemon
    const serial_driver = b.addExecutable(.{
        .name = "serial_driver_daemon",
        .root_source_file = b.path("system_services/drivers/serial/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(serial_driver);

    // VGA Text & Framebuffer Driver Daemon
    const vga_driver = b.addExecutable(.{
        .name = "vga_driver_daemon",
        .root_source_file = b.path("system_services/drivers/vga/vga_framebuffer.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(vga_driver);

    // RMO Name Resolver System Daemon
    const name_resolver = b.addExecutable(.{
        .name = "name_resolver_daemon",
        .root_source_file = b.path("system_services/name_resolver/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    name_resolver.root_module.addImport("fs_cow", fs_cow_module);
    b.installArtifact(name_resolver);

    // DirectStorage NVMe DMA Driver Daemon
    const nvme_driver = b.addExecutable(.{
        .name = "nvme_driver_daemon",
        .root_source_file = b.path("system_services/drivers/nvme/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    nvme_driver.root_module.addImport("direct_storage", direct_storage_mod);
    b.installArtifact(nvme_driver);

    // AMD-Vi IOMMU Translation Driver Daemon
    const iommu_driver = b.addExecutable(.{
        .name = "iommu_driver_daemon",
        .root_source_file = b.path("system_services/drivers/iommu/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(iommu_driver);

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

    const rust_step = b.step("user_space", "Build user-space Rust applications & Vulkan compositor");
    rust_step.dependOn(&cargo_build.step);

    // ------------------------------------------------------------------------
    // 4. QEMU Emulation & Testing
    // ------------------------------------------------------------------------
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-kernel",
        b.pathJoin(&.{ b.install_path, "bin", "museos-kernel.elf" }),
        "-m",
        "2G",
        "-serial",
        "stdio",
        "-vga",
        "std",
    });
    qemu_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run MuseOS kernel inside QEMU x86_64 emulator with VGA display");
    run_step.dependOn(&qemu_cmd.step);

    // Master meta-step to trigger full OS build
    const all_step = b.step("all", "Build all MuseOS kernel, daemons, and Rust user-space crates");
    all_step.dependOn(b.getInstallStep());
    all_step.dependOn(&cargo_build.step);
}
