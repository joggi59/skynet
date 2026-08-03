// SPDX-License-Identifier: GPL-3.0-or-later

//! The executing processor.

use core::arch::asm;

use crate::hal;

/// The processor this code is running on.
///
/// Carries no state and needs no token: [`hal::Cpu::halt`] grants access to
/// nothing — it removes the caller's own ability to continue.
pub struct Processor;

impl hal::Cpu for Processor {
    fn halt() -> ! {
        // SAFETY: `msr daifset` masks D, A, I and F on the current processor.
        // It touches no memory and uses no stack, so `nomem` and `nostack` hold.
        unsafe { asm!("msr daifset, #0xf", options(nomem, nostack)) };

        loop {
            // SAFETY: `wfi` is a hint instruction. It suspends until an
            // interrupt is pending and has no memory or stack effect. With
            // interrupts masked just above and none configured at M0, it parks
            // the processor indefinitely, which is the intent.
            //
            // `wfi` rather than a bare `loop {}`: it is what the instruction is
            // for, and an empty loop trips `clippy::empty_loop` under -D warnings.
            unsafe { asm!("wfi", options(nomem, nostack)) };
        }
    }
}
