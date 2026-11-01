/*
 * MuseOS AMD64 Interrupt Descriptor Table (IDT) & Trap Handler
 * File: kernel/asm/interrupts/idt.S
 * Target: x86_64-unknown-none (64-bit Long Mode)
 */

.code64
.section .text

/* Global symbols exported to C / Zig / Rust kernel code */
.global idt_init
.global idt_load
.global default_trap_handler

/* External kernel exception dispatcher written in Zig/C/Rust */
.extern kernel_exception_dispatcher

/*
 * IDT Entry Gate Types & Attributes (AMD64 System Descriptor)
 * 0x8E = Present, Ring 0, 64-bit Interrupt Gate (Interrupts Disabled)
 * 0x8F = Present, Ring 0, 64-bit Trap Gate (Interrupts Enabled)
 * 0xEE = Present, Ring 3, 64-bit User Interrupt Gate
 */
.equ IDT_ATTR_INT_GATE,   0x8E
.equ IDT_ATTR_TRAP_GATE,  0x8F
.equ IDT_ATTR_USER_GATE,  0xEE
.equ KERNEL_CS,           0x08

/*
 * Macro to declare Exception Handlers without Error Code
 */
.macro ISR_NO_ERRCODE num
.global isr_\num
isr_\num:
    pushq $0                  /* Push dummy error code */
    pushq $\num               /* Push vector number */
    jmp common_isr_stub
.endm

/*
 * Macro to declare Exception Handlers with CPU-pushed Error Code
 */
.macro ISR_ERRCODE num
.global isr_\num
isr_\num:
    pushq $\num               /* Push vector number (error code already on stack) */
    jmp common_isr_stub
.endm

/* Define Vector Stub Handlers (0 .. 31) */
ISR_NO_ERRCODE 0   /* Divide-by-Zero Exception */
ISR_NO_ERRCODE 1   /* Debug Exception */
ISR_NO_ERRCODE 2   /* Non-Maskable Interrupt (NMI) */
ISR_NO_ERRCODE 3   /* Breakpoint Exception */
ISR_NO_ERRCODE 4   /* Overflow Exception */
ISR_NO_ERRCODE 5   /* BOUND Range Exceeded */
ISR_NO_ERRCODE 6   /* Invalid Opcode Exception */
ISR_NO_ERRCODE 7   /* Device Not Available (No Math Coprocessor) */
ISR_ERRCODE    8   /* Double Fault Exception */
ISR_NO_ERRCODE 9   /* Coprocessor Segment Overrun */
ISR_ERRCODE    10  /* Invalid TSS Exception */
ISR_ERRCODE    11  /* Segment Not Present */
ISR_ERRCODE    12  /* Stack Fault Exception */
ISR_ERRCODE    13  /* General Protection Fault (GPF) */
ISR_ERRCODE    14  /* Page Fault Exception */
ISR_NO_ERRCODE 15  /* Reserved Exception */
ISR_NO_ERRCODE 16  /* x87 Floating-Point Error */
ISR_ERRCODE    17  /* Alignment Check Exception */
ISR_NO_ERRCODE 18  /* Machine Check Exception */
ISR_NO_ERRCODE 19  /* SIMD Floating-Point Exception */
ISR_NO_ERRCODE 20  /* Virtualization Exception */
ISR_ERRCODE    21  /* Control Protection Exception */
ISR_NO_ERRCODE 22  /* Reserved */
ISR_NO_ERRCODE 23  /* Reserved */
ISR_NO_ERRCODE 24  /* Reserved */
ISR_NO_ERRCODE 25  /* Reserved */
ISR_NO_ERRCODE 26  /* Reserved */
ISR_NO_ERRCODE 27  /* Reserved */
ISR_NO_ERRCODE 28  /* Hypervisor Injection Exception */
ISR_ERRCODE    29  /* VMM Communication Exception */
ISR_ERRCODE    30  /* Security Exception */
ISR_NO_ERRCODE 31  /* Reserved */

/* System Call Entry Gate (Vector 0x80) */
ISR_NO_ERRCODE 128 /* 0x80 System Call Vector */

/*
 * Common ISR Stub: Saves CPU Register State, sets up C ABI frame,
 * calls kernel_exception_dispatcher, restores state, and performs iretq.
 */
common_isr_stub:
    /* Save General Purpose Registers (GPRs) */
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    /* System V AMD64 ABI: Pass pointer to stack frame as RDI */
    movq %rsp, %rdi
    call kernel_exception_dispatcher

    /* Restore General Purpose Registers */
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    /* Clean up vector number and error code from stack */
    addq $16, %rsp

    /* Return from Interrupt (64-bit Long Mode) */
    iretq

/*
 * Function: idt_load
 * Prototype: void idt_load(const void* idt_ptr);
 * RDI: Address of 10-byte IDTR structure
 */
idt_load:
    lidt (%rdi)
    retq

/*
 * IDT Table & Descriptor Layout in BSS/Data Section
 */
.section .bss
.align 16
.global idt_table
idt_table:
    .skip 4096            /* 256 entries * 16 bytes per entry = 4096 bytes */

.section .data
.align 16
.global idt_descriptor
idt_descriptor:
    .word 4095            /* Limit: 256 entries * 16 - 1 */
    .quad idt_table       /* Base Address of IDT */
