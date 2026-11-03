const std = @import("std");
const fs_cow = @import("fs_cow");
const rmo = @import("rmo_parser.zig");

pub const ResolverError = error{
    InvalidScheme,
    NotFound,
};

// Standalone Freestanding Daemon Entry Point
export fn _start() callconv(.C) noreturn {
    _ = fs_cow;
    while (true) {
        asm volatile ("hlt");
    }
}
