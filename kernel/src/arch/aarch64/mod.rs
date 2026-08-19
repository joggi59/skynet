// SPDX-License-Identifier: GPL-3.0-or-later

//! aarch64 platform support for QEMU `virt`.
//!
//! Everything in this directory is machine-specific by construction. It is the
//! only place in the kernel permitted to name a register, an address or an
//! instruction (constitutional invariant 6) — and the linker script lives here
//! for the same reason, even though the mechanical check cannot see it.

mod boot;
mod cpu;
mod exception;
mod fail;
mod hex;
mod pl011;
mod platform;
mod psci;

pub use cpu::Processor;
pub use fail::Failure;
pub use pl011::BootConsole;
pub use psci::PowerControl;

/// The unit of physical memory this port hands out: 4 KiB.
///
/// Here rather than in `platform.rs` because it is a property of the
/// architecture and not of the board — every aarch64 machine this kernel could
/// run on offers the same choice of translation granules, and a board with a
/// different memory map does not get a different one.
///
/// **It must equal the translation granule the MMU design chooses.** RFC-0003
/// section 7 says so, and says why it is stated here as a warning rather than
/// enforced: "two constants that must agree, in two RFCs, is exactly how they
/// come to disagree". So there is exactly one frame-size constant in this
/// kernel — this one — and the compile-time assertion that it equals the
/// granule belongs in the RFC that introduces the granule, which does not exist
/// yet. Portable code never sees it: it travels as a parameter to
/// `frames::FrameAllocator::new`, so nothing above `arch/` can come to depend
/// on its value.
///
/// 4 KiB and not 16 or 64: it is the smallest granule ARMv8 defines, every
/// implementation supports it, and the smallest unit is the one that wastes
/// least on a machine with 8 MiB of RAM — which is the profile this kernel is
/// measured against.
pub const FRAME_SIZE: usize = 4096;
