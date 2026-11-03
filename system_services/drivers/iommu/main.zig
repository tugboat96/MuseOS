//! AMD-Vi (AMD IOMMU) DMA Translation Driver for MuseOS

const std = @import("std");

pub const DeviceTableEntry = packed struct(u256) {
    valid: u1 = 1,
    translation_valid: u1 = 1,
    paging_mode: u3 = 0b100,
    page_table_root: u40 = 0,
    io_read_permission: u1 = 1,
    io_write_permission: u1 = 1,
    domain_id: u16 = 0,
    reserved: u192 = 0,
};

pub const CommandEntry = packed struct(u128) {
    opcode: u4,
    flags: u4,
    reserved0: u8,
    domain_id: u16,
    address_lo: u32,
    address_hi: u32,
    reserved1: u32,
};

pub const MMIO_OFFSET_DEV_TABLE_PTR: usize = 0x0000;
pub const MMIO_OFFSET_CMD_BUF_PTR: usize = 0x0008;
pub const MMIO_OFFSET_CONTROL: usize = 0x0018;
pub const MMIO_OFFSET_CMD_HEAD: usize = 0x2000;
pub const MMIO_OFFSET_CMD_TAIL: usize = 0x2008;

pub const IommuError = error{
    UnalignedAddress,
    DeviceTableOverflow,
};

pub const IommuDriver = struct {
    mmio_base: [*]volatile u8,
    device_table: [*]DeviceTableEntry,
    cmd_buffer: [*]CommandEntry,
    cmd_tail: u32,
    cmd_buffer_size: u32,

    pub fn mapDeviceDomain(
        self: *IommuDriver,
        device_id: u16,
        domain_id: u16,
        io_pt_root_phys: usize,
    ) IommuError!void {
        const dte = DeviceTableEntry{
            .valid = 1,
            .translation_valid = 1,
            .paging_mode = 0b100,
            .page_table_root = @truncate(io_pt_root_phys >> 12),
            .io_read_permission = 1,
            .io_write_permission = 1,
            .domain_id = domain_id,
        };

        self.device_table[device_id] = dte;
    }
};

// Standalone Freestanding Daemon Entry Point
export fn _start() callconv(.C) noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
