// system_services/fs_cow/src/asm_bindings.zig
// Zig FFI bindings to kernel/asm/cow_allocator/block_scan.S for MuseOS

const std = @import("std");

/// Errors returned by the CoW Block Allocator assembly wrapper
pub const AllocatorError = error{
    NoFreeBlocks,
    InsufficientContiguousBlocks,
    InvalidBlockIndex,
    NullBitmapPointer,
};

// C ABI extern declarations matching kernel/asm/cow_allocator/block_scan.S
extern fn cow_find_free_block(bitmap_ptr: [*]const u64, total_words: usize) callconv(.C) u64;
extern fn cow_scan_contiguous_blocks(bitmap_ptr: [*]const u64, total_words: usize, required_blocks: usize) callconv(.C) u64;
extern fn cow_mark_block_allocated(bitmap_ptr: [*]u64, block_index: u64) callconv(.C) void;

pub const BlockScanSentinel: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// Safe Zig wrapper around `cow_find_free_block` assembly routine.
/// Scans the allocation bitmap using AMD64 `tzcnt` instruction.
pub fn findFreeBlock(bitmap: []const u64) AllocatorError!u64 {
    if (bitmap.len == 0) return AllocatorError.NullBitmapPointer;
    
    const result = cow_find_free_block(bitmap.ptr, bitmap.len);
    if (result == BlockScanSentinel) {
        return AllocatorError.NoFreeBlocks;
    }
    return result;
}

/// Safe Zig wrapper around `cow_scan_contiguous_blocks` assembly routine.
/// Locates a contiguous sequence of free blocks required for DirectStorage DMA buffers.
pub fn scanContiguousBlocks(bitmap: []const u64, required_blocks: usize) AllocatorError!u64 {
    if (bitmap.len == 0) return AllocatorError.NullBitmapPointer;
    if (required_blocks == 0) return 0;
    
    const result = cow_scan_contiguous_blocks(bitmap.ptr, bitmap.len, required_blocks);
    if (result == BlockScanSentinel) {
        return AllocatorError.InsufficientContiguousBlocks;
    }
    return result;
}

/// Safe Zig wrapper around `cow_mark_block_allocated` assembly routine.
/// Sets/resets bit flags in the sector allocation bitmap using `btr`.
pub fn markBlockAllocated(bitmap: []u64, block_index: u64) AllocatorError!void {
    if (bitmap.len == 0) return AllocatorError.NullBitmapPointer;
    const total_bits = bitmap.len * 64;
    if (block_index >= total_bits) {
        return AllocatorError.InvalidBlockIndex;
    }
    
    cow_mark_block_allocated(bitmap.ptr, block_index);
}
