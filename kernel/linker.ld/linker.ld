/*
 * MuseOS Kernel Linker Script (kernel/linker.ld)
 * Targets: AMD64 (x86_64-unknown-none) Bare-Metal Multiboot2 Kernel
 */

ENTRY(_start)

SECTIONS
{
    /* Multiboot2 header must be placed within the first 32 KiB of the ELF image */
    . = 1M;

    /* Text section: Multiboot header and kernel code */
    .text ALIGN(4K) :
    {
        KEEP(*(.multiboot_header))
        *(.text .text.*)
    }

    /* Read-only data section */
    .rodata ALIGN(4K) :
    {
        *(.rodata .rodata.*)
    }

    /* Read-write initialized data section */
    .data ALIGN(4K) :
    {
        *(.data .data.*)
    }

    /* Read-write uninitialized data section (BSS) and stack space */
    .bss ALIGN(4K) :
    {
        *(COMMON)
        *(.bss .bss.*)
    }

    /* Exclude debugging comments/notes from final runtime binary layout */
    /DISCARD/ :
    {
        *(.comment)
        *(.note.gnu.build-id)
    }
}
