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
//!
//! # What is here and what is in the library
//!
//! This binary holds everything that must reach the image whether or not
//! anything references it: the architecture modules, the panic handler, the
//! entry path. The portable, host-testable half — `hal` and `fdt` — is in the
//! `skynet_kernel` library, because `cargo test` has nowhere to put a harness in
//! a `no_main` binary. A `rlib` member nothing references is not linked in, so
//! the split costs the image nothing on its own.
//!
//! The `use skynet_kernel::hal;` below is load-bearing beyond this file: it
//! binds the name `hal` in this crate's root, so the `crate::hal::…` paths in
//! `arch/` and `panic.rs` keep resolving and no file under `arch/` had to be
//! touched to move `hal` into the library.

#![no_std]
#![no_main]

mod arch;
mod panic;

use skynet_kernel::hal;

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
///
/// It decomposes `BootResources` on its first line and never names it again,
/// which is what RFC-0001 asked of that struct: a parameter list that is taken
/// apart, not a registry something later reaches into. The frame allocator is
/// bound and dropped here because M1 has nothing to allocate for yet — binding
/// it is the honest shape, the same one `boot_rust` used for the memory map
/// before there was anything to hand it to.
///
/// Nothing is printed about the memory that was found: no count, no address, no
/// size. Printing a number needs a portable formatter, which is RFC-0001 O-4's
/// design and not a `write!` added here, and constitutional invariant 5 is
/// pending until M6 so nothing mechanical would have caught it.
pub fn kernel_main<C: Console, P: Power>(res: BootResources<C, P>) -> ! {
    let BootResources {
        mut console,
        power,
        frames: _frames,
    } = res;

    console.write(BOOT_MARKER);
    power.off()
}

/// Compile-time proof that the architecture implements the whole contract.
///
/// Stated from the portable side, which is what makes the seam real rather than
/// conventional: a port that omits a piece nobody currently calls fails to
/// compile, instead of silently narrowing the boundary until a second
/// architecture arrives and discovers it. Costs zero bytes and no runtime work.
///
/// It sits in this file rather than in `hal.rs` for one mechanical reason: after
/// the library split, this is the only translation unit in which both the traits
/// and their implementations are nameable.
const _: () = {
    const fn implements_console<T: hal::Console>() {}
    const fn implements_power<T: hal::Power>() {}
    const fn implements_cpu<T: hal::Cpu>() {}
    const fn implements_failstop<T: hal::FailStop>() {}

    implements_console::<crate::arch::BootConsole>();
    implements_power::<crate::arch::PowerControl>();
    implements_cpu::<crate::arch::Processor>();
    implements_failstop::<crate::arch::Failure>();
};
