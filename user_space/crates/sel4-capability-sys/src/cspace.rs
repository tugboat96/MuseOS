//! seL4 CSpace (Capability Space) Manager for MuseOS
//!
//! Provides no_std Rust abstractions for managing seL4 CNode capability slots,
//! minting capabilities, copying capability tokens, and controlling task CSpaces.

#![no_std]

use crate::{SeL4Capability, SeL4Error};

/// Represents an seL4 Capability Node (CNode) depth and slot index.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CSpaceSlot {
    pub cnode_radix: u8,
    pub index: usize,
}

impl CSpaceSlot {
    pub const fn new(cnode_radix: u8, index: usize) -> Self {
        Self { cnode_radix, index }
    }
}

/// seL4 Capability Rights Bitflags
#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CapabilityRights(pub u8);

impl CapabilityRights {
    pub const NONE: Self = Self(0);
    pub const READ: Self = Self(1 << 0);
    pub const WRITE: Self = Self(1 << 1);
    pub const GRANT: Self = Self(1 << 2);
    pub const ALL: Self = Self(Self::READ.0 | Self::WRITE.0 | Self::GRANT.0);

    pub fn can_read(&self) -> bool {
        (self.0 & Self::READ.0) != 0
    }

    pub fn can_write(&self) -> bool {
        (self.0 & Self::WRITE.0) != 0
    }

    pub fn can_grant(&self) -> bool {
        (self.0 & Self::GRANT.0) != 0
    }
}

/// seL4 Capability Space (CSpace) Manager
#[derive(Debug)]
pub struct CSpaceManager {
    root_cnode: SeL4Capability,
    cnode_radix_bits: u8,
    next_free_slot: usize,
    capacity: usize,
}

impl CSpaceManager {
    /// Create a new CSpace manager wrapping a root CNode capability pointer.
    pub const fn new(root_cnode: SeL4Capability, cnode_radix_bits: u8) -> Self {
        let capacity = 1usize << cnode_radix_bits;
        Self {
            root_cnode,
            cnode_radix_bits,
            next_free_slot: 1, // Slot 0 typically reserved for Null cap
            capacity,
        }
    }

    /// Allocate the next available CSpace slot.
    pub fn allocate_slot(&mut self) -> Result<CSpaceSlot, SeL4Error> {
        if self.next_free_slot >= self.capacity {
            return Err(SeL4Error::NotEnoughMemory);
        }

        let slot = CSpaceSlot::new(self.cnode_radix_bits, self.next_free_slot);
        self.next_free_slot += 1;
        Ok(slot)
    }

    /// Copy a capability from a source slot into a destination slot with reduced or equal rights.
    pub fn copy_capability(
        &self,
        src_slot: CSpaceSlot,
        dest_slot: CSpaceSlot,
        rights: CapabilityRights,
    ) -> Result<SeL4Capability, SeL4Error> {
        if src_slot.index >= self.capacity || dest_slot.index >= self.capacity {
            return Err(SeL4Error::InvalidCapability);
        }

        // Inline assembly syscall stub for seL4 CNode Copy invocation
        let mut err: usize;
        unsafe {
            core::arch::asm!(
                "mov rax, 1",        // Syscall 1 = seL4_Call
                "mov rdi, {root}",   // Root CNode capability
                "mov rsi, {src}",    // Source slot
                "mov rdx, {dest}",   // Dest slot
                "mov r8, {rights}",  // Rights mask
                "syscall",
                root = in(reg) self.root_cnode.raw(),
                src = in(reg) src_slot.index,
                dest = in(reg) dest_slot.index,
                rights = in(reg) rights.0 as usize,
                out("rax") err,
                out("rcx") _,
                out("r11") _,
                clobber_mem,
            );
        }

        if err != 0 {
            return Err(SeL4Error::from_code(err));
        }

        Ok(SeL4Capability::new(dest_slot.index as u64))
    }

    /// Mint a capability token with badge data attached (used for IPC endpoint routing).
    pub fn mint_capability(
        &self,
        src_slot: CSpaceSlot,
        dest_slot: CSpaceSlot,
        rights: CapabilityRights,
        badge: u64,
    ) -> Result<SeL4Capability, SeL4Error> {
        if src_slot.index >= self.capacity || dest_slot.index >= self.capacity {
            return Err(SeL4Error::InvalidCapability);
        }

        let mut err: usize;
        unsafe {
            core::arch::asm!(
                "mov rax, 1",        // Syscall 1 = seL4_Call
                "mov rdi, {root}",   // Root CNode cap
                "mov rsi, {src}",    // Source slot
                "mov rdx, {dest}",   // Dest slot
                "mov r8, {rights}",  // Rights mask
                "mov r9, {badge}",   // Badge value
                "syscall",
                root = in(reg) self.root_cnode.raw(),
                src = in(reg) src_slot.index,
                dest = in(reg) dest_slot.index,
                rights = in(reg) rights.0 as usize,
                badge = in(reg) badge,
                out("rax") err,
                out("rcx") _,
                out("r11") _,
                clobber_mem,
            );
        }

        if err != 0 {
            return Err(SeL4Error::from_code(err));
        }

        Ok(SeL4Capability::new(dest_slot.index as u64))
    }

    /// Revoke all capabilities derived from the capability in the target slot.
    pub fn revoke(&self, target_slot: CSpaceSlot) -> Result<(), SeL4Error> {
        if target_slot.index >= self.capacity {
            return Err(SeL4Error::InvalidCapability);
        }

        let mut err: usize;
        unsafe {
            core::arch::asm!(
                "mov rax, 1",        // Syscall 1 = seL4_Call
                "mov rdi, {root}",   // Root CNode cap
                "mov rsi, {target}", // Target slot to revoke
                "mov rdx, 0x05",     // Invocation 5 = CNode Revoke
                "syscall",
                root = in(reg) self.root_cnode.raw(),
                target = in(reg) target_slot.index,
                out("rax") err,
                out("rcx") _,
                out("r11") _,
                clobber_mem,
            );
        }

        if err != 0 {
            return Err(SeL4Error::from_code(err));
        }

        Ok(())
    }
}
