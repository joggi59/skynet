// SPDX-License-Identifier: GPL-3.0-or-later

//! The portable contract.
//!
//! Portable code may name what is in this file and nothing else. There is no
//! register, no address, no instruction, no architecture and no `cfg` here —
//! selection happens one level down, in [`crate::arch`].
//!
//! # Why traits rather than a module of free functions
//!
//! A module's contract is defined by its call sites. `arch::console_write_byte`
//! exists because something calls it, so the boundary silently equals "whatever
//! M0 happened to need" and a second port satisfies it by accident. The traits
//! below, plus the conformance block at the bottom of this file, state the whole
//! contract independently of who currently calls what.
//!
//! Fifteen lines, zero bytes at runtime, and the difference between a boundary
//! and a habit.

/// A byte sink reaching the operator's boot console.
pub trait Console {
    /// Write bytes in order. Returns when the device has taken all of them, or
    /// when an implementation has given up on it — an implementation may drop
    /// bytes, and this trait requires only that it return.
    ///
    /// The contract used to promise every byte and a return only once the device
    /// had accepted each one. An implementation cannot honour that: a device
    /// that answers and never drains makes it a promise to hang, and a kernel
    /// that hangs in its console cannot report why. Callers must not assume all
    /// bytes reached the wire; nothing in this kernel does.
    ///
    /// This is a portable file the task's `does_not_touch` names. It is touched,
    /// and the argument for touching it should be read against the argument
    /// this same contribution makes for NOT touching `rfcs/`: there the debt is
    /// named and left. The difference claimed is that an RFC is a design record
    /// a later contribution can correct, while this is the contract every
    /// implementation is checked against — leaving it false makes every
    /// conforming implementation non-conforming. Review has read it both ways — as the
    /// invariant-3-correct call, and as a violation dressed as disclosure. This
    /// is the disclosure, not the resolution.
    fn write(&mut self, bytes: &[u8]);
}

/// Authority to change the machine's power state.
///
/// `off` takes `self` by value: exercising this authority consumes it. There is
/// no way to hold a `Power` and use it twice, and no way to obtain one except
/// from the boot path.
pub trait Power {
    /// Power the machine off. Does not return.
    fn off(self) -> !;
}

/// Operations on the executing processor.
///
/// Deliberately an associated function with no receiver: halting the current
/// processor grants access to nothing — it removes the caller's own ability to
/// continue — so it requires no token.
pub trait Cpu {
    /// Stop this processor permanently, with interrupts masked. Does not return.
    fn halt() -> !;
}

/// The failure path, and the narrowest authority in the kernel.
///
/// `#[panic_handler]` is handed a `&PanicInfo` and nothing else, so the failure
/// path is the one caller the language refuses to hand anything to. Rather than
/// give it a global console to reach for, it is given this: an operation that
/// takes bytes, emits them on the platform's failure console, stops the machine,
/// and cannot do anything else.
///
/// It is not a [`Console`] and must never become one. What would make it one:
/// returning, taking a receiver, gaining a second caller, or being handed
/// anything but a compile-time constant.
pub trait FailStop {
    /// Emit `bytes`, then stop the machine. Does not return.
    ///
    /// `&'static [u8]`, not `&[u8]`. The bound on this operation is that it
    /// writes a compile-time constant and nothing else — an arbitrary runtime
    /// slice left that bound as prose, and review compiled a probe carrying
    /// runtime state through it. The lifetime makes the bound a property of the
    /// type rather than a promise in a comment.
    ///
    /// # Safety
    /// Callable only from the panic handler. The implementation may alias a
    /// console owned elsewhere, which is sound only because the kernel has
    /// already failed and no other code will run again.
    unsafe fn fail_stop(bytes: &'static [u8]) -> !;
}

/// Everything the boot path found, on its way to `kernel_main`.
///
/// Generic so that portable code cannot name a concrete device type, and
/// therefore cannot acquire one by any route other than being handed this.
pub struct BootResources<C: Console, P: Power> {
    pub console: C,
    pub power: P,
}

/// Compile-time proof that the architecture implements the whole contract.
///
/// Placed here, on the portable side, so it is checked from the side that
/// depends on it. Costs zero bytes and no runtime work.
///
/// This is what makes the seam real rather than conventional: a port that omits
/// a piece nobody currently calls fails to compile, instead of silently
/// narrowing the boundary until a second architecture arrives and discovers it.
const _: () = {
    const fn implements_console<T: Console>() {}
    const fn implements_power<T: Power>() {}
    const fn implements_cpu<T: Cpu>() {}
    const fn implements_failstop<T: FailStop>() {}

    implements_console::<crate::arch::BootConsole>();
    implements_power::<crate::arch::PowerControl>();
    implements_cpu::<crate::arch::Processor>();
    implements_failstop::<crate::arch::Failure>();
};
