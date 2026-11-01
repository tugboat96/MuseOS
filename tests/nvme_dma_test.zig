const std = @import("std");
const testing = std.testing;

// DirectStorage & NVMe DMA hardware test constants
pub const DIRECT_STORAGE_MAGIC: u64 = 0x44535F4D454D5F3644; // "DS_MEM_6D"
pub const PAGE_SIZE_4K: u64 = 4096;
pub const PAGE_SIZE_2MB: u64 = 2 * 1024 * 1024;

pub const DmaTransferStatus = enum(u32) {
    Success = 0,
    InvalidAlignment = 1,
    InvalidMagic = 2,
    QueueOverflow = 3,
    HardwareFault = 4,
};

pub const DirectStorageDescriptor = extern struct {
    phys_src_addr: u64,
    phys_dst_vram_addr: u64,
    transfer_bytes: u64,
    sub_queue_id: u16,
    flags: u16,
    reserved: u32,

    pub fn isValid(self: DirectStorageDescriptor) bool {
        if (self.transfer_bytes == 0) return false;
        if ((self.phys_src_addr % PAGE_SIZE_4K) != 0) return false;
        if ((self.phys_dst_vram_addr % PAGE_SIZE_4K) != 0) return false;
        return true;
    }
};

pub const DirectStorageHeader = extern struct {
    magic: u64,
    capacity: u32,
    active_count: u32,
    reserved: u64,

    pub fn validate(self: DirectStorageHeader) bool {
        return self.magic == DIRECT_STORAGE_MAGIC and self.capacity >= self.active_count;
    }
};

pub const NvmeDmaTestHarness = struct {
    descriptors: [16]DirectStorageDescriptor = undefined,
    header: DirectStorageHeader = undefined,

    pub fn init() NvmeDmaTestHarness {
        return .{
            .header = .{
                .magic = DIRECT_STORAGE_MAGIC,
                .capacity = 16,
                .active_count = 0,
                .reserved = 0,
            },
        };
    }

    pub fn submitTransfer(self: *NvmeDmaTestHarness, desc: DirectStorageDescriptor) DmaTransferStatus {
        if (!self.header.validate()) return .InvalidMagic;
        if (!desc.isValid()) return .InvalidAlignment;
        if (self.header.active_count >= self.header.capacity) return .QueueOverflow;

        self.descriptors[self.header.active_count] = desc;
        self.header.active_count += 1;
        return .Success;
    }
};

test "DirectStorage Header Validation" {
    const harness = NvmeDmaTestHarness.init();
    try testing.expect(harness.header.validate());
    try testing.expectEqual(DIRECT_STORAGE_MAGIC, harness.header.magic);
}

test "Aligned NVMe DMA Transfer Submission" {
    var harness = NvmeDmaTestHarness.init();
    const desc = DirectStorageDescriptor{
        .phys_src_addr = 0x100000,
        .phys_dst_vram_addr = 0xE0000000,
        .transfer_bytes = 65536,
        .sub_queue_id = 1,
        .flags = 0x01,
        .reserved = 0,
    };

    const status = harness.submitTransfer(desc);
    try testing.expectEqual(DmaTransferStatus.Success, status);
    try testing.expectEqual(@as(u32, 1), harness.header.active_count);
}

test "Misaligned Physical Address Rejection" {
    var harness = NvmeDmaTestHarness.init();
    const desc = DirectStorageDescriptor{
        .phys_src_addr = 0x100005, // Misaligned address
        .phys_dst_vram_addr = 0xE0000000,
        .transfer_bytes = 4096,
        .sub_queue_id = 1,
        .flags = 0,
        .reserved = 0,
    };

    const status = harness.submitTransfer(desc);
    try testing.expectEqual(DmaTransferStatus.InvalidAlignment, status);
    try testing.expectEqual(@as(u32, 0), harness.header.active_count);
}

test "Queue Overflow Prevention" {
    var harness = NvmeDmaTestHarness.init();
    const desc = DirectStorageDescriptor{
        .phys_src_addr = 0x200000,
        .phys_dst_vram_addr = 0xF0000000,
        .transfer_bytes = 4096,
        .sub_queue_id = 2,
        .flags = 0,
        .reserved = 0,
    };

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        _ = harness.submitTransfer(desc);
    }

    const overflow_status = harness.submitTransfer(desc);
    try testing.expectEqual(DmaTransferStatus.QueueOverflow, overflow_status);
}
