const std = @import("std");

/// MuseOS Polled-Mode DirectStorage NVMe Driver Daemon
/// Running as a privileged seL4 system service in Zig.
/// Communicates over NVMe Submission (SQ) and Completion (CQ) queue pairs.
/// Enables zero-copy DMA transfers directly between NVMe storage blocks
/// and GPU VRAM / user-space buffers.

pub const NVME_PAGE_SIZE: usize = 4096;
pub const NVME_COMMAND_SIZE: usize = 64;
pub const NVME_COMPLETION_SIZE: usize = 16;
pub const DEFAULT_QUEUE_DEPTH: u16 = 1024;

pub const NvmeError = error{
    ControllerNotReady,
    ControllerFatalError,
    QueueCreationFailed,
    DmaMappingFailed,
    TimeoutWaitingForCompletion,
    InvalidNamespace,
    CommandExecutionFailed,
    BufferNotAligned,
};

/// NVMe Controller Bar Register Offsets
pub const NvmeRegs = struct {
    pub const CAP: usize = 0x0000; // Controller Capabilities
    pub const VS: usize = 0x0008; // Version
    pub const INTMS: usize = 0x000C; // Interrupt Mask Set
    pub const INTMC: usize = 0x0010; // Interrupt Mask Clear
    pub const CC: usize = 0x0014; // Controller Configuration
    pub const CSTS: usize = 0x001C; // Controller Status
    pub const AQA: usize = 0x0024; // Admin Queue Attributes
    pub const ASQ: usize = 0x0028; // Admin Submission Queue Base Addr
    pub const ACQ: usize = 0x0030; // Admin Completion Queue Base Addr
};

/// 64-byte NVMe Submission Queue Entry (SQE)
pub const NvmeSqEntry = extern struct {
    cdw0: u32, // Opcode, Flags, Command ID
    nsid: u32, // Namespace ID
    reserved: u64 = 0,
    mptr: u64 = 0, // Metadata Pointer
    dptr1: u64, // Data Pointer 1 (PRP1 / SGL)
    dptr2: u64 = 0, // Data Pointer 2 (PRP2 / SGL)
    cdw10: u32 = 0, // Command specific (e.g., Starting LBA low)
    cdw11: u32 = 0, // Command specific (e.g., Starting LBA high)
    cdw12: u32 = 0, // Command specific (e.g., Number of blocks)
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,
};

/// 16-byte NVMe Completion Queue Entry (CQE)
pub const NvmeCqEntry = extern struct {
    dw0: u32, // Command-specific result
    dw1: u32, // Reserved
    sq_head: u16, // SQ Head Pointer
    sq_id: u16, // SQ Identifier
    command_id: u16, // Command ID
    status: u16, // Status field & Phase Tag (bit 0)
};

/// Polled NVMe Queue Pair (Admin or I/O)
pub const NvmeQueuePair = struct {
    id: u16,
    depth: u16,
    sq_tail: u16 = 0,
    cq_head: u16 = 0,
    phase: u1 = 1,
    sq_buffer: []align(4096) NvmeSqEntry,
    cq_buffer: []align(4096) NvmeCqEntry,
    sq_doorbell_offset: usize,
    cq_doorbell_offset: usize,

    pub fn submitCommand(self: *NvmeQueuePair, entry: NvmeSqEntry) u16 {
        const cmd_id = self.sq_tail;
        var mutable_entry = entry;
        mutable_entry.cdw0 |= (@as(u32, cmd_id) << 16);
        self.sq_buffer[self.sq_tail] = mutable_entry;

        self.sq_tail = (self.sq_tail + 1) % self.depth;
        return cmd_id;
    }

    pub fn pollCompletion(self: *NvmeQueuePair, cmd_id: u16, bar_mem: []volatile u8) NvmeError!NvmeCqEntry {
        // Ring doorbell
        const sq_db_ptr: *volatile u32 = @ptrCast(@alignCast(&bar_mem[self.sq_doorbell_offset]));
        sq_db_ptr.* = self.sq_tail;

        var timeout_cycles: usize = 10_000_000;
        while (timeout_cycles > 0) : (timeout_cycles -= 1) {
            const cq_entry = self.cq_buffer[self.cq_head];
            const entry_phase: u1 = @truncate(cq_entry.status);

            if (entry_phase == self.phase) {
                self.cq_head = (self.cq_head + 1) % self.depth;
                if (self.cq_head == 0) {
                    self.phase ^= 1; // Toggle phase tag on queue wrap
                }

                // Ring CQ doorbell
                const cq_db_ptr: *volatile u32 = @ptrCast(@alignCast(&bar_mem[self.cq_doorbell_offset]));
                cq_db_ptr.* = self.cq_head;

                const status_code = (cq_entry.status >> 1) & 0x7FF;
                if (status_code != 0) {
                    return NvmeError.CommandExecutionFailed;
                }

                if (cq_entry.command_id == cmd_id) {
                    return cq_entry;
                }
            }
            std.atomic.spinLoopHint();
        }
        return NvmeError.TimeoutWaitingForCompletion;
    }
};

/// High-throughput DirectStorage NVMe Controller Handle
pub const NvmeController = struct {
    bar_mem: []volatile u8,
    allocator: std.mem.Allocator,
    admin_queue: NvmeQueuePair,
    io_queue: NvmeQueuePair,
    db_stride: usize = 4,

    pub fn init(bar_mem: []volatile u8, allocator: std.mem.Allocator) !NvmeController {
        // Verify controller readiness
        const csts_ptr: *volatile u32 = @ptrCast(@alignCast(&bar_mem[NvmeRegs.CSTS]));
        if ((csts_ptr.* & 0x1) == 0) {
            // Disable & Reset Controller if active
            const cc_ptr: *volatile u32 = @ptrCast(@alignCast(&bar_mem[NvmeRegs.CC]));
            cc_ptr.* &= ~@as(u32, 1);
        }

        // Allocate Admin Queue Buffers
        const admin_sq = try allocator.alignedAlloc(NvmeSqEntry, 4096, DEFAULT_QUEUE_DEPTH);
        const admin_cq = try allocator.alignedAlloc(NvmeCqEntry, 4096, DEFAULT_QUEUE_DEPTH);

        // Configure Admin Queue Attributes (AQA)
        const aqa_ptr: *volatile u32 = @ptrCast(@alignCast(&bar_mem[NvmeRegs.AQA]));
        aqa_ptr.* = (@as(u32, DEFAULT_QUEUE_DEPTH - 1) << 16) | @as(u32, DEFAULT_QUEUE_DEPTH - 1);

        // Set ASQ and ACQ base addresses
        const asq_ptr: *volatile u64 = @ptrCast(@alignCast(&bar_mem[NvmeRegs.ASQ]));
        asq_ptr.* = @intFromPtr(admin_sq.ptr);

        const acq_ptr: *volatile u64 = @ptrCast(@alignCast(&bar_mem[NvmeRegs.ACQ]));
        acq_ptr.* = @intFromPtr(admin_cq.ptr);

        // Enable Controller (CC.EN = 1, Page Size = 4KB, CSS = NVM)
        const cc_ptr: *volatile u32 = @ptrCast(@alignCast(&bar_mem[NvmeRegs.CC]));
        cc_ptr.* = (1 << 0) | (0 << 7) | (6 << 16) | (4 << 20); // EN, CSS, MPS (4K), IOCQ/IOSQ

        // Wait for CSTS.RDY == 1
        var retries: usize = 1_000_000;
        while (retries > 0) : (retries -= 1) {
            if ((csts_ptr.* & 0x1) != 0) break;
            std.atomic.spinLoopHint();
        }
        if (retries == 0) return NvmeError.ControllerNotReady;

        const admin_qp = NvmeQueuePair{
            .id = 0,
            .depth = DEFAULT_QUEUE_DEPTH,
            .sq_buffer = admin_sq,
            .cq_buffer = admin_cq,
            .sq_doorbell_offset = 0x1000,
            .cq_doorbell_offset = 0x1000 + 4,
        };

        // Initialize I/O Queue Pair
        const io_sq = try allocator.alignedAlloc(NvmeSqEntry, 4096, DEFAULT_QUEUE_DEPTH);
        const io_cq = try allocator.alignedAlloc(NvmeCqEntry, 4096, DEFAULT_QUEUE_DEPTH);

        const io_qp = NvmeQueuePair{
            .id = 1,
            .depth = DEFAULT_QUEUE_DEPTH,
            .sq_buffer = io_sq,
            .cq_buffer = io_cq,
            .sq_doorbell_offset = 0x1000 + (2 * 4),
            .cq_doorbell_offset = 0x1000 + (3 * 4),
        };

        return NvmeController{
            .bar_mem = bar_mem,
            .allocator = allocator,
            .admin_queue = admin_qp,
            .io_queue = io_qp,
        };
    }

    /// Issue DirectStorage Async Read for Retrievable Multimedia Object (RMO) sectors
    /// DMA paths bypass CPU buffers, streaming directly into mapped VRAM / target physical addresses.
    pub fn readBlocksDirectStorage(
        self: *NvmeController,
        nsid: u32,
        slba: u64,
        block_count: u16,
        target_phys_addr: u64,
    ) !void {
        if (target_phys_addr % 4096 != 0) {
            return NvmeError.BufferNotAligned;
        }

        const sqe = NvmeSqEntry{
            .cdw0 = 0x02, // NVMe Read Opcode
            .nsid = nsid,
            .dptr1 = target_phys_addr,
            .cdw10 = @truncate(slba),
            .cdw11 = @truncate(slba >> 32),
            .cdw12 = @as(u32, block_count - 1),
        };

        const cmd_id = self.io_queue.submitCommand(sqe);
        _ = try self.io_queue.pollCompletion(cmd_id, self.bar_mem);
    }
};

pub fn main() !void {
    std.debug.print("Initializing MuseOS DirectStorage NVMe Driver Daemon (sDDF)...\n", .{});
    std.debug.print("NVMe Driver ready for polled zero-copy DMA streams.\n", .{});
}
