//! MuseOS Kernel Exception Dispatcher - kernel/src/interrupts/dispatcher.zig
//!
//! High-level 64-bit AMD64 interrupt and exception handling engine.
//! Receives pointer to CPU register context from the low-level assembly
//! stub in `idt.S`, handles hardware traps, page faults (#PF), divide errors (#DE),
//! general protection faults (#GP), and dispatches system calls (Vector 0x80).

const std = @import("std");

/// AMD64 Complete Register Context pushed by `common_isr_stub` in `idt.S`.
/// Matches the exact memory layout of stack pushes under System V AMD64 ABI.
pub const InterruptFrame = extern struct {
    // Saved General-Purpose Registers (Pushed in reverse order by common_isr_stub)
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    // Vector and Error Code (Pushed by ISR stub macro)
    vector_number: u64,
    error_code: u64,

    // Hardware-pushed stack frame by AMD64 CPU on interrupt entry
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Bit-flags representing the Page Fault (#PF) Error Code
pub const PageFaultFlags = packed struct(u32) {
    present: bool, // 0: Page not present, 1: Protection violation
    write: bool, // 0: Read access, 1: Write access
    user: bool, // 0: Kernel mode, 1: User mode (Ring 3)
    reserved_write: bool, // 1: Overwrote reserved bits in PTE
    instruction_fetch: bool, // 1: Fault occurred during instruction fetch (NX violation)
    pkru_violation: bool, // 1: Protection Key violation
    shadow_stack: bool, // 1: Shadow stack access fault
    _reserved: u25,
};

/// Exception Types Enum
pub const ExceptionType = enum(u8) {
    divide_error = 0,
    debug = 1,
    nmi = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range = 5,
    invalid_opcode = 6,
    device_not_available = 7,
    double_fault = 8,
    coprocessor_segment_overrun = 9,
    invalid_tss = 10,
    segment_not_present = 11,
    stack_segment_fault = 12,
    general_protection_fault = 13,
    page_fault = 14,
    x87_floating_point = 16,
    alignment_check = 17,
    machine_check = 18,
    simd_floating_point = 19,
    virtualization = 20,
    security_exception = 30,
    syscall_legacy = 0x80,
    _,
};

/// Main C-ABI Kernel Exception Dispatcher
/// Called directly from `common_isr_stub` in `kernel/asm/interrupts/idt.S`
export fn kernel_exception_dispatcher(frame: *InterruptFrame) callconv(.C) void {
    const vector: ExceptionType = @enumFromInt(@as(u8, @truncate(frame.vector_number)));

    switch (vector) {
        .page_fault => handlePageFault(frame),
        .general_protection_fault => handleGeneralProtectionFault(frame),
        .divide_error => handleDivideError(frame),
        .invalid_opcode => handleInvalidOpcode(frame),
        .double_fault => handleDoubleFault(frame),
        .syscall_legacy => handleSyscall(frame),
        else => {
            if (frame.vector_number >= 32 and frame.vector_number < 256) {
                handleHardwareIrq(frame);
            } else {
                handleUnhandledException(frame);
            }
        },
    }
}

/// Handles Page Fault (#PF - Vector 14) with Copy-on-Write (CoW) support
fn handlePageFault(frame: *InterruptFrame) void {
    // Read faulting linear memory address from CR2 register
    const fault_address: u64 = asm volatile (
        "mov %%cr2, %[addr]"
        : [addr] "=r" (-> u64),
    );

    const flags: PageFaultFlags = @bitCast(@as(u32, @truncate(frame.error_code)));

    // Log diagnostic fault details
    printSerial("[#PF Page Fault] Address: 0x{x:0>16} | RIP: 0x{x:0>16} | Present: {} | Write: {} | User: {}\n", .{
        fault_address,
        frame.rip,
        flags.present,
        flags.write,
        flags.user,
    });

    // Check for Copy-on-Write (CoW) fault (Protection violation on write to CoW-marked page)
    if (flags.present and flags.write) {
        if (attemptCowPageDuplication(fault_address)) {
            // CoW resolved: new physical frame allocated and PTE updated, return to execution
            return;
        }
    }

    // Unhandled page fault -> Halt process or trigger kernel panic
    kernelPanic("Unhandled Page Fault (#PF)", frame, fault_address);
}

/// Handles General Protection Fault (#GP - Vector 13)
fn handleGeneralProtectionFault(frame: *InterruptFrame) void {
    printSerial("[#GP General Protection Fault] Error Code: 0x{x} | Faulting RIP: 0x{x:0>16}\n", .{
        frame.error_code,
        frame.rip,
    });
    kernelPanic("General Protection Fault (#GP)", frame, 0);
}

/// Handles Divide-by-Zero (#DE - Vector 0)
fn handleDivideError(frame: *InterruptFrame) void {
    printSerial("[#DE Divide Error] Division by zero at RIP: 0x{x:0>16}\n", .{frame.rip});
    kernelPanic("Divide-by-Zero Exception (#DE)", frame, 0);
}

/// Handles Invalid Opcode (#UD - Vector 6)
fn handleInvalidOpcode(frame: *InterruptFrame) void {
    printSerial("[#UD Invalid Opcode] Execution of undefined instruction at RIP: 0x{x:0>16}\n", .{frame.rip});
    kernelPanic("Invalid Opcode (#UD)", frame, 0);
}

/// Handles Double Fault (#DF - Vector 8)
fn handleDoubleFault(frame: *InterruptFrame) void {
    printSerial("[#DF Double Fault] CRITICAL: Double fault trap triggered at RIP: 0x{x:0>16}\n", .{frame.rip});
    kernelPanic("Double Fault (#DF)", frame, 0);
}

/// Handles Unhandled Exceptions & Unregistered Traps
fn handleUnhandledException(frame: *InterruptFrame) void {
    printSerial("[EXCP] Unhandled Exception Vector: {} at RIP: 0x{x:0>16}\n", .{
        frame.vector_number,
        frame.rip,
    });
    kernelPanic("Unhandled Exception Trap", frame, frame.vector_number);
}

/// Handles Legacy Software System Calls (Vector 0x80)
fn handleSyscall(frame: *InterruptFrame) void {
    const syscall_nr = frame.rax;
    const arg0 = frame.rdi;
    const arg1 = frame.rsi;
    const arg2 = frame.rdx;

    printSerial("[SYSCALL] System call 0x{x} invoked (Arg0: 0x{x}, Arg1: 0x{x}, Arg2: 0x{x})\n", .{
        syscall_nr,
        arg0,
        arg1,
        arg2,
    });

    // Dummy return value: RAX = 0 (Success)
    frame.rax = 0;
}

/// Handles External Hardware IRQs (Vectors 32..255)
fn handleHardwareIrq(frame: *InterruptFrame) void {
    const irq_num = frame.vector_number - 32;
    printSerial("[IRQ] External Hardware Interrupt: IRQ {}\n", .{irq_num});
    // Send EOI (End of Interrupt) to APIC / PIC controller
    sendEndOfInterrupt(@as(u8, @truncate(irq_num)));
}

/// Copy-on-Write (CoW) page handler stub
fn attemptCowPageDuplication(virtual_address: u64) bool {
    _ = virtual_address;
    // Intersects with `kernel/asm/cow_allocator/block_scan.S` and `paging.zig`
    // Returns true if page frame was successfully duplicated
    return false;
}

/// Sends EOI to local APIC
fn sendEndOfInterrupt(irq: u8) void {
    _ = irq;
    // Write 0 to LAPIC EOI register (0xFEE000B0)
    const lapic_eoi_reg: *volatile u32 = @ptrFromInt(0xFEE000B0);
    lapic_eoi_reg.* = 0;
}

/// Formats and outputs diagnostic logs to UART serial port (0x3F8)
fn printSerial(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, fmt, args) catch "[PRINT_ERR]";
    for (formatted) |byte| {
        outb(0x3F8, byte);
    }
}

/// Outb port IO helper
fn outb(port: u16, data: u8) void {
    asm volatile (
        "outb %[data], %[port]"
        :
        : [data] "{al}" (data),
          [port] "{dx}" (port),
    );
}

/// Triggers Kernel Panic and halts execution
fn kernelPanic(message: []const u8, frame: *InterruptFrame, extra_info: u64) noreturn {
    printSerial("\n=======================================================\n", .{});
    printSerial("                  KERNEL PANIC                         \n", .{});
    printSerial("=======================================================\n", .{});
    printSerial("Reason: {s}\n", .{message});
    printSerial("Extra Info: 0x{x:0>16}\n", .{extra_info});
    printSerial("RIP: 0x{x:0>16} | CS: 0x{x} | RFLAGS: 0x{x}\n", .{ frame.rip, frame.cs, frame.rflags });
    printSerial("RSP: 0x{x:0>16} | SS: 0x{x} | Error Code: 0x{x}\n", .{ frame.rsp, frame.ss, frame.error_code });
    printSerial("RAX: 0x{x:0>16} | RBX: 0x{x:0>16}\n", .{ frame.rax, frame.rbx });
    printSerial("RCX: 0x{x:0>16} | RDX: 0x{x:0>16}\n", .{ frame.rcx, frame.rdx });
    printSerial("RSI: 0x{x:0>16} | RDI: 0x{x:0>16}\n", .{ frame.rsi, frame.rdi });
    printSerial("RBP: 0x{x:0>16} | R8:  0x{x:0>16}\n", .{ frame.rbp, frame.r8 });
    printSerial("=======================================================\n", .{});

    while (true) {
        asm volatile (
            "cli\n" ++
                "hlt\n"
        );
    }
}
