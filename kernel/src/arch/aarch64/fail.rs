// SPDX-License-Identifier: GPL-3.0-or-later

//! The failure path, and the only place outside `boot_rust` that mints a device.

use crate::hal::{self, Console, Power};

use super::pl011::BootConsole;
use super::platform;
use super::psci::PowerControl;

/// The platform's fail-stop.
///
/// This is the single place in the kernel where authority is created outside
/// the boot path, and it is bounded deliberately: one function, one caller, one
/// compile-time constant written, never returns, not a [`hal::Console`], and
/// unusable for ordinary output.
///
/// What would turn it into a global console — and must not be allowed to:
/// returning instead of diverging, gaining a receiver, acquiring a second call
/// site, or being handed anything other than a compile-time constant.
pub struct Failure;

impl hal::FailStop for Failure {
    unsafe fn fail_stop(bytes: &[u8]) -> ! {
        // SAFETY: the kernel has already failed and this function never
        // returns, so no other owner of the PL011 or of PSCI will run again and
        // the aliasing cannot race with anything. `UART0_BASE` is the platform
        // console's base, which satisfies `BootConsole::new`'s precondition;
        // the "at most once" clause is met in substance because the other
        // holder is provably dead.
        let mut console = unsafe { BootConsole::new(platform::UART0_BASE) };
        console.write(bytes);
        // SAFETY: as above — reached only after the kernel has failed, from a
        // path that never returns, at EL1 where the HVC conduit is valid.
        unsafe { PowerControl::new() }.off()
    }
}
