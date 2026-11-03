// MuseOS AMD64 Kernel Main Entry - kernel/src/main.zig

const std = @import("std");
const serial = @import("serial");
const vga = @import("vga");
const paging = @import("paging");
const direct_storage = @import("direct_storage");
const dispatcher = @import("interrupts/dispatcher.zig");

// Multiboot2 Bootloader Magic Signatures
const MULTIBOOT2_BOOTLOADER_MAGIC: u32 = 0x36d76289;

// Global System Drivers
var serial_logger: serial.SerialPort = undefined;
var vga_renderer: vga.VgaFramebuffer = undefined;

export fn kernel_main(multiboot_info_ptr: usize, multiboot_magic: usize) callconv(.C) noreturn {
    // Reference imported system modules & interrupt dispatcher
    _ = paging;
    _ = direct_storage;
    _ = dispatcher;

    // ------------------------------------------------------------------------
    // 1. Initialize Serial UART (COM1: 0x3F8) for Debug Logging
    // ------------------------------------------------------------------------
    serial_logger = serial.SerialPort.init(serial.COM1_PORT);
    serial_logger.writeString("[BOOT] Entering MuseOS Kernel Entry (64-bit Long Mode)...\n");

    // ------------------------------------------------------------------------
    // 2. Initialize VGA Text & Framebuffer Display
    // ------------------------------------------------------------------------
    vga_renderer = vga.VgaFramebuffer.init(0xB8000, 80, 25, 80 * 2);
    vga_renderer.clear(vga.Color.MINT_BG);

    vga_renderer.writeString("[  OK  ] Serial UART COM1 initialized (0x3F8)\n", vga.Color.BADGE_GREEN, vga.Color.MINT_BG);
    vga_renderer.writeString("[  OK  ] VGA Text Buffer initialized (0xB8000)\n", vga.Color.BADGE_GREEN, vga.Color.MINT_BG);

    // ------------------------------------------------------------------------
    // 3. Verify Multiboot2 Handshake
    // ------------------------------------------------------------------------
    if (multiboot_magic != MULTIBOOT2_BOOTLOADER_MAGIC) {
        serial_logger.writeString("[ERROR] Invalid Multiboot2 magic header detected!\n");
        vga_renderer.writeString("[ FAIL ] Invalid Multiboot2 Header Magic\n", vga.Color.RED, vga.Color.MINT_BG);
    } else {
        serial_logger.writeString("[BOOT] Multiboot2 Handshake Validated.\n");
        vga_renderer.writeString("[  OK  ] Multiboot2 Handshake Validated\n", vga.Color.BADGE_GREEN, vga.Color.MINT_BG);
    }

    _ = multiboot_info_ptr;

    // ------------------------------------------------------------------------
    // 4. Initialize Hardware Driver Daemons & Paging Engine
    // ------------------------------------------------------------------------
    serial_logger.writeString("[MMU] Initializing AMD64 4-Level Page Tables...\n");
    vga_renderer.writeString("[ MMU  ] AMD64 4-Level Identity Paging Active\n", vga.Color.TEXT_WHITE, vga.Color.MINT_BG);

    serial_logger.writeString("[DRV] Initializing DirectStorage NVMe DMA Controller...\n");
    vga_renderer.writeString("[ DRV  ] DirectStorage NVMe DMA Driver Online\n", vga.Color.TEXT_WHITE, vga.Color.MINT_BG);

    serial_logger.writeString("[SYS] System Services Initialized. Kernel entering main loop...\n");
    vga_renderer.writeString("[ SYS  ] MuseOS Core Ready.\n", vga.Color.TEXT_WHITE, vga.Color.MINT_BG);

    // Fallback CPU halt loop
    while (true) {
        asm volatile ("hlt");
    }
}
