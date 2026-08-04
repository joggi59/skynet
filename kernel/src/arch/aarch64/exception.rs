// SPDX-License-Identifier: GPL-3.0-or-later

//! Exception vectors, and what the kernel says when something goes wrong.
//!
//! Before this existed, `VBAR_EL1` held whatever reset left there — zero on QEMU
//! virt — so any exception vectored into the middle of `.text` and executed
//! whatever it found. Review measured the result: 10,262,934
//! undefined-instruction exceptions in four seconds, with no console output at
//! all. See RFC-0002.

use core::arch::naked_asm;

use super::fail::Failure;

/// Which of the sixteen entries was taken.
///
/// Four groups of four — Synchronous, IRQ, FIQ, SError — for each of the four
/// origins AArch64 defines. Only the `CurSpx` group can occur at M1: the kernel
/// runs at EL1h so it uses SP_EL1, there is no EL0 until M3, and AArch32 is not
/// supported at all.
///
/// The twelve unreachable entries are populated anyway. An entry that cannot
/// happen is the one you most want to be legible when it does, because its
/// occurrence means something is wrong about an assumption above.
#[derive(Clone, Copy)]
#[repr(u64)]
pub enum Slot {
    CurSp0Sync = 0,
    CurSp0Irq = 1,
    CurSp0Fiq = 2,
    CurSp0Serr = 3,
    CurSpxSync = 4,
    CurSpxIrq = 5,
    CurSpxFiq = 6,
    CurSpxSerr = 7,
    Low64Sync = 8,
    Low64Irq = 9,
    Low64Fiq = 10,
    Low64Serr = 11,
    Low32Sync = 12,
    Low32Irq = 13,
    Low32Fiq = 14,
    Low32Serr = 15,
}

impl Slot {
    /// The name printed in the report.
    pub fn name(self) -> &'static [u8] {
        match self {
            Slot::CurSp0Sync => b"cur_sp0_sync",
            Slot::CurSp0Irq => b"cur_sp0_irq",
            Slot::CurSp0Fiq => b"cur_sp0_fiq",
            Slot::CurSp0Serr => b"cur_sp0_serror",
            Slot::CurSpxSync => b"cur_spx_sync",
            Slot::CurSpxIrq => b"cur_spx_irq",
            Slot::CurSpxFiq => b"cur_spx_fiq",
            Slot::CurSpxSerr => b"cur_spx_serror",
            Slot::Low64Sync => b"lower_a64_sync",
            Slot::Low64Irq => b"lower_a64_irq",
            Slot::Low64Fiq => b"lower_a64_fiq",
            Slot::Low64Serr => b"lower_a64_serror",
            Slot::Low32Sync => b"lower_a32_sync",
            Slot::Low32Irq => b"lower_a32_irq",
            Slot::Low32Fiq => b"lower_a32_fiq",
            Slot::Low32Serr => b"lower_a32_serror",
        }
    }

    /// From the immediate the vector entry loaded. Any value outside 0..=15 is
    /// impossible from the table below, and is reported rather than assumed away.
    fn from_index(i: u64) -> Option<Self> {
        Some(match i {
            0 => Slot::CurSp0Sync,
            1 => Slot::CurSp0Irq,
            2 => Slot::CurSp0Fiq,
            3 => Slot::CurSp0Serr,
            4 => Slot::CurSpxSync,
            5 => Slot::CurSpxIrq,
            6 => Slot::CurSpxFiq,
            7 => Slot::CurSpxSerr,
            8 => Slot::Low64Sync,
            9 => Slot::Low64Irq,
            10 => Slot::Low64Fiq,
            11 => Slot::Low64Serr,
            12 => Slot::Low32Sync,
            13 => Slot::Low32Irq,
            14 => Slot::Low32Fiq,
            15 => Slot::Low32Serr,
            _ => return None,
        })
    }
}

/// Decode `ESR_EL1[31:26]`, the exception class.
///
/// Covers the classes a kernel at M1 can produce. Anything else prints its raw
/// EC rather than being guessed at — a wrong name is worse than a number.
pub fn class_name(esr: u64) -> Option<&'static [u8]> {
    Some(match (esr >> 26) & 0x3f {
        0x00 => b"unknown (often an undefined instruction)".as_slice(),
        0x0e => b"illegal execution state".as_slice(),
        0x15 => b"SVC from AArch64 (no system calls until M3)".as_slice(),
        0x18 => b"trapped MSR/MRS or system instruction".as_slice(),
        0x21 => b"instruction abort, same EL".as_slice(),
        0x22 => b"PC alignment fault".as_slice(),
        0x25 => b"data abort, same EL".as_slice(),
        0x26 => b"SP alignment fault".as_slice(),
        0x2f => b"SError".as_slice(),
        0x3c => b"BRK (debugger breakpoint)".as_slice(),
        _ => return None,
    })
}

/// Is `FAR_EL1` meaningful for this exception class?
///
/// It holds a faulting address for aborts and alignment faults, and whatever was
/// left there otherwise. Printing a stale value as though it meant something is
/// how a debugging session goes wrong for an hour.
pub fn far_is_meaningful(esr: u64) -> bool {
    matches!((esr >> 26) & 0x3f, 0x20 | 0x21 | 0x22 | 0x24 | 0x25 | 0x26)
}

/// Is this exception class asynchronous, so `ELR_EL1` names where execution
/// happened to be rather than what caused it?
///
/// True for SError, which may be raised by something that executed much earlier
/// — RFC-0002, O-2. The report says so rather than letting a reader trust an
/// address that does not point at the cause.
pub fn elr_is_indicative_only(esr: u64) -> bool {
    (esr >> 26) & 0x3f == 0x2f
}

/// Shared handler. Every one of the sixteen entries branches here.
///
/// # Safety
///
/// Reached only from a vector entry, which has already test-and-set the failure
/// flag and written no stack. Does not return: nothing at M1 is resumable — there is no scheduler to
/// reschedule onto, no page table to repair and no process to kill, so a fault
/// is a kernel bug and the honest response is to say what happened and stop.
unsafe extern "C" fn exception_entry(index: u64) -> ! {
    let esr: u64;
    let far: u64;
    let elr: u64;
    // SAFETY: reading three system registers. `nomem` and `nostack` hold — an
    // `mrs` touches neither. These are readable at EL1, which is the only level
    // the kernel runs at (boot.rs parks anywhere else).
    unsafe {
        core::arch::asm!("mrs {}, esr_el1", out(reg) esr, options(nomem, nostack));
        core::arch::asm!("mrs {}, far_el1", out(reg) far, options(nomem, nostack));
        core::arch::asm!("mrs {}, elr_el1", out(reg) elr, options(nomem, nostack));
    }

    // SAFETY: reached only from a vector entry, and this diverges. The entry has
    // already test-and-set the failure flag — before touching any stack — so a
    // fault raised anywhere below this line vectors straight back into the entry,
    // finds the flag set, prints SKYNET_REFAULT and stops. That is the storm
    // review measured at 2,328,136 exceptions, and the earlier guard placed
    // eighteen faultable stores too late to catch it.
    unsafe { Failure::fault_stop(Slot::from_index(index), esr, far, elr) }
}

/// The emergency console path in the vector table builds the UART address with a
/// single `movz … lsl #16`, which can only express a base whose low sixteen bits
/// are zero. True of every PL011 placement this kernel has seen, and a link-time
/// lie the moment it is not.
const _: () = assert!(
    super::platform::UART0_BASE & 0xffff == 0,
    "UART0_BASE has a non-zero low half-word: the vector table's `movz` emergency \
     path cannot form this address, and would write to the wrong one in silence"
);

/// The same emergency path stops the machine with a two-instruction immediate, so
/// the function ID must fit in the low thirty-two bits. Every PSCI ID does; the
/// assertion is here so that a future constant which does not fails the build
/// rather than issuing an HVC with a truncated argument.
const _: () = assert!(
    super::psci::PSCI_SYSTEM_OFF >> 32 == 0,
    "PSCI_SYSTEM_OFF does not fit in 32 bits: the vector table's emergency \
     shutdown would issue a truncated function ID"
);

/// The vector table.
///
/// Sixteen entries of 128 bytes, 2 KiB aligned. Both are architectural
/// requirements: `VBAR_EL1`'s low eleven bits are RES0, so a misaligned write
/// silently lands somewhere else — no link error, no warning, no fault.
///
/// The 2 KiB alignment is enforced by the LINKER, in `link.ld`'s dedicated
/// `.vectors` output section, not by an `.align` directive inside this function.
/// An earlier revision relied on the directive, which aligns the table but not
/// the symbol `VBAR_EL1` is loaded from; deleting it linked cleanly with the
/// table where the hardware would read it as the middle of `_start`.
/// `ci/constitution-check.sh --check vector-alignment` now measures the result.
///
/// Each entry saves the registers it is about to clobber, loads its own index,
/// and branches to the shared handler. Entries are kept to a handful of
/// instructions because 128 bytes is a hard limit the assembler will not warn
/// about — overflow one and the next entry simply starts in the middle of your
/// code.
///
/// # Safety
///
/// Not callable. This is a table of exception entry points, reached only by the
/// processor taking an exception.
#[unsafe(naked)]
#[unsafe(link_section = ".vectors")]
pub(super) unsafe extern "C" fn vector_table() -> ! {
    naked_asm!(
        // Each entry: make room for x0-x30, save the two registers the entry
        // itself uses, save the rest, load the slot index, branch.
        //
        // 256 bytes of stack in a path that is about to stop. RFC-0002 O-1
        // records that a stack-overflow fault pushes further into whatever is
        // below; fixing that properly needs the MMU and belongs with it.
        // The entry sets the failure flag BEFORE it touches anything, and
        // writes no stack at all.
        //
        // An earlier revision pushed x0-x30 first and consulted the guard
        // eighteen faultable stores later. A fault whose cause is a bad stack
        // pointer therefore looped here forever: review measured 2,328,136
        // exceptions in six seconds with no console output. The frame was also
        // write-only — nothing ever read it, though the design said the report
        // did.
        //
        // Ten instructions. Because the entry sets the flag, `fault_stop` must
        // not check it again: checking twice would halt on the first fault and
        // print nothing.
        ".macro ENTRY, idx",
        "  adrp x0, {guard}",
        "  add  x0, x0, #:lo12:{guard}",
        "  ldrb w1, [x0]",
        "  mov  w2, #0xa5",
        "  strb w2, [x0]",
        "  cbnz w1, 20f",
        "  mov  x0, #\\idx",
        "  b    {handler}",
        // Already failing. Say so on the console, then stop.
        //
        // An earlier revision halted here in silence, which made the one failure
        // this table exists to prevent — a fault storm — indistinguishable from a
        // clean shutdown, and made a corrupted guard byte turn the FIRST genuine
        // fault into nothing at all. Sixteen bytes and no stack: the address is
        // built with `movz`, the string is read with a post-indexed `ldrb`, and
        // TXFF is polled so a full FIFO drops nothing.
        "20: movz x1, #{uart_hi}, lsl #16",
        "    adr  x0, 23f",
        "21: ldrb w2, [x0], #1",
        "    cbz  w2, 24f",
        "22: ldr  w3, [x1, #{fr_off}]",
        "    tbnz w3, #{txff_bit}, 22b",
        "    str  w2, [x1, #{dr_off}]",
        "    b    21b",
        "23: .asciz \"SKYNET_REFAULT\\r\\n\"",
        "    .balign 4",
        // Stop the machine, rather than spin. A `wfi` loop here is honest about
        // the state but indistinguishable from a hang, and a hang is what this
        // whole path exists to remove: CI would see a timeout, which is the
        // signal that hid the original storm for two contributions.
        "24: movz x0, #{psci_off_lo}",
        "    movk x0, #{psci_off_hi}, lsl #16",
        "    hvc  #0",
        // Unreachable — PSCI SYSTEM_OFF does not return. If it ever does, the
        // machine is beyond diagnosis and this is the only safe end.
        "25: wfi",
        "    b    25b",
        ".endm",

        ".align 7", "ENTRY 0",
        ".align 7", "ENTRY 1",
        ".align 7", "ENTRY 2",
        ".align 7", "ENTRY 3",
        // Current EL with SP_ELx — the four that can happen at M1.
        ".align 7", "ENTRY 4",
        ".align 7", "ENTRY 5",
        ".align 7", "ENTRY 6",
        ".align 7", "ENTRY 7",
        // Lower EL using AArch64 — unreachable until EL0 exists at M3.
        ".align 7", "ENTRY 8",
        ".align 7", "ENTRY 9",
        ".align 7", "ENTRY 10",
        ".align 7", "ENTRY 11",
        // Lower EL using AArch32 — never; AArch32 is not supported.
        ".align 7", "ENTRY 12",
        ".align 7", "ENTRY 13",
        ".align 7", "ENTRY 14",
        ".align 7", "ENTRY 15",

        handler = sym exception_entry,
        guard    = sym super::fail::IN_FAILURE,
        uart_hi  = const (super::platform::UART0_BASE >> 16),
        dr_off   = const super::pl011::BootConsole::DR,
        fr_off   = const super::pl011::BootConsole::FR,
        txff_bit = const super::pl011::BootConsole::FR_TXFF.trailing_zeros(),
        psci_off_lo = const (super::psci::PSCI_SYSTEM_OFF & 0xffff),
        psci_off_hi = const ((super::psci::PSCI_SYSTEM_OFF >> 16) & 0xffff),
    )
}
