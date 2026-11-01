/*
 * seL4 Kernel Boot Configuration Spec for MuseOS
 * Target Architecture: AMD64 / x86_64
 * Configuration File: kernel/config/sel4_config.h
 */

#ifndef SEL4_CONFIG_H
#define SEL4_CONFIG_H

#include <stdint.h>
#include <stdbool.h>

/* =========================================================================
 * Architecture & Hardware Configuration (AMD64)
 * ========================================================================= */

#define CONFIG_ARCH_X86_64                  1
#define CONFIG_ARCH_X86                     1
#define CONFIG_WORD_SIZE                    64

/* Page Table & Memory Layout */
#define CONFIG_HUGE_PAGE_SUPPORT            1   /* 2MB and 1GB Page Support */
#define CONFIG_VTX_SUPPORT                  1   /* Hardware Virtualization */
#define CONFIG_IOMMU_SUPPORT                1   /* AMD-Vi IOMMU Protection */

/* Vector Interrupt & APIC Configuration */
#define CONFIG_MAX_NUM_IOAPIC               4
#define CONFIG_XAPIC_MODE                   1
#define CONFIG_X2APIC_MODE                  1
#define CONFIG_TIMER_TICK_MS                1   /* 1ms Tick Frequency */

/* =========================================================================
 * Kernel Memory & CSpace Sizing Spec
 * ========================================================================= */

/* Capability Node (CNode) Initial Sizing */
#define CONFIG_ROOT_CNODE_SIZE_BITS         16  /* 65,536 Capability Slots */
#define CONFIG_BOOT_CAP_ADDRESS_BITS        64

/* Untyped Memory Allocator Sizing */
#define CONFIG_MAX_NUM_BOOTINFO_UNTYPED     64
#define CONFIG_MIN_UNTYPED_SIZE_BITS        12  /* 4 KiB Smallest Chunk */
#define CONFIG_MAX_UNTYPED_SIZE_BITS        30  /* 1 GiB Largest Chunk */

/* =========================================================================
 * System Call & IPC Configuration
 * ========================================================================= */

#define CONFIG_FASTPATH                     1   /* Fastpath IPC Enabled */
#define CONFIG_MAX_NUM_NODES                1   /* Single-Node Core */
#define CONFIG_NUM_PRIORITIES               256 /* 256 Scheduling Priorities */
#define CONFIG_MAX_IPC_MSG_WORDS            120 /* Max Message Payload Registers */

/* Kernel Stack & Physical Base Address */
#define CONFIG_KERNEL_STACK_SIZE_BYTES      8192
#define CONFIG_PADDR_LOAD                   0x00100000 /* 1MB Base Load */

/* =========================================================================
 * Data Structures & Capability Definitions
 * ========================================================================= */

typedef struct sel4_bootinfo {
    uint64_t extraLen;
    uint64_t nodeID;
    uint64_t numNodes;
    uint64_t numIOPTLevels;
    uint64_t ipcBufferVaddr;
    uint64_t rootCNodeSizeBits;
    uint64_t initThreadCNodeSizeBits;
    uint64_t untypedMemoryRangeBits[CONFIG_MAX_NUM_BOOTINFO_UNTYPED];
    uint64_t untypedPaddr[CONFIG_MAX_NUM_BOOTINFO_UNTYPED];
} sel4_bootinfo_t;

/* Function stub for bare-metal kernel initialization entry point */
static inline bool sel4_validate_boot_config(void) {
    return (CONFIG_WORD_SIZE == 64) && (CONFIG_PADDR_LOAD == 0x00100000);
}

#endif /* SEL4_CONFIG_H */
