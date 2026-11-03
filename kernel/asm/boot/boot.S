/*
 * MuseOS AMD64 Bootloader - kernel/asm/boot/boot.S
 * 
 * Multiboot1, Multiboot2, and Xen PVH compliant headers and 64-bit Long Mode entry transition.
 */

.set MULTIBOOT1_HEADER_MAGIC, 0x1badb002
.set MULTIBOOT1_HEADER_FLAGS, 0x00000003
.set MULTIBOOT1_CHECKSUM, -(MULTIBOOT1_HEADER_MAGIC + MULTIBOOT1_HEADER_FLAGS)

.set MULTIBOOT2_HEADER_MAGIC, 0xe85250d6
.set MULTIBOOT_ARCHITECTURE_I386, 0

/* Xen PVH ELF Note Entry for QEMU x86_64 Direct Kernel Loading */
.section .note.xen, "a", @note
.align 4
pvh_note_start:
    .long 4                                 /* namesz = 4 ("Xen\0") */
    .long 4                                 /* descsz = 4 (32-bit addr) */
    .long 18                                /* type = XEN_ELFNOTE_PHYS32_ENTRY (18) */
    .asciz "Xen"                            /* name = "Xen\0" */
    .long _start                            /* desc = 32-bit entry point */
pvh_note_end:

/* Multiboot 1 Header */
.section .multiboot_header, "a"
.align 4
multiboot1_header:
    .long MULTIBOOT1_HEADER_MAGIC
    .long MULTIBOOT1_HEADER_FLAGS
    .long MULTIBOOT1_CHECKSUM

/* Multiboot 2 Header */
.section .multiboot2, "a"
.align 8
multiboot2_header:
    .long MULTIBOOT2_HEADER_MAGIC
    .long MULTIBOOT_ARCHITECTURE_I386
    .long 24
    .long (0x100000000 - (MULTIBOOT2_HEADER_MAGIC + MULTIBOOT_ARCHITECTURE_I386 + 24))

    /* End tag */
    .short 0    /* type */
    .short 0    /* flags */
    .long 8     /* size */
multiboot2_header_end:

/* Initial Early Stack Allocation (16 KiB) */
.section .bss
.align 16
stack_bottom:
    .skip 16384
stack_top:

/* 4-Level Page Tables for 64-bit Identity Mapping */
.align 4096
pml4_table:
    .skip 4096
pdpt_table:
    .skip 4096
pd_table:
    .skip 4096

/* Global Descriptor Table (GDT) for 64-bit Mode */
.section .rodata
.align 8
gdt64:
    .quad 0 # Null Descriptor
gdt64_code:
    /* 64-bit Code Segment: Executable, Conforming=0, Readable, Long-mode=1, Present=1 */
    .quad (1 << 43) | (1 << 44) | (1 << 47) | (1 << 53)
gdt64_data:
    /* 64-bit Data Segment: Writable, Present=1 */
    .quad (1 << 41) | (1 << 44) | (1 << 47)
gdt64_end:

gdt64_pointer:
    .word gdt64_end - gdt64 - 1
    .quad gdt64

/* Boot Code Entry Point (32-bit Protected Mode initially) */
.section .text
.code32
.global _start
.type _start, @function
_start:
    /* Initialize Stack Pointer */
    mov $stack_top, %esp

    /* Save Multiboot info pointer and magic */
    mov %ebx, %edi    /* Multiboot info address -> EDI */
    mov %eax, %esi    /* Multiboot magic -> ESI */

    /* Verify CPU supports CPUID and Long Mode */
    call check_cpuid
    call check_long_mode

    /* Build 4-Level Page Tables (Identity Map first 1 GiB using 2MB pages) */
    call setup_page_tables

    /* Enable PAE (Physical Address Extension) in CR4 */
    mov %cr4, %eax
    or $(1 << 5), %eax    /* Set PAE bit */
    mov %eax, %cr4

    /* Load PML4 physical address into CR3 */
    mov $pml4_table, %eax
    mov %eax, %cr3

    /* Enable Long Mode in IA32_EFER MSR (0xC0000080) */
    mov $0xC0000080, %ecx
    rdmsr
    or $(1 << 8), %eax    /* Set LME bit */
    wrmsr

    /* Enable Paging and Protected Mode in CR0 */
    mov %cr0, %eax
    or $(1 << 31) | (1 << 0), %eax    /* Set PG and PE bits */
    mov %eax, %cr0

    /* Load 64-bit Global Descriptor Table */
    lgdt gdt64_pointer

    /* Far jump to 64-bit code segment */
    ljmp $0x08, $long_mode_entry

/* CPU Checks */
check_cpuid:
    pushfl
    pop %eax
    mov %eax, %ecx
    xor $(1 << 21), %eax
    push %eax
    popfl
    pushfl
    pop %eax
    push %ecx
    popfl
    cmp %ecx, %eax
    je .no_cpuid
    ret
.no_cpuid:
    mov $0xDEAD0001, %eax
    hlt

check_long_mode:
    mov $0x80000000, %eax
    cpuid
    cmp $0x80000001, %eax
    jb .no_long_mode
    mov $0x80000001, %eax
    cpuid
    test $(1 << 29), %edx
    jz .no_long_mode
    ret
.no_long_mode:
    mov $0xDEAD0002, %eax
    hlt

/* Setup Identity Page Tables */
setup_page_tables:
    /* Map PML4[0] -> pdpt_table */
    mov $pdpt_table, %eax
    or $0b11, %eax        /* Present + Writable */
    mov %eax, pml4_table

    /* Map PDPT[0] -> pd_table */
    mov $pd_table, %eax
    or $0b11, %eax        /* Present + Writable */
    mov %eax, pdpt_table

    /* Identity map 512 entries of 2MB pages (1 GiB total) */
    mov $0, %ecx
.map_pd_loop:
    mov $0x200000, %eax   /* 2MB */
    mul %ecx
    or $0b10000011, %eax  /* Present + Writable + Page Size (2MB) */
    mov %eax, pd_table(, %ecx, 8)
    inc %ecx
    cmp $512, %ecx
    jne .map_pd_loop
    ret

/* 64-bit Long Mode Code Entry */
.code64
long_mode_entry:
    /* Reload segment registers with 0 / data selector */
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    /* Move Multiboot arguments into System V AMD64 ABI calling registers */
    mov %edi, %edi       /* Zero-extend Multiboot info pointer to RDI */
    mov %esi, %esi       /* Zero-extend Multiboot magic to RSI */

    /* Jump to high-level seL4 / MuseOS C/Zig kernel entry */
    call kernel_main

    /* Fallback halt loop */
.hlt_loop:
    cli
    hlt
    jmp .hlt_loop
