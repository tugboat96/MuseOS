const std = @import("std");
pub const serial_lib = @import("serial_lib.zig");

// Standalone Freestanding Daemon Entry Point
export fn _start() callconv(.C) noreturn {
    var port = serial_lib.SerialPort.init(serial_lib.COM1_PORT);
    port.writeString("[sDDF] Serial COM1 Driver Daemon Running.\n");
    while (true) {
        asm volatile ("hlt");
    }
}
