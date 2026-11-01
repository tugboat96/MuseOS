//! MuseOS User-Space Audio Stream Renderer Crate (`muse-audio`)
//!
//! Provides a high-performance, `#![no_std]` audio streaming renderer for Retrievable Multimedia
//! Objects (RMO) within the MuseOS environment. Integrates with seL4 IPC endpoints and 
//! DirectStorage DMA buffers to achieve ultra-low latency PCM audio playback.

#![no_std]

use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// Supported audio sample formats in MuseOS RMO streams.
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SampleFormat {
    PcmInt16 = 1,
    PcmInt24 = 2,
    PcmInt32 = 3,
    PcmFloat32 = 4,
}

/// Channel layout configuration for audio streams.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelLayout {
    Mono = 1,
    Stereo = 2,
    Quadraphonic = 4,
    Surround51 = 6,
    Surround71 = 8,
}

/// Configuration parameters for initializing an audio render stream.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AudioConfig {
    pub sample_rate: u32,
    pub channels: ChannelLayout,
    pub format: SampleFormat,
    pub buffer_frame_count: u32,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            sample_rate: 48000,
            channels: ChannelLayout::Stereo,
            format: SampleFormat::PcmFloat32,
            buffer_frame_count: 512,
        }
    }
}

/// Render status codes returned by the audio stream renderer.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioStatus {
    Ok = 0,
    BufferOverflow = -1,
    BufferUnderflow = -2,
    InvalidConfig = -3,
    DeviceNotReady = -4,
    IpcError = -5,
}

/// Double-buffered audio ring buffer header shared between user-space and audio hardware daemon.
#[repr(C, align(64))]
pub struct AudioRingBufferHeader {
    pub write_cursor: AtomicUsize,
    pub read_cursor: AtomicUsize,
    pub total_buffer_bytes: usize,
    pub period_bytes: usize,
    pub is_playing: AtomicBool,
    pub is_muted: AtomicBool,
}

/// Core audio renderer engine managing stream playback and DirectStorage DMA buffer submits.
pub struct AudioStreamRenderer {
    config: AudioConfig,
    ring_buffer: *mut AudioRingBufferHeader,
    pcm_data_buffer: *mut u8,
    buffer_len: usize,
    sel4_ep_cap: u64,
}

impl AudioStreamRenderer {
    /// Creates a new `AudioStreamRenderer` instance bound to an seL4 audio daemon endpoint capability.
    ///
    /// # Safety
    /// The caller must guarantee that `ring_buffer` and `pcm_data_buffer` point to valid, page-aligned
    /// shared memory buffers established via seL4 CSpace mapping.
    pub unsafe fn new(
        config: AudioConfig,
        ring_buffer: *mut AudioRingBufferHeader,
        pcm_data_buffer: *mut u8,
        buffer_len: usize,
        sel4_ep_cap: u64,
    ) -> Result<Self, AudioStatus> {
        if ring_buffer.is_null() || pcm_data_buffer.is_null() {
            return Err(AudioStatus::InvalidConfig);
        }

        if config.sample_rate < 8000 || config.sample_rate > 192000 {
            return Err(AudioStatus::InvalidConfig);
        }

        Ok(Self {
            config,
            ring_buffer,
            pcm_data_buffer,
            buffer_len,
            sel4_ep_cap,
        })
    }

    /// Submits a frame buffer slice to the underlying audio DMA ring buffer.
    pub fn submit_pcm_samples(&self, samples: &[u8]) -> AudioStatus {
        if samples.is_empty() || samples.len() > self.buffer_len {
            return AudioStatus::InvalidConfig;
        }

        unsafe {
            let header = &*self.ring_buffer;
            let current_write = header.write_cursor.load(Ordering::Acquire);
            let current_read = header.read_cursor.load(Ordering::Acquire);

            // Compute available space in ring buffer
            let occupied = if current_write >= current_read {
                current_write - current_read
            } else {
                self.buffer_len - (current_read - current_write)
            };

            let available = self.buffer_len.saturating_sub(occupied);
            if samples.len() > available {
                return AudioStatus::BufferOverflow;
            }

            // Copy samples into shared PCM data buffer
            let dest_ptr = self.pcm_data_buffer.add(current_write);
            let first_part = core::cmp::min(samples.len(), self.buffer_len - current_write);
            
            core::ptr::copy_nonoverlapping(samples.as_ptr(), dest_ptr, first_part);

            if samples.len() > first_part {
                let second_part = samples.len() - first_part;
                core::ptr::copy_nonoverlapping(
                    samples.as_ptr().add(first_part),
                    self.pcm_data_buffer,
                    second_part,
                );
            }

            // Update write cursor atomic
            let next_write = (current_write + samples.len()) % self.buffer_len;
            header.write_cursor.store(next_write, Ordering::Release);
        }

        AudioStatus::Ok
    }

    /// Triggers audio playback start via seL4 IPC kernel notification.
    pub fn start(&self) -> AudioStatus {
        unsafe {
            let header = &*self.ring_buffer;
            header.is_playing.store(true, Ordering::Release);
        }

        // Trigger seL4 IPC signal to audio hardware service (RDI=cap, RAX=0x401 AudioStart)
        self.notify_audio_daemon(0x401);
        AudioStatus::Ok
    }

    /// Pauses audio stream output without dropping buffer contents.
    pub fn pause(&self) -> AudioStatus {
        unsafe {
            let header = &*self.ring_buffer;
            header.is_playing.store(false, Ordering::Release);
        }

        self.notify_audio_daemon(0x402);
        AudioStatus::Ok
    }

    /// Inline AMD64 assembly syscall trigger to notify seL4 audio hardware daemon.
    fn notify_audio_daemon(&self, opcode: u64) {
        #[cfg(target_arch = "x86_64")]
        unsafe {
            core::arch::asm!(
                "mov rdi, {cap}",
                "mov rsi, {msg_info}",
                "syscall",
                cap = in(reg) self.sel4_ep_cap,
                msg_info = in(reg) opcode,
                out("rax") _,
                out("rcx") _,
                out("r11") _,
                options(nostack)
            );
        }
    }

    /// Returns the current configuration of this audio renderer stream.
    pub fn config(&self) -> &AudioConfig {
        &self.config
    }
}
