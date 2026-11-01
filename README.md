# MuseOS — AMD64 Multimedia Operating System Architecture

MuseOS is a high-performance, modular operating system engineered specifically for modern **AMD64 hardware platforms**. Designed around a formally verified **seL4 microkernel**, MuseOS integrates an assembly-optimized Copy-on-Write (CoW) filesystem, a zero-copy **Retrievable Multimedia Object (RMO)** streaming pipeline, hardware-accelerated DirectStorage NVMe DMA drivers, and a `no_std` Rust user-space rendering stack.

---

## 🏛️ System Architecture

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        User Space (Rust / Vulkan)                      │
│   ┌─────────────────────┐  ┌─────────────────────┐  ┌──────────────┐   │
│   │   muse-compositor   │  │     muse-audio      │  │  rmo-client  │   │
│   │ (Vulkan Swapchain)  │  │ (Lock-Free Audio)   │  │ (media://)   │   │
│   └──────────┬──────────┘  └──────────┬──────────┘  └──────┬───────┘   │
│              │                        │                    │           │
│              └────────────────────────┼────────────────────┘           │
│                                       │ (seL4 IPC / CSpace)            │
├───────────────────────────────────────┴────────────────────────────────┤
│                     System Daemons & Drivers (Zig)                     │
│   ┌─────────────────────┐  ┌─────────────────────┐  ┌──────────────┐   │
│   │    Name Resolver    │  │ DirectStorage NVMe  │  │ AMD-Vi IOMMU │   │
│   │    (media:// RMO)   │  │   (DMA Polled SQ)   │  │ (DTE Mapping)│   │
│   └──────────┬──────────┘  └──────────┬──────────┘  └──────┬───────┘   │
│              │                        │                    │           │
│              └────────────────────────┼────────────────────┘           │
│                                       │ (ASM CoW Block Scan)           │
├───────────────────────────────────────┴────────────────────────────────┤
│                    Bare-Metal Core (Assembly & C Header)               │
│   ┌─────────────────────┐  ┌─────────────────────┐  ┌──────────────┐   │
│   │       boot.S        │  │     block_scan.S    │  │    idt.S     │   │
│   │ (Multiboot2 Entry)  │  │ (AVX2 Bit-Scanner) │  │ (IDT Traps)  │   │
│   └─────────────────────┘  └─────────────────────┘  └──────────────┘   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 🔑 Core Features & Components

### 1. Bare-Metal Assembly Kernel Initialization
* **Multiboot2 Bootloader Entry (`kernel/asm/boot/boot.S`)**: Sets up 64-bit Long Mode, establishes initial 4-level page tables, and transitions from 32-bit protected mode to 64-bit execution.
* **IDT & Exception Traps (`kernel/asm/interrupts/idt.S`)**: Full System V ABI register saving with support for 256 interrupt gates and CPU exception dispatchers.
* **Linker & Hardware Config (`kernel/linker.ld`, `kernel/config/sel4_config.h`)**: Places kernel entry at `0x100000` (1 MiB) with 4 KiB aligned sections and seL4 root CSpace capability sizing.

### 2. High-Throughput Memory & Filesystem Infrastructure
* **4-Level Paging Engine (`kernel/src/memory/paging.zig`)**: Complete 64-bit page table manipulation (PML4 to PT), 2 MiB huge-page mapping, and inline `CR3` / `INVLPG` control.
* **DirectStorage Map Descriptors (`kernel/src/memory/direct_storage.zig`)**: 64-byte aligned memory structures matching AMD64 cache lines for zero-copy transfers between NVMe controllers and GPU VRAM.
* **CoW Bit-Scanner (`kernel/asm/cow_allocator/block_scan.S`)**: Assembly-optimized `popcnt` and `tzcnt` loop for ultra-fast free-block allocation in Copy-on-Write storage pools.

### 3. System Services & Hardware Drivers (Zig sDDF)
* **Retrievable Multimedia Objects (`system_services/name_resolver/src/rmo_parser.zig`)**: 64-byte zero-copy header parser for RMO binary assets, enforcing media type schemas and DMA eligibility flags.
* **Logical URI Name Resolver (`system_services/name_resolver/src/main.zig`)**: High-performance daemon resolving `media://` paths to raw block offsets and IPC capability tokens.
* **DirectStorage NVMe Driver (`system_services/drivers/nvme/main.zig`)**: Polled-mode submission/completion queue manager supporting NVMe DMA hardware bypass directly to host/VRAM targets.
* **AMD-Vi IOMMU Driver (`system_services/drivers/iommu/main.zig`)**: Hardware DMA translation driver managing Device Table Entries (DTEs) and page invalidation doorbells.

### 4. User-Space Framework & Engine Crates (Rust `#![no_std]`)
* **seL4 Capability Manager (`user_space/crates/sel4-capability-sys/src/cspace.rs`)**: High-assurance CNode slot allocation, badge minting, and capability revocation wrappers.
* **RMO Client Library (`user_space/crates/rmo-client/src/lib.rs`)**: Client API for resolving `media://` asset URIs and streaming DirectStorage payloads.
* **Vulkan Compositor (`user_space/crates/muse-compositor/src/lib.rs`)**: Zero-copy surface renderer importing RMO textures directly into VRAM swapchains.
* **Audio Stream Renderer (`user_space/crates/muse-audio/src/lib.rs`)**: Lock-free atomic double-buffered ring-buffer engine for low-latency PCM audio output.

---

## 📂 Repository Structure

```text
.
├── build.zig                              # Master Zig Build Orchestrator
├── kernel/
│   ├── linker.ld                          # Linker script (1 MB base load address)
│   ├── config/
│   │   └── sel4_config.h                  # seL4 microkernel configuration header
│   ├── asm/
│   │   ├── boot/boot.S                    # Multiboot2 64-bit initialization
│   │   ├── cow_allocator/block_scan.S     # Assembly AVX2/bit-scan block search
│   │   └── interrupts/idt.S               # 64-bit IDT & exception trap handlers
│   └── src/memory/
│       ├── paging.zig                     # 4-level AMD64 paging management
│       └── direct_storage.zig             # DirectStorage DMA memory descriptors
├── system_services/
│   ├── fs_cow/src/
│   │   └── asm_bindings.zig               # Zig FFI safety wrapper for block_scan.S
│   ├── name_resolver/src/
│   │   ├── rmo_parser.zig                 # RMO header binary layout & validation
│   │   └── main.zig                       # media:// URI daemon implementation
│   └── drivers/
│       ├── nvme/main.zig                  # DirectStorage NVMe DMA driver daemon
│       └── iommu/main.zig                 # AMD-Vi IOMMU DMA translation driver
├── user_space/crates/
│   ├── sel4-capability-sys/src/
│   │   ├── lib.rs                         # seL4 syscall FFI bindings
│   │   └── cspace.rs                      # CSpace capability slot allocator
│   ├── rmo-client/src/lib.rs              # User-space RMO client library
│   ├── muse-compositor/src/lib.rs         # Rust Vulkan swapchain compositor
│   └── muse-audio/src/lib.rs              # Lock-free atomic audio renderer
├── tests/
│   └── nvme_dma_test.zig                  # DirectStorage NVMe unit tests
├── scripts/
│   └── launch_qemu.sh                     # QEMU launcher with NVMe & GDB debugging
└── .github/workflows/
    └── ci.yml                             # GitHub Actions CI build & test pipeline
```

---

## 🛠️ Prerequisites & Setup

Ensure the following toolchains are installed on your build host:

* **Zig Compiler**: Version `0.13.0` or newer
* **Rust Toolchain**: `nightly` with the `x86_64-unknown-none` target installed:
  ```bash
  rustup target add x86_64-unknown-none
  ```
* **Assembler**: `nasm` or `gas` (GNU Assembler)
* **Emulation**: `qemu-system-x86_64` (for bare-metal execution)

---

## 🚀 Building & Running

### 1. Compile the Entire Operating System
Build the boot assembly, Zig daemons, Rust user-space crates, and kernel executable using the master Zig build script:

```bash
zig build
```

### 2. Run DirectStorage & Driver Unit Tests
Execute the automated DMA unit test suite:

```bash
zig test tests/nvme_dma_test.zig
```

### 3. Launch in QEMU Simulation
Boot the compiled `museos-kernel.elf` binary inside QEMU with hardware acceleration and simulated NVMe PCIe drives:

```bash
# Executable run step via Zig
zig build run

# Or launch directly using the shell script
chmod +x scripts/launch_qemu.sh
./scripts/launch_qemu.sh
```

### 4. Enable GDB Remote Debugging
To launch QEMU with a GDB remote server on port `1234` (CPU execution paused at startup):

```bash
./scripts/launch_qemu.sh --gdb
```

In a separate terminal, connect GDB:
```bash
gdb -ex "target remote localhost:1234" -ex "symbol-file zig-out/bin/museos-kernel.elf"
```

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.
