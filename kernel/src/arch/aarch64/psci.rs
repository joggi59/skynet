// SPDX-License-Identifier: GPL-3.0-or-later

//! PSCI — Power State Coordination Interface.

use core::arch::asm;

use crate::hal::{self, Cpu};

use super::cpu::Processor;

/// `SYSTEM_OFF`, PSCI 0.2+, 32-bit calling convention.
const PSCI_SYSTEM_OFF: u64 = 0x8400_0008;

/// Authority to power the machine off.
///
/// Zero-sized and unforgeable: the field is private and the constructor is
/// unsafe, so holding one is evidence of entitlement rather than of luck.
pub struct PowerControl {
    _private: (),
}

impl PowerControl {
    /// # Safety
    /// The platform's PSCI conduit must be HVC and callable from the current
    /// exception level. True for QEMU `virt` entered at EL1, which is the only
    /// entry level M0 supports — `boot.rs` parks anywhere else, precisely so
    /// this precondition cannot be falsified by the boot path that establishes
    /// it. See RFC-0001, O-3 (closed).
    ///
    /// `pub(super)` for the reason on [`super::pl011::BootConsole::new`], and
    /// more sharply here: this constructor takes no arguments, so a
    /// crate-visible version hands the authority to power the machine off to
    /// anyone willing to write `unsafe`.
    pub(super) const unsafe fn new() -> Self {
        Self { _private: () }
    }
}

impl hal::Power for PowerControl {
    fn off(self) -> ! {
        // SAFETY: SMC32 SYSTEM_OFF takes its function identifier in x0. QEMU's
        // virt machine implements PSCI itself at the HVC conduit when the guest
        // runs at EL1 with no EL2 and no secure firmware, which is exactly the
        // configuration the boot contract produces and the only one `boot.rs`
        // allows to reach here.
        //
        // Clobbers: the call may write x0-x3, declared as outputs so the
        // compiler does not assume they survive. SMCCC v1.0 additionally
        // permits x4-x17 corruption, and this kernel never queries
        // SMCCC_VERSION, so it must assume v1.0.
        //
        // Declaring only x0-x3 is nonetheless sound, for a reason that has to be
        // stated rather than assumed: nothing is live across this call on either
        // path. NOT "because the call is divergent" — the fall-through below
        // exists precisely because it may return, and review caught the earlier
        // wording contradicting itself four lines later.
        //
        // `nomem` holds because SYSTEM_OFF touches no memory this kernel can
        // observe, `nostack` because it uses none.
        unsafe {
            asm!(
                "hvc #0",
                inout("x0") PSCI_SYSTEM_OFF => _,
                out("x1") _,
                out("x2") _,
                out("x3") _,
                options(nomem, nostack),
            );
        }

        // Reached only if PSCI did not honour the call — firmware that does not
        // implement SYSTEM_OFF returns NOT_SUPPORTED rather than powering down.
        // `options(noreturn)` above would have been shorter and would have been
        // an unsound claim about someone else's firmware.
        Processor::halt()
    }
}
