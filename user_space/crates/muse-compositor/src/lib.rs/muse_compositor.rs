//! MuseOS Vulkan Compositor Surface Wrapper (`muse-compositor`)
//!
//! Provides high-performance, GPU-accelerated surface compositing and zero-copy
//! texture mapping for Retrievable Multimedia Objects (RMO) within user space.

#![no_std]

extern crate alloc;

use core::ffi::c_void;
use sel4_capability_sys::{SeL4Capability, SeL4Error};

/// Opaque Vulkan handle representations for bare-metal / no_std user-space execution.
#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VkInstance(pub *mut c_void);

#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VkPhysicalDevice(pub *mut c_void);

#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VkDevice(pub *mut c_void);

#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VkSurfaceKHR(pub u64);

#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VkSwapchainKHR(pub u64);

#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VkImage(pub u64);

#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VkDeviceMemory(pub u64);

/// Compositor surface display presentation modes.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PresentationMode {
    Immediate = 0,
    Fifo = 1,
    FifoRelaxed = 2,
    Mailbox = 3,
}

/// Color space and dynamic range target configuration.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorSpace {
    SRGBLinear = 0,
    HDR10Plus = 1,
    DolbyVision = 2,
}

/// Surface extent configuration (width x height in pixels).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Extent2D {
    pub width: u32,
    pub height: u32,
}

/// Errors specific to compositor surface allocation and Vulkan execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompositorError {
    VulkanInitializationFailed,
    SurfaceCreationFailed,
    SwapchainOutOfDate,
    DeviceLost,
    InvalidCapabilityToken,
    MemoryMappingFailed,
    SeL4Error(SeL4Error),
}

/// Configuration structure for creating a compositor display surface.
#[derive(Debug, Clone)]
pub struct SurfaceConfig {
    pub extent: Extent2D,
    pub mode: PresentationMode,
    pub color_space: ColorSpace,
    pub buffer_count: u32,
}

/// Represents an active Vulkan compositor surface connected to an seL4 display endpoint.
pub struct CompositorSurface {
    instance: VkInstance,
    physical_device: VkPhysicalDevice,
    device: VkDevice,
    surface: VkSurfaceKHR,
    swapchain: VkSwapchainKHR,
    config: SurfaceConfig,
    display_cap: SeL4Capability,
}

impl CompositorSurface {
    /// Constructs a new compositor surface backed by an seL4 display capability token.
    pub unsafe fn new(
        instance: VkInstance,
        physical_device: VkPhysicalDevice,
        device: VkDevice,
        display_cap: SeL4Capability,
        config: SurfaceConfig,
    ) -> Result<Self, CompositorError> {
        if display_cap.cptr == 0 {
            return Err(CompositorError::InvalidCapabilityToken);
        }

        // Create native Vulkan surface from seL4 frame descriptor capability
        let mut surface_handle: u64 = 0;
        let res = create_sel4_vulkan_surface(instance, display_cap.cptr, &mut surface_handle);
        if res != 0 {
            return Err(CompositorError::SurfaceCreationFailed);
        }

        let surface = VkSurfaceKHR(surface_handle);

        // Create initial swapchain
        let mut swapchain_handle: u64 = 0;
        let res = create_swapchain_khr(
            device,
            surface,
            config.extent.width,
            config.extent.height,
            config.mode as u32,
            config.color_space as u32,
            config.buffer_count,
            &mut swapchain_handle,
        );
        if res != 0 {
            return Err(CompositorError::VulkanInitializationFailed);
        }

        Ok(Self {
            instance,
            physical_device,
            device,
            surface,
            swapchain: VkSwapchainKHR(swapchain_handle),
            config,
            display_cap,
        })
    }

    /// Recreates the swapchain upon window resize or refresh rate shift.
    pub fn resize(&mut self, new_extent: Extent2D) -> Result<(), CompositorError> {
        self.config.extent = new_extent;
        let mut new_swapchain: u64 = 0;

        let res = unsafe {
            create_swapchain_khr(
                self.device,
                self.surface,
                new_extent.width,
                new_extent.height,
                self.config.mode as u32,
                self.config.color_space as u32,
                self.config.buffer_count,
                &mut new_swapchain,
            )
        };

        if res != 0 {
            return Err(CompositorError::SwapchainOutOfDate);
        }

        self.swapchain = VkSwapchainKHR(new_swapchain);
        Ok(())
    }

    /// DirectStorage Zero-Copy Import: Imports an RMO DirectStorage VRAM allocation directly into Vulkan.
    pub unsafe fn import_rmo_vram_texture(
        &self,
        vram_phys_addr: u64,
        size_bytes: u64,
        out_image: *mut VkImage,
        out_memory: *mut VkDeviceMemory,
    ) -> Result<(), CompositorError> {
        if vram_phys_addr == 0 || size_bytes == 0 {
            return Err(CompositorError::MemoryMappingFailed);
        }

        let res = bind_direct_storage_vram(
            self.device,
            vram_phys_addr,
            size_bytes,
            out_image,
            out_memory,
        );

        if res != 0 {
            return Err(CompositorError::MemoryMappingFailed);
        }

        Ok(())
    }

    /// Submits the current frame buffer to the presentation engine.
    pub fn present_frame(&self, image_index: u32) -> Result<(), CompositorError> {
        let res = unsafe { queue_present_khr(self.device, self.swapchain.0, image_index) };
        if res != 0 {
            return Err(CompositorError::DeviceLost);
        }
        Ok(())
    }

    /// Returns the active surface configuration.
    pub fn config(&self) -> &SurfaceConfig {
        &self.config
    }
}

// -----------------------------------------------------------------------------
// FFI Declarations for Bare-Metal Vulkan / Display Server Integration
// -----------------------------------------------------------------------------
extern "C" {
    fn create_sel4_vulkan_surface(
        instance: VkInstance,
        display_cptr: u64,
        out_surface: *mut u64,
    ) -> i32;

    fn create_swapchain_khr(
        device: VkDevice,
        surface: VkSurfaceKHR,
        width: u32,
        height: u32,
        present_mode: u32,
        color_space: u32,
        buffer_count: u32,
        out_swapchain: *mut u64,
    ) -> i32;

    fn bind_direct_storage_vram(
        device: VkDevice,
        vram_phys_addr: u64,
        size_bytes: u64,
        out_image: *mut VkImage,
        out_memory: *mut VkDeviceMemory,
    ) -> i32;

    fn queue_present_khr(device: VkDevice, swapchain: u64, image_index: u32) -> i32;
}
