//! MuseOS - AMD64 DirectStorage Memory Mapping Subsystem
//! Kernel Path: kernel/src/memory/direct_storage.zig
//!
//! Provides bare-metal memory structures and physical mapping routines
//! for zero-copy DirectStorage DMA bypass between PCIe NVMe controllers,
//! host RAM page lists, and GPU VRAM allocations.

const std = @import("std");

/// Alignment requirements for DirectStorage DMA structures
pub const DS_DESCRIPTOR_ALIGNMENT: usize = 64; // Cache-line aligned
pub const DS_PAGE_ALIGNMENT: usize = 4096; // 4 KiB standard page alignment
pub const DS_HUGE_PAGE_ALIGNMENT: usize = 2 * 1024 * 1024; // 2 MiB huge page alignment

/// DirectStorage Transfer Direction
pub const DirectStorageDirection = enum(u2) {
    DeviceToHost = 0,
    HostToDevice = 1,
    DeviceToDeviceVram = 2, // Direct NVMe to GPU VRAM bypass
};

/// DirectStorage Memory Target Type
pub const DirectStorageTargetType = enum(u4) {
    HostPhysicalMemory = 0x1,
    GpuVramMapped = 0x2,
    SharedCowBuffer = 0x3,
    IommuProtectedRegion = 0x4,
};

/// Transfer Status Flags
pub const TransferFlags = packed struct(u16) {
    is_completed: bool = false,
    has_error: bool = false,
    use_iommu: bool = true,
    bypass_cpu_cache: bool = true,
    reserved: u12 = 0,
};

/// Hardware DMA Range Descriptor (64-byte aligned for AMD64 cache lines)
pub const DirectStorageDescriptor = extern struct {
    /// Physical source address (e.g. NVMe controller LBA sector byte offset / PRPs)
    source_phys_addr: u64 align(DS_DESCRIPTOR_ALIGNMENT),
    /// Physical target memory address (System RAM physical addr or PCIe BAR VRAM addr)
    target_phys_addr: u64,
    /// Total transfer length in bytes (must be 512-byte sector aligned)
    transfer_bytes: u64,
    /// DirectStorage transfer direction
    direction: DirectStorageDirection,
    /// Target buffer memory classification
    target_type: DirectStorageTargetType,
    /// Transfer control flags
    flags: TransferFlags,
    /// IOMMU Domain ID for hardware DMA mapping verification
    iommu_domain_id: u16,
    /// Associated RMO 64-bit Object ID hash
    rmo_object_id: u64,
    /// Reserved padding for strict 64-byte structure size matching x86_64 cache line
    reserved_padding: [16]u8 = [_]u8{0} ** 16,
};

/// DirectStorage Memory Region Header
pub const DirectStorageMemoryHeader = extern struct {
    magic: u64 = 0x44535F4D454D5F3644, // "DS_MEM_6D" magic identifier
    region_version: u32 = 1,
    total_pages: u32,
    base_phys_addr: u64,
    region_size_bytes: u64,
    active_descriptors_count: u32,
    max_descriptors_capacity: u32,

    pub fn validate(self: *const DirectStorageMemoryHeader) bool {
        if (self.magic != 0x44535F4D454D5F3644) return false;
        if (self.region_size_bytes == 0) return false;
        if (!std.mem.isAligned(self.base_phys_addr, DS_PAGE_ALIGNMENT)) return false;
        return true;
    }
};

/// Errors associated with DirectStorage Memory Mapping
pub const DirectStorageError = error{
    InvalidMagic,
    MisalignedPhysicalAddress,
    MisalignedTransferSize,
    DescriptorBufferOverflow,
    IommuDomainMismatch,
    VramRangeOutOfMemory,
};

/// DirectStorage Memory Region Manager
pub const DirectStorageMapManager = struct {
    header: DirectStorageMemoryHeader,
    descriptors: []DirectStorageDescriptor,

    pub fn init(
        base_phys_addr: u64,
        size_bytes: u64,
        descriptor_buffer: []DirectStorageDescriptor,
    ) DirectStorageError!DirectStorageMapManager {
        if (!std.mem.isAligned(base_phys_addr, DS_PAGE_ALIGNMENT)) {
            return DirectStorageError.MisalignedPhysicalAddress;
        }

        const pages = @as(u32, @intCast(size_bytes / DS_PAGE_ALIGNMENT));

        const header = DirectStorageMemoryHeader{
            .total_pages = pages,
            .base_phys_addr = base_phys_addr,
            .region_size_bytes = size_bytes,
            .active_descriptors_count = 0,
            .max_descriptors_capacity = @as(u32, @intCast(descriptor_buffer.len)),
        };

        return DirectStorageMapManager{
            .header = header,
            .descriptors = descriptor_buffer,
        };
    }

    /// Register a direct DMA range mapping into the DirectStorage memory map
    pub fn createDmaMapping(
        self: *DirectStorageMapManager,
        source_phys: u64,
        target_phys: u64,
        bytes: u64,
        direction: DirectStorageDirection,
        target_type: DirectStorageTargetType,
        iommu_domain: u16,
        rmo_id: u64,
    ) DirectStorageError!*DirectStorageDescriptor {
        if (self.header.active_descriptors_count >= self.header.max_descriptors_capacity) {
            return DirectStorageError.DescriptorBufferOverflow;
        }

        if (bytes % 512 != 0) {
            return DirectStorageError.MisalignedTransferSize;
        }

        const idx = self.header.active_descriptors_count;
        self.descriptors[idx] = DirectStorageDescriptor{
            .source_phys_addr = source_phys,
            .target_phys_addr = target_phys,
            .transfer_bytes = bytes,
            .direction = direction,
            .target_type = target_type,
            .flags = TransferFlags{},
            .iommu_domain_id = iommu_domain,
            .rmo_object_id = rmo_id,
            .reserved_padding = [_]u8{0} ** 16,
        };

        self.header.active_descriptors_count += 1;
        return &self.descriptors[idx];
    }
};
