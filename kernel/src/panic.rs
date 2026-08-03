// SPDX-License-Identifier: GPL-3.0-or-later

//! The failure path.

use crate::arch::Failure;
use crate::hal::FailStop;

/// The bytes that mean "this kernel failed".
///
/// Defined by `PANIC_MARKER` in `ci/lib.sh`; `ci/boot-test.sh` fails the run if
/// it appears. A compile-time constant and nothing else: no formatting, no
/// `PanicInfo`, no private state on the wire.
const PANIC_MARKER: &[u8] = b"SKYNET_PANIC\n";

/// Panic handler.
///
/// This is the one place the language forces a global entry point: it is called
/// with a `&PanicInfo` and nothing else, so it cannot be handed a console. The
/// design gives it the narrowest authority that satisfies the contract rather
/// than the most convenient one — see [`crate::hal::FailStop`].
///
/// # Why it announces itself rather than halting silently
///
/// A panic that halts is caught by the boot test's timeout: correctly, but
/// thirty seconds later and with nothing in the log to read. A panic that shuts
/// down cleanly exits 0 and is indistinguishable from success to a test checking
/// only the exit code. With the marker, a panic before the boot marker fails on
/// the missing boot marker and a panic after it fails on this one — fail-closed
/// in both directions, in milliseconds, with a legible reason.
///
/// # Why it does not print the panic message
///
/// `_info` is ignored deliberately. Formatting it would pull `core::fmt` into
/// the image, and it would put whatever a future panic string happens to hold
/// onto an outward channel. A compile-time constant keeps invariant 5 exactly
/// true and the image small. Richer diagnostics need a design, not a `write!` —
/// RFC-0001, O-4.
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    // SAFETY: this is the panic handler and it never returns, so no other owner
    // of the console or of PSCI will run again. Aliasing them here cannot race
    // with anything. That is the precondition `FailStop::fail_stop` documents,
    // and this is its only call site.
    unsafe { Failure::fail_stop(PANIC_MARKER) }
}
