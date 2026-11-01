//! AMD-Vi (AMD IOMMU) DMA Translation Driver for MuseOS
//!
//! Provides bare-metal hardware-assisted I/O Virtual Memory (IOMMU) protection
//! and DMA page table translation for PCIe peripherals (e.g. DirectStorage NVMe controllers).

const std = @import("std");

/// Device Table Entry (DTE) - 256 bits (32 bytes) per PCIe Bus/Device/Function (BDF)
pub const DeviceTableEntry = packed struct(u256) {
    /// Valid Bit
    valid: u1 = 1,
    /// Translation Valid Bit
    translation_valid: u1 = 1,
    /// Reserved / Mode bits (Mode 001b = 1-level, Mode 010b = 2-level, Mode 011b = 3-level, Mode 100b = 4-level paging)
    paging_mode: u3 = 0b100,
    /// Page Table Root Physical Address (Bits 51:12 shift)
    page_table_root: u40 = 0,
    /// Interrupt Virtualization / IO Control flags
    io_read_permission: u1 = 1,
    io_write_permission: u1 = 1,
    domain_id: u16 = 0,
    /// Padding / Reserved bits up to 256 bits
    reserved: u192 = 0,
};

/// AMD-Vi I/O Page Table Entry (PTE) - 64 bits
pub const IoPageTableEntry = packed struct(u64) {
    present: u1 = 1,
    read: u1 = 1,
    write: u1 = 1,
    accessed: u1 = 0,
    dirty: u1 = 0,
    reserved0: u7 = 0,
    /// Physical Frame Base Address (4 KiB aligned)
    frame_address: u40 = 0,
    reserved1: u12 = 0,
};

/// AMD-Vi Command Buffer Entry (128 bits / 16 bytes)
pub const CommandEntry = packed struct(u128) {
    opcode: u4,
    flags: u4,
    reserved0: u8,
    domain_id: u16,
    address_lo: u32,
    address_hi: u32,
    reserved1: u32,
};

/// AMD-Vi Register Map Offsets
pub const MMIO_OFFSET_DEV_TABLE_PTR: usize = 0x0000;
pub const MMIO_OFFSET_CMD_BUF_PTR: usize = 0x0008;
pub const MMIO_OFFSET_EVENT_LOG_PTR: usize = 0x0010;
pub const MMIO_OFFSET_CONTROL: usize = 0x0018;
pub const MMIO_OFFSET_CMD_HEAD: usize = 0x2000;
pub const MMIO_OFFSET_CMD_TAIL: usize = 0x2008;

/// AMD-Vi Control Register Bits
pub const CONTROL_IOMMU_ENABLE: u64 = 1 << 0;
pub const CONTROL_CMD_BUF_ENABLE: u64 = 1 << 1;
pub const CONTROL_EVENT_LOG_ENABLE: u64 = 1 << 2;
pub const CONTROL_EVENT_INT_ENABLE: u64 = 1 << 3;

pub const IommuError = error{
    UnalignedAddress,
    DeviceTableOverflow,
    InvalidDeviceID,
    CommandQueueFull,
    HardwareInitializationFailed,
};

pub const IommuDriver = struct {
    mmio_base: [*]volatile u8,
    device_table: [*]DeviceTableEntry,
    cmd_buffer: [*]CommandEntry,
    cmd_tail: u32,
    cmd_buffer_size: u32,

    pub fn init(
        mmio_phys: usize,
        dev_table_phys: usize,
        dev_table_entries: usize,
        cmd_buf_phys: usize,
        cmd_buf_size: u32,
    ) IommuError!IommuDriver {
        if (dev_table_phys % 4096 != 0 or cmd_buf_phys % 4096 != 0) {
            return IommuError.UnalignedAddress;
        }
        if (dev_table_entries > 65536) {
            return IommuError.DeviceTableOverflow;
        }

        const mmio_ptr = @as([*]volatile u8, @ptrFromInt(mmio_phys));
        const dev_tbl_ptr = @as([*]DeviceTableEntry, @ptrFromInt(dev_table_phys));
        const cmd_buf_ptr = @as([*]CommandEntry, @ptrFromInt(cmd_buf_phys));

        var driver = IommuDriver{
            .mmio_base = mmio_ptr,
            .device_table = dev_tbl_ptr,
            .cmd_buffer = cmd_buf_ptr,
            .cmd_tail = 0,
            .cmd_buffer_size = cmd_buf_size,
        };

        // 1. Program Device Table Pointer Register (0x0000)
        // Format: Base Address [51:12] | Size (entries - 1)
        const dev_table_reg_val: u64 = (dev_table_phys & 0x000F_FFFF_FFFF_F000) | ((dev_table_entries / 512) - 1);
        driver.writeMmio64(MMIO_OFFSET_DEV_TABLE_PTR, dev_table_reg_val);

        // 2. Program Command Buffer Pointer Register (0x0008)
        const cmd_buf_count_power: u64 = 8; // 256 entries
        const cmd_buf_reg_val: u64 = (cmd_buf_phys & 0x000F_FFFF_FFFF_F000) | (cmd_buf_count_power << 56);
        driver.writeMmio64(MMIO_OFFSET_CMD_BUF_PTR, cmd_buf_reg_val);

        // Reset head and tail registers
        driver.writeMmio64(MMIO_OFFSET_CMD_HEAD, 0);
        driver.writeMmio64(MMIO_OFFSET_CMD_TAIL, 0);

        // 3. Enable AMD-Vi Hardware & Command Buffer in Control Register
        const control_val = CONTROL_IOMMU_ENABLE | CONTROL_CMD_BUF_ENABLE | CONTROL_EVENT_LOG_ENABLE;
        driver.writeMmio64(MMIO_OFFSET_CONTROL, control_val);

        return driver;
    }

    /// Assigns a PCIe Device (BDF) to a hardware domain and sets its I/O Page Table root pointer
    pub fn mapDeviceDomain(
        self: *IommuDriver,
        device_id: u16,
        domain_id: u16,
        io_pt_root_phys: usize,
    ) IommuError!void {
        var dte = DeviceTableEntry{
            .valid = 1,
            .translation_valid = 1,
            .paging_mode = 0b100, // 4-level paging
            .page_table_root = @truncate(io_pt_root_phys >> 12),
            .io_read_permission = 1,
            .io_write_permission = 1,
            .domain_id = domain_id,
        };

        self.device_table[device_id] = dte;
        try self.invalidateIommuPages(domain_id, 0, 0xFFFF_FFFF_FFFF_FFFF);
    }

    /// Enqueues an INVALIDATE_IOMMU_PAGES command into the Command Buffer
    pub fn invalidateIommuPages(
        self: *IommuDriver,
        domain_id: u16,
        virt_addr: usize,
        size: usize,
    ) IommuError!void {
        _ = size;
        const next_tail = (self.cmd_tail + 1) % self.cmd_buffer_size;

        // Opcode 0x03 = INVALIDATE_IOMMU_PAGES
        const cmd = CommandEntry{
            .opcode = 0x03,
            .flags = 0x01, // Invalidate all pages in range
            .reserved0 = 0,
            .domain_id = domain_id,
            .address_lo = @truncate(virt_addr),
            .address_hi = @truncate(virt_addr >> 32),
            .reserved1 = 0,
        };

        self.cmd_buffer[self.cmd_tail] = cmd;
        self.cmd_tail = next_tail;

        // Write doorbell to notify AMD-Vi hardware
        self.writeMmio64(MMIO_OFFSET_CMD_TAIL, @as(u64, self.cmd_tail) * 16);
    }

    inline fn writeMmio64(self: *IommuDriver, offset: usize, value: u64) void {
        const ptr = @as(*volatile u64, @ptrCast(@alignCast(self.mmio_base + offset)));
        ptr.* = value;
    }

    inline fn readMmio64(self: *IommuDriver, offset: usize) u64 {
        const ptr = @as(*const volatile u64, @ptrCast(@alignCast(self.mmio_base + offset)));
        return ptr.*;
    }
};
