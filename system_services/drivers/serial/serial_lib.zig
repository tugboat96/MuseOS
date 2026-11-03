const std = @import("std");

/// AMD64 Low-Level I/O Port Assemblies
pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[val], %[pt]"
        :
        : [val] "{al}" (value),
          [pt] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[pt], %[val]"
        : [val] "={al}" (-> u8),
        : [pt] "{dx}" (port),
    );
}

/// Standard COM1 Serial UART Controller Address
pub const COM1_PORT: u16 = 0x3F8;

pub const SerialPort = struct {
    port: u16,

    pub fn init(port: u16) SerialPort {
        const serial = SerialPort{ .port = port };
        // Disable UART Interrupts
        outb(port + 1, 0x00);
        // Enable DLAB (Divisor Latch Access Bit)
        outb(port + 3, 0x80);
        // Set Baud Rate Divisor to 3 (38,400 Baud)
        outb(port + 0, 0x03);
        outb(port + 1, 0x00);
        // 8 Bits, No Parity, 1 Stop Bit (8N1)
        outb(port + 3, 0x03);
        // Enable FIFO, Clear Queues, set 14-byte Interrupt Threshold
        outb(port + 2, 0xC7);
        // Enable IRQs, Assert RTS/DSR Signals
        outb(port + 4, 0x0B);
        return serial;
    }

    pub fn isTransmitEmpty(self: *const SerialPort) bool {
        return (inb(self.port + 5) & 0x20) != 0;
    }

    pub fn writeByte(self: *const SerialPort, byte: u8) void {
        while (!self.isTransmitEmpty()) {
            asm volatile ("pause");
        }
        outb(self.port, byte);
    }

    pub fn writeString(self: *const SerialPort, str: []const u8) void {
        for (str) |c| {
            if (c == '\n') {
                self.writeByte('\r');
            }
            self.writeByte(c);
        }
    }
};
