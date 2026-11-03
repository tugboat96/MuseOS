// MuseOS AMD64 Memory Management & Paging Subsystem
// File: kernel/src/memory/paging.zig
// Freestanding Zig implementation of 4-level AMD64 Long Mode Paging (PML4, PDPT, PD, PT)

const std = @import("std");

/// Page table entry flags for AMD64 64-bit Long Mode
pub const PageFlags = packed struct(u64) {
    present: u1 = 1,
    writable: u1 = 1,
    user_accessible: u1 = 0,
    write_through: u1 = 0,
    cache_disable: u1 = 0,
    accessed: u1 = 0,
    dirty: u1 = 0,
    huge_page: u1 = 0, // 2MB page in PD, 1GB page in PDPT
    global: u1 = 0,
    available_low: u3 = 0,
    physical_frame: u40 = 0, // Frame physical address shifted right by 12 bits (bits 12..51)
    available_high: u11 = 0,
    no_execute: u1 = 0, // NX bit (Bit 63 in EFER.NXE)

    pub inline fn fromAddress(phys_addr: u64, flags: PageFlags) PageFlags {
        var entry = flags;
        entry.physical_frame = @truncate(phys_addr >> 12);
        return entry;
    }

    pub inline fn getAddress(self: PageFlags) u64 {
        return @as(u64, self.physical_frame) << 12;
    }
};

/// 4 KiB Page Table alignment structure (512 entries x 8 bytes = 4096 bytes)
pub const PageTable = struct {
    entries: [512]PageFlags align(4096),

    pub fn clear(self: *PageTable) void {
        @memset(std.mem.asBytes(&self.entries), 0);
    }
};

pub const PagingError = error{
    FrameAllocationFailed,
    PageAlreadyMapped,
    PageNotMapped,
    InvalidVirtualAddress,
    InvalidPhysicalAddress,
    MisalignedAddress,
};

/// 4-Level Paging System Manager (PML4 -> PDPT -> PD -> PT)
pub const PagingManager = struct {
    pml4: *PageTable,
    pml4_phys: u64,

    pub fn init(pml4_virt: *PageTable, pml4_phys: u64) PagingManager {
        return PagingManager{
            .pml4 = pml4_virt,
            .pml4_phys = pml4_phys,
        };
    }

    /// Activate this PML4 in the CPU by updating CR3
    pub fn activate(self: PagingManager) void {
        loadCr3(self.pml4_phys);
    }

    /// Map a 4 KiB virtual page to a physical frame
    pub fn mapPage(
        self: *PagingManager,
        virt: u64,
        phys: u64,
        flags: PageFlags,
        allocator_fn: *const fn () ?*PageTable,
    ) PagingError!void {
        if (virt % 4096 != 0) return PagingError.MisalignedAddress;
        if (phys % 4096 != 0) return PagingError.MisalignedAddress;

        const pml4_idx = (virt >> 39) & 0x1FF;
        const pdpt_idx = (virt >> 30) & 0x1FF;
        const pd_idx = (virt >> 21) & 0x1FF;
        const pt_idx = (virt >> 12) & 0x1FF;

        // PML4 -> PDPT
        const pdpt = try getOrCreateNextTable(&self.pml4.entries[pml4_idx], allocator_fn);
        // PDPT -> PD
        const pd = try getOrCreateNextTable(&pdpt.entries[pdpt_idx], allocator_fn);
        // PD -> PT
        const pt = try getOrCreateNextTable(&pd.entries[pd_idx], allocator_fn);

        if (pt.entries[pt_idx].present == 1) {
            return PagingError.PageAlreadyMapped;
        }

        var entry_flags = flags;
        entry_flags.present = 1;
        entry_flags.huge_page = 0;
        pt.entries[pt_idx] = PageFlags.fromAddress(phys, entry_flags);

        invalidatePage(virt);
    }

    /// Map a 2 MiB Huge Page into virtual address space
    pub fn map2MBHugePage(
        self: *PagingManager,
        virt: u64,
        phys: u64,
        flags: PageFlags,
        allocator_fn: *const fn () ?*PageTable,
    ) PagingError!void {
        if (virt % (2 * 1024 * 1024) != 0) return PagingError.MisalignedAddress;
        if (phys % (2 * 1024 * 1024) != 0) return PagingError.MisalignedAddress;

        const pml4_idx = (virt >> 39) & 0x1FF;
        const pdpt_idx = (virt >> 30) & 0x1FF;
        const pd_idx = (virt >> 21) & 0x1FF;

        const pdpt = try getOrCreateNextTable(&self.pml4.entries[pml4_idx], allocator_fn);
        const pd = try getOrCreateNextTable(&pdpt.entries[pdpt_idx], allocator_fn);

        if (pd.entries[pd_idx].present == 1) {
            return PagingError.PageAlreadyMapped;
        }

        var entry_flags = flags;
        entry_flags.present = 1;
        entry_flags.huge_page = 1; // Mark as 2MB Page in PD
        pd.entries[pd_idx] = PageFlags.fromAddress(phys, entry_flags);

        invalidatePage(virt);
    }

    /// Unmap a virtual page address
    pub fn unmapPage(self: *PagingManager, virt: u64) PagingError!void {
        if (virt % 4096 != 0) return PagingError.MisalignedAddress;

        const pml4_idx = (virt >> 39) & 0x1FF;
        const pdpt_idx = (virt >> 30) & 0x1FF;
        const pd_idx = (virt >> 21) & 0x1FF;
        const pt_idx = (virt >> 12) & 0x1FF;

        if (self.pml4.entries[pml4_idx].present == 0) return PagingError.PageNotMapped;
        const pdpt: *PageTable = @ptrFromInt(self.pml4.entries[pml4_idx].getAddress());

        if (pdpt.entries[pdpt_idx].present == 0) return PagingError.PageNotMapped;
        const pd: *PageTable = @ptrFromInt(pdpt.entries[pdpt_idx].getAddress());

        if (pd.entries[pd_idx].present == 0) return PagingError.PageNotMapped;

        // If it's a 2MB huge page, unmap at PD level
        if (pd.entries[pd_idx].huge_page == 1) {
            pd.entries[pd_idx].present = 0;
            invalidatePage(virt);
            return;
        }

        const pt: *PageTable = @ptrFromInt(pd.entries[pd_idx].getAddress());
        if (pt.entries[pt_idx].present == 0) return PagingError.PageNotMapped;

        pt.entries[pt_idx].present = 0;
        invalidatePage(virt);
    }

    /// Translate virtual address to physical address
    pub fn translateAddress(self: PagingManager, virt: u64) ?u64 {
        const pml4_idx = (virt >> 39) & 0x1FF;
        const pdpt_idx = (virt >> 30) & 0x1FF;
        const pd_idx = (virt >> 21) & 0x1FF;
        const pt_idx = (virt >> 12) & 0x1FF;
        const offset = virt & 0xFFF;

        if (self.pml4.entries[pml4_idx].present == 0) return null;
        const pdpt: *const PageTable = @ptrFromInt(self.pml4.entries[pml4_idx].getAddress());

        if (pdpt.entries[pdpt_idx].present == 0) return null;
        const pd: *const PageTable = @ptrFromInt(pdpt.entries[pdpt_idx].getAddress());

        if (pd.entries[pd_idx].present == 0) return null;

        if (pd.entries[pd_idx].huge_page == 1) {
            const huge_offset = virt & 0x1FFFFF; // 2MB offset
            return pd.entries[pd_idx].getAddress() + huge_offset;
        }

        const pt: *const PageTable = @ptrFromInt(pd.entries[pd_idx].getAddress());
        if (pt.entries[pt_idx].present == 0) return null;

        return pt.entries[pt_idx].getAddress() + offset;
    }
};

/// Helper to navigate/allocate lower-level page tables
fn getOrCreateNextTable(
    entry: *PageFlags,
    allocator_fn: *const fn () ?*PageTable,
) PagingError!*PageTable {
    if (entry.present == 1) {
        return @ptrFromInt(entry.getAddress());
    }

    const new_table = allocator_fn() orelse return PagingError.FrameAllocationFailed;
    new_table.clear();

    const phys_addr = @intFromPtr(new_table);
    entry.* = PageFlags.fromAddress(phys_addr, .{
        .present = 1,
        .writable = 1,
        .user_accessible = 1,
    });

    return new_table;
}

/// Load CR3 register with PML4 physical address
pub inline fn loadCr3(pml4_phys: u64) void {
    asm volatile (
        \\mov %[phys], %%cr3
        :
        : [phys] "r" (pml4_phys),
        : "memory"
    );
}

/// Read CR3 register
pub inline fn readCr3() u64 {
    return asm volatile (
        \\mov %%cr3, %[phys]
        : [phys] "=r" (-> u64),
    );
}

/// Flush TLB entry for a single virtual address via invlpg
pub inline fn invalidatePage(virt: u64) void {
    asm volatile (
        \\invlpg (%[addr])
        :
        : [addr] "r" (virt),
        : "memory"
    );
}
