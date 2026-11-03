const std = @import("std");
pub const vga_lib = @import("vga_lib.zig");

// Standalone Freestanding Daemon Entry Point
export fn _start() callconv(.C) noreturn {
    var fb = vga_lib.VgaFramebuffer.init(0xB8000, 80, 25, 80 * 2);
    fb.writeString("[sDDF] VGA Framebuffer Driver Daemon Online.\n", vga_lib.Color.BADGE_GREEN, vga_lib.Color.MINT_BG);
    while (true) {
        asm volatile ("hlt");
    }
}
