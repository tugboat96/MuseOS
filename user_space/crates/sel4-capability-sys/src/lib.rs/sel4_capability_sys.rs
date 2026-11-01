//! # seL4 Capability System Bindings (`sel4-capability-sys`)
//!
//! Low-level `#![no_std]` Rust capability management bindings and syscall wrappers
//! for user-space processes running on the seL4 microkernel in MuseOS.

#![no_std]
#![deny(missing_docs)]
#![deny(unsafe_op_in_unsafe_fn)]

use core::arch::asm;

/// Capability reference index type in the seL4 CSpace.
pub type SeL4CPtr = usize;

/// Word-sized data payload for IPC registers.
pub type SeL4Word = usize;

/// Process identifier / Capability Node slot offset.
pub type SeL4Slot = usize;

/// Standard seL4 IPC Message Info Register Layout.
/// Encodes length, extra caps, caps unwrapped, and label bits.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SeL4MessageInfo {
    words: SeL4Word,
}

impl SeL4MessageInfo {
    /// Creates a new `SeL4MessageInfo` struct with label, caps, and length parameters.
    #[inline]
    pub const fn new(label: SeL4Word, caps_unwrapped: SeL4Word, extra_caps: SeL4Word, length: SeL4Word) -> Self {
        let words = (label << 12)
            | ((caps_unwrapped & 0x7) << 9)
            | ((extra_caps & 0x3) << 7)
            | (length & 0x7F);
        Self { words }
    }

    /// Returns the length of the message payload in words.
    #[inline]
    pub const fn length(&self) -> SeL4Word {
        self.words & 0x7F
    }

    /// Returns the label contained in the message info.
    #[inline]
    pub const fn label(&self) -> SeL4Word {
        self.words >> 12
    }
}

/// Capability invocation error codes returned by seL4 syscalls.
#[repr(usize)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeL4Error {
    /// The invocation succeeded without error.
    NoError = 0,
    /// An invalid capability index was provided.
    InvalidCapability = 1,
    /// The capability lacks sufficient permissions for the operation.
    PermissionDenied = 2,
    /// The destination capability slot was invalid or occupied.
    InvalidArgument = 3,
    /// Failed to retype untyped memory into target capability.
    TruncatedMessage = 4,
    /// Memory allocation or CNode table overflow.
    CNodeFull = 5,
    /// Execution alignment error or unaligned address.
    AlignmentError = 6,
    /// Failed to resolve target capability path.
    FailedLookup = 7,
    /// Illegal operation on target kernel object.
    IllegalOperation = 8,
    /// Unknown or unspecified kernel fault.
    UnknownError = 0xFF,
}

impl SeL4Error {
    /// Converts a raw system call return register value into a typed `SeL4Error`.
    #[inline]
    pub const fn from_raw(val: usize) -> Self {
        match val {
            0 => Self::NoError,
            1 => Self::InvalidCapability,
            2 => Self::PermissionDenied,
            3 => Self::InvalidArgument,
            4 => Self::TruncatedMessage,
            5 => Self::CNodeFull,
            6 => Self::AlignmentError,
            7 => Self::FailedLookup,
            8 => Self::IllegalOperation,
            _ => Self::UnknownError,
        }
    }
}

/// seL4 System Call Numbers for AMD64 x86_64 architecture.
#[repr(isize)]
#[derive(Debug, Clone, Copy)]
pub enum SyscallNumber {
    /// Blocking Call: Send message and await reply.
    Call = -1,
    /// Reply and Wait: Send reply capability and block on endpoint.
    ReplyWait = -2,
    /// Non-blocking send syscall.
    Send = -3,
    /// Non-blocking receive syscall.
    NBSend = -4,
    /// Blocking wait / receive on endpoint or notification object.
    Wait = -5,
    /// Non-blocking poll on notification object.
    Poll = -6,
    /// Yield execution slice to scheduler.
    Yield = -7,
}

/// Direct System V AMD64 assembly wrapper for `seL4_Call`.
///
/// Invokes a capability endpoint with a request message and blocks waiting for a kernel reply.
///
/// # Safety
///
/// This call executes an inline `syscall` instruction that modifies architectural CPU registers (`RAX`, `RDI`, `RSI`, `RDX`, `R10`, `R8`, `R9`).
/// The caller must ensure `dest` refers to a valid seL4 capability pointer.
#[inline]
pub unsafe fn sel4_call(dest: SeL4CPtr, msg_info: SeL4MessageInfo) -> (SeL4MessageInfo, SeL4Error) {
    let mut info_out: usize;
    let mut err_out: usize;

    // Direct AMD64 syscall execution using SYSENTER/SYSCALL register layout for seL4 kernel
    unsafe {
        asm!(
            "syscall",
            inout("rax") SyscallNumber::Call as isize => err_out,
            inout("rdi") dest => _,
            inout("rsi") msg_info.words => info_out,
            out("rcx") _,
            out("r11") _,
            options(nostack)
        );
    }

    (
        SeL4MessageInfo { words: info_out },
        SeL4Error::from_raw(err_out),
    )
}

/// Direct System V AMD64 assembly wrapper for `seL4_Send`.
///
/// Sends an asynchronous or synchronous message without blocking for a response.
///
/// # Safety
///
/// Executes bare-metal `syscall`. `dest` must be a valid CSpace capability slot.
#[inline]
pub unsafe fn sel4_send(dest: SeL4CPtr, msg_info: SeL4MessageInfo) {
    unsafe {
        asm!(
            "syscall",
            in("rax") SyscallNumber::Send as isize,
            in("rdi") dest,
            in("rsi") msg_info.words,
            out("rcx") _,
            out("r11") _,
            options(nostack)
        );
    }
}

/// Direct System V AMD64 assembly wrapper for `seL4_Yield`.
///
/// Relinquishes the current thread's remaining CPU time quantum.
#[inline]
pub fn sel4_yield() {
    unsafe {
        asm!(
            "syscall",
            in("rax") SyscallNumber::Yield as isize,
            out("rcx") _,
            out("r11") _,
            options(nomem, nostack)
        );
    }
}

/// High-level typed Capability Wrapper.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SeL4Capability {
    cptr: SeL4CPtr,
}

impl SeL4Capability {
    /// Instantiates a capability handle around a raw CSpace slot index.
    #[inline]
    pub const fn from_cptr(cptr: SeL4CPtr) -> Self {
        Self { cptr }
    }

    /// Obtains the underlying raw slot index.
    #[inline]
    pub const fn cptr(&self) -> SeL4CPtr {
        self.cptr
    }

    /// Invokes a synchronous call on this capability.
    #[inline]
    pub fn call(&self, info: SeL4MessageInfo) -> Result<SeL4MessageInfo, SeL4Error> {
        let (reply_info, err) = unsafe { sel4_call(self.cptr, info) };
        if err == SeL4Error::NoError {
            Ok(reply_info)
        } else {
            Err(err)
        }
    }

    /// Performs an asynchronous send on this capability endpoint.
    #[inline]
    pub fn send(&self, info: SeL4MessageInfo) {
        unsafe { sel4_send(self.cptr, info) };
    }
}
