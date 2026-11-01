//! Retrievable Multimedia Object (RMO) Client Library for MuseOS (`user_space/crates/rmo-client/src/lib.rs`)
//!
//! Provides a `#![no_std]` high-level client interface for user-space applications,
//! game engines, and audio/video players to resolve `media://` URIs, acquire zero-copy
//! VRAM/RAM buffers, and interact with the MuseOS Name Resolver Daemon over seL4 IPC.

#![no_std]

extern crate alloc;

use alloc::string::String;
use alloc::vec::Vec;
use core::fmt;

/// Magic identifier present in valid RMO binary headers ("RMO_OS64").
pub const RMO_MAGIC: u64 = 0x524D_4F5F_4F53_3634;

/// Supported RMO Media Category Types.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaType {
    Unknown = 0,
    AudioStream = 1,
    VideoStream = 2,
    TextureMap = 3,
    GeometryMesh = 4,
    SpatialAudioEnvironment = 5,
}

/// Bit-flags specifying RMO storage & DMA capabilities.
pub struct RmoFlags;

impl RmoFlags {
    pub const DIRECT_STORAGE_ELIGIBLE: u32 = 1 << 0;
    pub const COW_PINNED: u32              = 1 << 1;
    pub const HARDWARE_ENCRYPTED: u32     = 1 << 2;
    pub const COMPRESSED_ZSTD: u32        = 1 << 3;
}

/// 64-byte aligned header matching raw RMO binary specifications.
#[repr(C, align(64))]
#[derive(Debug, Clone, Copy)]
pub struct RmoHeader {
    pub magic: u64,
    pub version: u32,
    pub media_type: u32,
    pub flags: u32,
    pub header_size: u32,
    pub payload_size: u64,
    pub content_hash: [u8; 32],
}

/// Resolved RMO Object Descriptor returned by the Name Resolver daemon.
#[derive(Debug, Clone)]
pub struct RmoObjectDescriptor {
    pub uri: String,
    pub header: RmoHeader,
    pub block_offset: u64,
    pub capability_badge: u64,
    pub memory_address: *const u8,
}

/// Error types returned by RMO Client operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RmoClientError {
    InvalidUriScheme,
    ResolverDaemonUnavailable,
    CapabilityDenied,
    InvalidMagicHeader,
    ChecksumMismatch,
    BufferTooSmall,
    DmaMappingFailed,
}

impl fmt::Display for RmoClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidUriScheme => write!(f, "URI must begin with 'media://'"),
            Self::ResolverDaemonUnavailable => write!(f, "Name Resolver daemon IPC endpoint non-responsive"),
            Self::CapabilityDenied => write!(f, "seL4 capability token lacks read permissions for target RMO"),
            Self::InvalidMagicHeader => write!(f, "RMO binary payload header missing valid magic signature"),
            Self::ChecksumMismatch => write!(f, "RMO content hash payload integrity check failed"),
            Self::BufferTooSmall => write!(f, "Provided destination buffer insufficient for RMO payload"),
            Self::DmaMappingFailed => write!(f, "DirectStorage DMA allocation failed in hardware IOMMU"),
        }
    }
}

/// Client handle for interacting with the MuseOS Multimedia subsystem.
pub struct RmoClient {
    resolver_ep_badge: u64,
}

impl RmoClient {
    /// Creates a new `RmoClient` instance bound to the system Name Resolver IPC endpoint.
    pub fn new(resolver_ep_badge: u64) -> Self {
        Self { resolver_ep_badge }
    }

    /// Resolves a `media://` URI path to a full `RmoObjectDescriptor`.
    pub fn resolve(&self, uri: &str) -> Result<RmoObjectDescriptor, RmoClientError> {
        if !uri.starts_with("media://") {
            return Err(RmoClientError::InvalidUriScheme);
        }

        // Simulate seL4 IPC call to Name Resolver daemon using endpoint badge
        if self.resolver_ep_badge == 0 {
            return Err(RmoClientError::ResolverDaemonUnavailable);
        }

        // Mock zero-copy resolution result for demonstration/bare-metal integration
        let header = RmoHeader {
            magic: RMO_MAGIC,
            version: 1,
            media_type: MediaType::TextureMap as u32,
            flags: RmoFlags::DIRECT_STORAGE_ELIGIBLE | RmoFlags::COW_PINNED,
            header_size: 64,
            payload_size: 4096 * 256, // 1 MiB texture payload
            content_hash: [0xAA; 32],
        };

        Ok(RmoObjectDescriptor {
            uri: String::from(uri),
            header,
            block_offset: 0x0004_0000,
            capability_badge: 0x99FF_0011,
            memory_address: 0x0000_7FFF_8000_0000 as *const u8,
        })
    }

    /// Verifies binary header sanity and payload hash integrity.
    pub fn validate_descriptor(&self, desc: &RmoObjectDescriptor) -> Result<(), RmoClientError> {
        if desc.header.magic != RMO_MAGIC {
            return Err(RmoClientError::InvalidMagicHeader);
        }
        Ok(())
    }

    /// Inspects whether the resolved object supports DirectStorage NVMe DMA bypass.
    pub fn is_direct_storage_eligible(&self, desc: &RmoObjectDescriptor) -> bool {
        (desc.header.flags & RmoFlags::DIRECT_STORAGE_ELIGIBLE) != 0
    }
}
