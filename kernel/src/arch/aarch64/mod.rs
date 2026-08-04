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
