// SPDX-License-Identifier: GPL-3.0-or-later

//! PL011 UART — the boot console.

use core::ptr::{read_volatile, write_volatile};

use crate::hal;

/// A PL011 the holder is entitled to drive.
///
/// The `base` field is private and there is no safe constructor, so holding a
/// `BootConsole` in safe code is evidence that someone entitled to create one
/// did. That is what ownership is doing at M0 in place of the capability that
/// will do it at M4.
pub struct BootConsole {
    base: *mut u8,
}

impl BootConsole {
    /// Data register. Writing a byte transmits it. Write-only here.
    const DR: usize = 0x000;
    /// Flag register. Read-only here.
    const FR: usize = 0x018;
    /// `FR.TXFF` — transmit FIFO full.
    const FR_TXFF: u32 = 1 << 5;

    /// # Safety
    /// `base` must be the MMIO base of a PL011 that no other code touches, and
    /// this must be called at most once for that device.
    pub const unsafe fn new(base: usize) -> Self {
        Self { base: base as *mut u8 }
    }
}

impl hal::Console for BootConsole {
    /// Write every byte, blocking until the device has accepted each one.
    ///
    /// No initialisation of LCR_H, IBRD, FBRD or CR. QEMU's PL011 transmits
    /// without it, and on real hardware the firmware has already configured the
    /// port it printed its own messages on. Writing a configuration sequence
    /// nobody can test against real hardware is not something M0 should do.
    fn write(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            // SAFETY:
            //
            // `self.base` is the MMIO base of a PL011, established by the
            // unsafe constructor's precondition — holding `self` is the
            // evidence that precondition was met.
            //
            // The MMU is off throughout M0 (page tables are M1), so the
            // physical address is the address issued, and both accesses are to
            // Device-nGnRnE memory, which is what makes the poll-then-write
            // ordering architecturally real rather than merely a compiler
            // property. `volatile` additionally forbids the compiler eliding,
            // reordering or coalescing them.
            //
            // FR is only read and DR is only written, so neither access is a
            // read-modify-write and no hazard exists between them.
            //
            // `&mut self` gives exclusive access for the duration, so no other
            // holder can interleave. The one aliasing exception is
            // `Failure::fail_stop`, which is sound because the kernel has
            // already failed and nothing else will run again.
            unsafe {
                let fr = self.base.add(Self::FR) as *const u32;
                while read_volatile(fr) & Self::FR_TXFF != 0 {}
                write_volatile(self.base.add(Self::DR) as *mut u32, byte as u32);
            }
        }
    }
}
