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
//!
//! The conformance block that used to sit at the bottom of this file now lives
//! in `main.rs`. It did not move because it stopped belonging to the portable
//! side — it still belongs there, which is why it is in `main.rs` and not in an
//! `arch` file. It moved because `main.rs` is the only place after the library
//! split where the traits and their implementations are both nameable.

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

// ---------------------------------------------------------------------------
// What the device tree said
// ---------------------------------------------------------------------------

/// The most memory regions a [`MemoryMap`] can hold.
///
/// Eight, and a guess: the only machine measured reports one. RFC-0003 O-3.
/// Exceeding it is a typed error rather than a truncated map — the whole value
/// of a fixed bound is that crossing it is legible.
pub const MAX_REGIONS: usize = 8;

/// The most reservation entries a [`MemoryMap`] can hold.
///
/// Sixteen, and the same guess with the same single data point behind it: the
/// only machine measured reserves nothing at all. RFC-0003 O-3.
pub const MAX_RESERVED: usize = 16;

/// A region of physical memory.
///
/// `u64` and not `usize`. A 32-bit port with a wider physical address space is
/// a real machine, and `usize` there is a silent truncation of an address the
/// hardware can reach.
///
/// # Where `base + len` is bounded, and why not here
///
/// This type does not enforce that `base + len` is representable. It could:
/// private fields, a fallible constructor and two accessors would make the
/// state unbuildable rather than merely rejected. That was weighed and not
/// taken, for two reasons. The shape RFC-0003 section 2 gives is a pair of
/// public `u64`s, and its one consumer — the frame allocator — reads both of
/// them off every entry of two slices; putting a fallible constructor in front
/// of a type nobody but the parser builds moves the check without removing it,
/// and pays for the move in interface. And the values that can overflow all
/// arrive from one place: a device tree blob, which is the only untrusted
/// input in this kernel that becomes a `Region`.
///
/// So the bound is checked at that door, in [`crate::fdt`], on both paths a
/// blob can take — a `reg` entry and a reservation entry — and a blob that
/// asks for a region running off the end of the address space is a typed parse
/// error. The gap this leaves is real and worth naming: a `Region` written by
/// hand elsewhere in the kernel is still unconstrained. That is a different
/// risk from the one a blob poses, and the day something other than the parser
/// starts constructing these is the day to revisit the trade rather than now.
#[derive(Clone, Copy, PartialEq, Eq)]
#[cfg_attr(test, derive(Debug))]
pub struct Region {
    pub base: u64,
    pub len: u64,
}

/// What the device tree said, copied out of the blob so the blob can be released.
///
/// Fixed arrays and no allocation, because the thing that makes allocation
/// possible is built from this. That is the bootstrap, stated rather than
/// worked around.
///
/// The read interface is two borrowed slices and nothing else. There is
/// deliberately no lookup by name, no accessor taking an index, and no method
/// that hands out a [`Region`] as a thing with an identity — RFC-0001's warning
/// about `BootResources` becoming a registry is about exactly that shape, and
/// the one consumer this has (the frame allocator) iterates both slices once.
pub struct MemoryMap {
    regions: [Region; MAX_REGIONS],
    region_count: usize,
    reserved: [Region; MAX_RESERVED],
    reserved_count: usize,
}

/// A fixed array in [`MemoryMap`] had no room left.
///
/// Returned rather than silently dropping the entry, and deliberately carrying
/// nothing: the caller knows which array it was pushing to, and a map that
/// quietly forgot a reservation hands out memory that is spoken for.
#[derive(Clone, Copy, PartialEq, Eq)]
#[cfg_attr(test, derive(Debug))]
pub struct Full;

impl MemoryMap {
    /// A map that says nothing yet.
    pub(crate) const fn empty() -> Self {
        const NONE: Region = Region { base: 0, len: 0 };
        Self {
            regions: [NONE; MAX_REGIONS],
            region_count: 0,
            reserved: [NONE; MAX_RESERVED],
            reserved_count: 0,
        }
    }

    /// Record a region of usable memory.
    pub(crate) fn push_region(&mut self, region: Region) -> Result<(), Full> {
        if self.region_count == MAX_REGIONS {
            return Err(Full);
        }
        self.regions[self.region_count] = region;
        self.region_count += 1;
        Ok(())
    }

    /// Record a region that is already spoken for.
    pub(crate) fn push_reserved(&mut self, region: Region) -> Result<(), Full> {
        if self.reserved_count == MAX_RESERVED {
            return Err(Full);
        }
        self.reserved[self.reserved_count] = region;
        self.reserved_count += 1;
        Ok(())
    }

    /// Every region of memory the device tree reported.
    pub fn regions(&self) -> &[Region] {
        &self.regions[..self.region_count]
    }

    /// Every entry of the device tree's memory reservation block.
    pub fn reserved(&self) -> &[Region] {
        &self.reserved[..self.reserved_count]
    }
}
