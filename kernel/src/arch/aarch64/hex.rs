// SPDX-License-Identifier: GPL-3.0-or-later

//! Fixed-width hexadecimal, without `core::fmt`.
//!
//! `core::fmt` is kilobytes against a 192 KiB budget that must also fit an MMU,
//! page tables and an allocator later in this milestone. This is forty lines and
//! costs a sixteen-byte table.
//!
//! Everything here is written so it cannot itself fault. That is not a style
//! preference: this code runs *inside* the fault handler, and `overflow-checks`
//! is on in release, so an overflow here would take the panic path from inside
//! the fault path. There is no indexing that can go out of bounds and no
//! arithmetic that can overflow — the shift count is bounded by construction and
//! the nibble is masked to four bits before it reaches the table.

const DIGITS: &[u8; 16] = b"0123456789abcdef";

/// Write `value` as exactly `nybbles` hex digits, most significant first.
///
/// `nybbles` is clamped to 16, so the shift below can never reach 64 — a shift
/// of 64 or more on a `u64` is undefined in the abstract machine and a silent
/// wrap on aarch64, which is exactly the class of thing that must not happen
/// here.
pub fn write_hex(out: &mut impl FnMut(u8), value: u64, nybbles: u8) {
    let n = if nybbles > 16 { 16 } else { nybbles };
    let mut i = n;
    while i > 0 {
        i -= 1;
        // i <= 15, so the shift is at most 60. No overflow is reachable.
        let nibble = ((value >> (i * 4)) & 0xf) as usize;
        // nibble is masked to 0..=15, so the index is always in bounds.
        out(DIGITS[nibble]);
    }
}

/// `0x` followed by eight digits. For 32-bit registers such as `ESR_EL1`.
pub fn write_u32(out: &mut impl FnMut(u8), value: u64) {
    out(b'0');
    out(b'x');
    write_hex(out, value, 8);
}

/// `0x` followed by sixteen digits. For addresses.
pub fn write_u64(out: &mut impl FnMut(u8), value: u64) {
    out(b'0');
    out(b'x');
    write_hex(out, value, 16);
}
