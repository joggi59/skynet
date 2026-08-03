// SPDX-License-Identifier: GPL-3.0-or-later

//! Skynet kernel.
//!
//! Milestone M0: boot, announce, shut down. See `rfcs/0001-aarch64-boot.md`.
//!
//! `no_std` costs exactly two items here: `#![no_std]` swaps the `std` prelude
//! for `core`, and `#![no_main]` removes the requirement for a `fn main` with
//! the host startup contract. No external crate is involved in either — `core`
//! and `compiler_builtins` come from the installed `rust-std` for the target and
//! do not appear in `Cargo.lock`.

#![no_std]
#![no_main]

mod arch;
mod hal;
mod panic;

use hal::{BootResources, Console, Power};

/// The bytes that mean "this kernel is alive".
///
/// Defined by `BOOT_MARKER` in `ci/lib.sh` and looked for by `ci/boot-test.sh`.
/// It lives in portable code because it is a project contract, not a fact about
/// aarch64.
const BOOT_MARKER: &[u8] = b"SKYNET_BOOT_OK\n";

/// The portable kernel.
///
/// Generic over the device types, which is the point: this function cannot name
/// `BootConsole`, so it cannot acquire one by any route other than the one it
/// was handed. Portable code reaching for an architecture type would not
/// type-check. Monomorphisation makes the abstraction free.
///
/// No globals, no statics, no initialisation phase, and no way to obtain a
/// device it was not given.
pub fn kernel_main<C: Console, P: Power>(mut res: BootResources<C, P>) -> ! {
    res.console.write(BOOT_MARKER);
    res.power.off()
}
