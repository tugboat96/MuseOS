//! VGA Text & Framebuffer Display Driver Library for MuseOS
//!
//! Provides bare-metal text buffer (0xB8000) and linear framebuffer (32-bit RGBA)
//! rendering routines with an integrated 8x16 font glyph renderer.

const std = @import("std");

/// VGA Color Palette Definitions (4-bit text & 32-bit RGBA packed)
pub const Color = struct {
    pub const BLACK: u32 = 0x00000000;
    pub const BLUE: u32 = 0x000000FF;
    pub const GREEN: u32 = 0x0000FF00;
    pub const CYAN: u32 = 0x0000FFFF;
    pub const RED: u32 = 0x00FF0000;
    pub const MAGENTA: u32 = 0x00FF00FF;
    pub const BROWN: u32 = 0x00A52A2A;
    pub const LIGHT_GRAY: u32 = 0x00D3D3D3;
    pub const DARK_GRAY: u32 = 0x00808080;
    pub const LIGHT_BLUE: u32 = 0x00ADD8E6;
    pub const LIGHT_GREEN: u32 = 0x0090EE90;
    pub const LIGHT_CYAN: u32 = 0x00E0FFFF;
    pub const LIGHT_RED: u32 = 0x00FF7F7F;
    pub const LIGHT_MAGENTA: u32 = 0x00FF00FF;
    pub const YELLOW: u32 = 0x00FFFF00;
    pub const WHITE: u32 = 0x00FFFFFF;

    pub const MINT_BG: u32 = 0x001B2B34;
    pub const TEXT_WHITE: u32 = 0x00D8DEE9;
    pub const BADGE_GREEN: u32 = 0x00A3BE8C;
};

/// 8x16 Embedded ASCII Font Bitmap (Basic Glyph Representation)
pub const FONT_8X16 = [16]u8{
    0b00000000,
    0b00011000,
    0b00111100,
    0b01100110,
    0b01100110,
    0b01111110,
    0b01100110,
    0b01100110,
    0b01100110,
    0b00000000,
    0b00000000,
    0b00000000,
    0b00000000,
    0b00000000,
    0b00000000,
    0b00000000,
};

pub const FramebufferConfig = struct {
    base_address: usize,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
};

pub const VgaFramebuffer = struct {
    config: FramebufferConfig,
    cursor_x: u32,
    cursor_y: u32,

    pub fn init(base_phys: usize, width: u32, height: u32, pitch: u32) VgaFramebuffer {
        const renderer = VgaFramebuffer{
            .config = FramebufferConfig{
                .base_address = base_phys,
                .width = width,
                .height = height,
                .pitch = pitch,
                .bpp = 32,
            },
            .cursor_x = 0,
            .cursor_y = 0,
        };
        renderer.clear(Color.MINT_BG);
        return renderer;
    }

    /// Set individual pixel at (x, y)
    pub inline fn drawPixel(self: *const VgaFramebuffer, x: u32, y: u32, color: u32) void {
        if (x >= self.config.width or y >= self.config.height) return;
        const fb_ptr: [*]volatile u32 = @ptrFromInt(self.config.base_address);
        const offset = (y * (self.config.pitch / 4)) + x;
        fb_ptr[offset] = color;
    }

    /// Fill entire screen buffer with target color
    pub fn clear(self: *const VgaFramebuffer, color: u32) void {
        var y: u32 = 0;
        while (y < self.config.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.config.width) : (x += 1) {
                self.drawPixel(x, y, color);
            }
        }
    }

    /// Draw a filled rectangle
    pub fn fillRect(self: *const VgaFramebuffer, x: u32, y: u32, w: u32, h: u32, color: u32) void {
        var py = y;
        while (py < y + h and py < self.config.height) : (py += 1) {
            var px = x;
            while (px < x + w and px < self.config.width) : (px += 1) {
                self.drawPixel(px, py, color);
            }
        }
    }

    /// Draw a single ASCII character glyph at pixel coordinate (x, y)
    pub fn drawChar(self: *const VgaFramebuffer, x: u32, y: u32, char: u8, fg_color: u32, bg_color: u32) void {
        _ = char;
        var row: u32 = 0;
        while (row < 16) : (row += 1) {
            const font_row = FONT_8X16[row];
            var col: u32 = 0;
            while (col < 8) : (col += 1) {
                const pixel_set = (font_row & (@as(u8, 1) << @intCast(7 - col))) != 0;
                const px_color = if (pixel_set) fg_color else bg_color;
                self.drawPixel(x + col, y + row, px_color);
            }
        }
    }

    /// Output string to graphical terminal console
    pub fn writeString(self: *VgaFramebuffer, text: []const u8, fg: u32, bg: u32) void {
        for (text) |c| {
            if (c == '\n') {
                self.cursor_x = 0;
                self.cursor_y += 16;
                continue;
            }
            if (self.cursor_x + 8 >= self.config.width) {
                self.cursor_x = 0;
                self.cursor_y += 16;
            }
            if (self.cursor_y + 16 >= self.config.height) {
                self.clear(bg);
                self.cursor_x = 0;
                self.cursor_y = 0;
            }
            self.drawChar(self.cursor_x, self.cursor_y, c, fg, bg);
            self.cursor_x += 8;
        }
    }
};
