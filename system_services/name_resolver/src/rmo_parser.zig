const std = @import("std");

/// Magic number identifier for Retrievable Multimedia Objects: "RMO_OS64" in ASCII (0x524D4F5F4F533634)
pub const RMO_MAGIC: u64 = 0x524D4F5F4F533634;

/// Supported media payload types for MuseOS Retrievable Multimedia Objects
pub const MediaType = enum(u32) {
    AudioStream = 0x01,
    VideoStream = 0x02,
    TextureMap = 0x03,
    VectorGraphic = 0x04,
    CompositeTimeline = 0x05,

    pub fn isValid(value: u32) bool {
        return value >= 0x01 and value <= 0x05;
    }
};

/// Bit flags specifying storage behavior and capability permissions for RMO payloads
pub const RmoFlags = struct {
    pub const DIRECT_STORAGE_ELIGIBLE: u32 = 1 << 0; // Can be DMA-streamed directly to GPU VRAM
    pub const COW_PINNED: u32 = 1 << 1; // Pinned in Copy-on-Write B-Tree leaf
    pub const ENCRYPTED: u32 = 1 << 2; // Hardware AES/ChaCha payload encryption
    pub const REALTIME_CLOCK_SYNC: u32 = 1 << 3; // Synchronized to audio sample clock domain
};

/// 64-bit aligned header structure matching raw CPU memory layout for zero-copy parsing
pub const RmoHeader = extern struct {
    magic: u64 = RMO_MAGIC,
    type: MediaType,
    flags: u32,
    content_hash: [32]u8,
    data_size: u64,
    sample_rate_or_fps: u32,
    channels_or_depth: u32,
    dimension_x: u32,
    dimension_y: u32,
};

/// Error set for Retrievable Multimedia Object parsing operations
pub const RmoParseError = error{
    InvalidMagic,
    UnsupportedMediaType,
    BufferTooSmall,
    MisalignedHeader,
    CorruptedPayloadSize,
};

/// Parses and validates a raw slice of memory into an RMO Header pointer
pub fn parseHeader(buffer: []const u8) RmoParseError!*const RmoHeader {
    if (buffer.len < @sizeOf(RmoHeader)) {
        return RmoParseError.BufferTooSmall;
    }

    if (@intFromPtr(buffer.ptr) % @alignOf(RmoHeader) != 0) {
        return RmoParseError.MisalignedHeader;
    }

    const header: *const RmoHeader = @ptrCast(@alignCast(buffer.ptr));

    if (header.magic != RMO_MAGIC) {
        return RmoParseError.InvalidMagic;
    }

    if (!MediaType.isValid(@intFromEnum(header.type))) {
        return RmoParseError.UnsupportedMediaType;
    }

    return header;
}

/// Validates structural integrity of an RmoHeader struct against container file bounds
pub fn validateHeader(header: *const RmoHeader, total_file_size: u64) RmoParseError!void {
    if (header.magic != RMO_MAGIC) {
        return RmoParseError.InvalidMagic;
    }

    if (total_file_size > 0 and (header.data_size + @sizeOf(RmoHeader) > total_file_size)) {
        return RmoParseError.CorruptedPayloadSize;
    }
}
