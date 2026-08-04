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
    // `pub(super)`, so that the vector table's re-entrancy path can reach the
    // console without a second copy of these three facts. It writes the UART
    // directly — it has no stack and cannot construct a `BootConsole` — and a
    // duplicated register offset is how a driver and its emergency path drift
    // apart. Visible within `arch::aarch64` only; portable code sees nothing.
    pub(super) const DR: usize = 0x000;
    /// Flag register. Read-only here.
    pub(super) const FR: usize = 0x018;
    /// `FR.TXFF` — transmit FIFO full.
    pub(super) const FR_TXFF: u32 = 1 << 5;

    /// How many times either console path asks a full FIFO before giving up on
    /// a byte.
    ///
    /// Not a timeout — there is no clock at M1 and this count has no unit. The
    /// only property it buys is that the loop ends. Roughly a millisecond of
    /// polling on the machines this runs on: several orders of magnitude more
    /// than a PL011 needs to drain a character, and nothing beside the
    /// thirty-second CI timeout it exists to prevent.
    ///
    /// `pub(super)` because the vector table's emergency path spells the same
    /// loop in assembly and must not carry its own number. One budget, two
    /// spellings, and the second one is checked against the first by nothing but
    /// this comment — which is why they share the constant instead.
    pub(super) const POLL_BUDGET: u32 = 1_000_000;

    /// # Safety
    /// `base` must be the MMIO base of a PL011 that no other code touches, and
    /// this must be called at most once for that device.
    ///
    /// `pub(super)`, not `pub`. A crate-visible constructor lets any portable
    /// module mint its own device and bypass the token it was handed; review
    /// demonstrated exactly that against the merged M0. Visibility is what makes
    /// "only the boot path creates devices" a property of the language instead
    /// of an item on a review checklist.
    pub(super) const unsafe fn new(base: usize) -> Self {
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
            // The poll is BOUNDED, and the byte is dropped when the budget runs
            // out rather than waited for forever.
            //
            // `while TXFF {}` is the obvious spelling and it is unbounded in the
            // one direction that matters: a UART that answers and never drains.
            // No exception is ever taken, so no guard, no state machine and no
            // watchdog can intervene — review demonstrated it by pointing this
            // poll at QEMU virt's PCIe MMIO window, which reads back with TXFF
            // set forever. Two exceptions on the clock, nothing on the console,
            // and a thirty-second CI timeout indistinguishable from a hang.
            //
            // This is not a timeout. There is no clock here and the count has no
            // unit; the only property being bought is that the loop ends. A
            // console that eats a byte is a bad console. A console that stops the
            // kernel is a bad kernel.
            unsafe {
                let fr = self.base.add(Self::FR) as *const u32;
                let mut budget = Self::POLL_BUDGET;
                while read_volatile(fr) & Self::FR_TXFF != 0 {
                    budget -= 1;
                    if budget == 0 {
                        // Abandon the whole write, not just this byte. A FIFO
                        // that has not moved in a million reads will not move
                        // for the next byte either, and spending the budget
                        // again per byte turns one stall into a hundred.
                        return;
                    }
                }
                write_volatile(self.base.add(Self::DR) as *mut u32, byte as u32);
            }
        }
    }
}
