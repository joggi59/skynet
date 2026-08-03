// SPDX-License-Identifier: GPL-3.0-or-later

//! The board's memory map.
//!
//! Architecture and board are different axes of variation. One extra file keeps
//! a QEMU virt address out of the PL011 driver, so porting to a board with the
//! same ISA and a different map touches this file alone.

/// PL011 UART0 on QEMU `virt`.
pub const UART0_BASE: usize = 0x0900_0000;
