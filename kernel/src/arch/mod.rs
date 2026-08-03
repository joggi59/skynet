// SPDX-License-Identifier: GPL-3.0-or-later

//! Architecture selection.
//!
//! This module and `build.rs` are the only two places in the kernel that may
//! name an architecture. Everything below this line is machine-specific by
//! construction; everything above it is portable by construction. That split is
//! constitutional invariant 6, and `ci/constitution-check.sh --check
//! hal-boundary` enforces the Rust half of it mechanically.
//!
//! When a second architecture arrives (M10) it is added here and nowhere else.
//! If it turns out to need a change above this line, the boundary had already
//! leaked and the port is what discovered it.

#[cfg(target_arch = "aarch64")]
mod aarch64;

#[cfg(target_arch = "aarch64")]
pub use aarch64::{BootConsole, Failure, PowerControl, Processor};

#[cfg(not(target_arch = "aarch64"))]
compile_error!(
    "no HAL implementation for this target architecture; \
     add one under kernel/src/arch/ and a linker script in build.rs"
);
