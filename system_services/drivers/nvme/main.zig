const std = @import("std");
const direct_storage = @import("direct_storage");

pub const NvmeError = error{
    ControllerNotReady,
    CommandExecutionFailed,
};

// Standalone Freestanding Daemon Entry Point
export fn _start() callconv(.C) noreturn {
    _ = direct_storage;
    while (true) {
        asm volatile ("hlt");
    }
}
