// SPDX-License-Identifier: GPL-3.0-or-later

//! The portable half of the Skynet kernel, as a library.
//!
//! Everything here is data and logic: no architecture, no device, no address
//! that means anything to a machine. The binary target (`src/main.rs`) holds
//! what must be linked into the image unconditionally — the entry path, the
//! panic handler, and the architecture modules.
//!
//! # Why a library target exists at all
//!
//! `cargo test` cannot run against a `no_main` binary: there is no place to put
//! the harness. RFC-0003 section 6 measured the alternative on this toolchain —
//! a `[lib]` beside the existing `[[bin]]`, with `test = false` on the binary —
//! and that is what this file is the root of. Nothing about the image changes:
//! a `rlib` member the binary does not reference is not pulled into the link,
//! and `--gc-sections` removes what is.
//!
//! `no_std` is lifted only under `cfg(test)`, where the code is compiled for the
//! host and the harness itself needs `std`. The bare-metal build never sees that
//! configuration, so nothing in the image can come to depend on it.

#![cfg_attr(not(test), no_std)]

pub mod fdt;
pub mod hal;
