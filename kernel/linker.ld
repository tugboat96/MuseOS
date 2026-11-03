/*
 * MuseOS Kernel Linker Script (kernel/linker.ld)
 * Target: AMD64 (x86_64-unknown-none) Bare-Metal Multiboot / PVH Kernel
 */

ENTRY(_start)

PHDRS
{
    text PT_LOAD FILEHDR PHDRS FLAGS(7); /* Read, Write, Execute */
    note PT_NOTE FLAGS(4);               /* Read-only */
}

SECTIONS
{
    . = 1M;

    .text ALIGN(4K) : AT(ADDR(.text))
    {
        KEEP(*(.multiboot2))
        KEEP(*(.multiboot_header))
        *(.text .text.*)
    } :text

    .note.xen ALIGN(4) : AT(ADDR(.note.xen))
    {
        KEEP(*(.note.xen))
    } :text :note

    .rodata ALIGN(4K) : AT(ADDR(.rodata))
    {
        *(.rodata .rodata.*)
    } :text

    .data ALIGN(4K) : AT(ADDR(.data))
    {
        *(.data .data.*)
    } :text

    .bss ALIGN(4K) : AT(ADDR(.bss))
    {
        *(COMMON)
        *(.bss .bss.*)
    } :text

    /DISCARD/ :
    {
        *(.comment)
        *(.note.gnu.build-id)
    }
}
