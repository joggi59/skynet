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
/// Each entry reads the guard, decides which of four rungs it is on, and
/// branches. Nothing else lives here.
///
/// The emergency paths used to be inlined into the macro, so all sixteen entries
/// carried a private copy of the marker string, the console poll and the PSCI
/// call — 124 bytes of the 128 available, with no room for any of the four
/// defects review then found. They are shared functions in `.text` now, reached
/// by a branch, and an entry is 84 bytes.
///
/// 128 bytes is a hard limit the assembler will not warn about: overflow one and
/// the next entry starts in the middle of your code. `link.ld` asserts it.
///
#[unsafe(naked)]
#[unsafe(link_section = ".vectors")]
pub(super) unsafe extern "C" fn vector_table() -> ! {
    naked_asm!(
        // The whole entry. Read the guard, pick a rung, branch.
        //
        // The rungs are tested MOST DEGRADED FIRST, so that a machine already
        // failing badly cannot be routed back into code that does more work.
        // The guard is only written on the rung that continues — an earlier
        // revision stored it before comparing and could demote a lower rung back
        // to a higher one, which lets two states oscillate forever.
        //
        // x0 holds the guard's address only for this entry's own use. It used to
        // be carried into the shared paths as an implicit argument they stored
        // through — which meant a `#[link_name]` caller chose that pointer, and
        // no such pointer existed before the paths were split out. The advance
        // is issued here now; the paths take nothing.
        // The whole ladder lives HERE, in `.vectors`, and nothing else does.
        //
        // The rungs used to advance the guard with their own first instructions,
        // and those instructions are in `.text` — the region this layout does
        // NOT protect. Review zeroed memory down to 0x40080810, leaving the
        // guard and the whole table verifiably intact, took one fault, and got
        // 3,813,734 exceptions with an empty console: vector entry, first byte
        // of the emergency path, repeat. The bound was true of the ladder and
        // not of the machine, which is the same shape of defect the ladder was
        // built to close, one level down.
        //
        // Every advance is now issued from the entry, which the processor
        // branches to and which sits in the section the layout protects. The
        // functions it branches to hold no state and write nothing.
        ".macro ENTRY, idx",
        "  adr  x0, {guard}",
        "  ldr  w1, [x0]",

        // Rung four, INSIDE the entry. Two instructions, no branch out.
        //
        // It used to be a function in `.failpath`, and the entry branched to it
        // — so an image with `.failpath` destroyed and the guard and all sixteen
        // entries provably intact still stormed: 442,394 exceptions per second,
        // empty console, exit 124. Third time in this file that the thing
        // deciding was protected and the thing executing was not. The end of the
        // ladder cannot depend on any memory but the entry the processor is
        // already executing.
        "  movz w2, #{silent_lo}",
        "  movk w2, #{silent_hi}, lsl #16",
        "  cmp  w1, w2",
        "  b.ne 1f",
        "9: wfi",
        "   b    9b",

        // Rung three: the marker path faulted. Advance to SILENT, stop quietly.
        "1: movz w3, #{stopping_lo}",
        "   movk w3, #{stopping_hi}, lsl #16",
        "   cmp  w1, w3",
        "   b.ne 2f",
        "   str  w2, [x0]",
        "   b    {quiet}",

        // Rung two: the report faulted. Advance to STOPPING, print the marker.
        "2: movz w2, #{failing_lo}",
        "   movk w2, #{failing_hi}, lsl #16",
        "   cmp  w1, w2",
        "   b.ne 3f",
        "   str  w3, [x0]",
        "   b    {emergency}",

        // Rung one: not failing. Claim it and take the full report path.
        "3: str  w2, [x0]",
        "   mov  x0, #\\idx",
        "   b    {handler}",
        ".endm",

        ".align 7", "ENTRY 0",
        ".align 7", "ENTRY 1",
        ".align 7", "ENTRY 2",
        ".align 7", "ENTRY 3",

        ".align 7", "ENTRY 4",
        ".align 7", "ENTRY 5",
        ".align 7", "ENTRY 6",
        ".align 7", "ENTRY 7",

        ".align 7", "ENTRY 8",
        ".align 7", "ENTRY 9",
        ".align 7", "ENTRY 10",
        ".align 7", "ENTRY 11",

        ".align 7", "ENTRY 12",
        ".align 7", "ENTRY 13",
        ".align 7", "ENTRY 14",
        ".align 7", "ENTRY 15",

        handler     = sym exception_entry,
        emergency   = sym emergency_report,
        quiet       = sym quiet_stop,
        guard       = sym super::fail::IN_FAILURE,
        failing_lo  = const (super::fail::FAILING & 0xffff),
        failing_hi  = const (super::fail::FAILING >> 16),
        stopping_lo = const (super::fail::STOPPING & 0xffff),
        stopping_hi = const (super::fail::STOPPING >> 16),
        silent_lo   = const (super::fail::SILENT & 0xffff),
        silent_hi   = const (super::fail::SILENT >> 16),
    )
}

/// Rung two: the report faulted. Print a fixed marker, then stop the machine.
///
/// No stack, no `BootConsole`, no constructor. The address is formed with one
/// `movz`, the string is read out of this function's own body, and the poll on
/// TXFF is BOUNDED — see [`BootConsole::POLL_BUDGET`](super::pl011::BootConsole).
///
/// # Safety
/// Reached by a branch from a vector entry, which has already advanced the
/// ladder to `STOPPING`. Takes nothing and writes no memory but the UART.
///
/// Not "uncallable from Rust" — an earlier version of this comment said that
/// of these three functions, having just withdrawn the identical claim about
/// two others forty lines away. `#[link_name]` reaches any symbol.
#[unsafe(naked)]
#[unsafe(link_section = ".failpath")]
unsafe extern "C" fn emergency_report() -> ! {
    naked_asm!(
        "  movz x1, #{uart_hi}, lsl #16",
        "  adr  x3, 30f",
        // The per-byte budget. A UART that answers and never drains is not
        // bounded by any state machine: no exception is ever taken, so nothing
        // can intervene. Review pointed QEMU virt's PCIe MMIO window at this
        // poll — it reads back with TXFF set forever, and the machine spun with
        // two exceptions on the clock and nothing on the console. A byte that
        // will not go is dropped, and the marker comes out short rather than
        // never.
        "20: ldrb w4, [x3], #1",
        "    cbz  w4, 24f",
        "    movz w5, #{poll_lo}",
        "    movk w5, #{poll_hi}, lsl #16",
        "21: ldr  w6, [x1, #{fr_off}]",
        "    tbz  w6, #{txff_bit}, 23f",
        "    subs w5, w5, #1",
        "    b.ne 21b",
        "    b    20b",
        "23: str  w4, [x1, #{dr_off}]",
        "    b    20b",

        "30: .asciz \"SKYNET_REFAULT\\r\\n\"",
        "    .balign 4",

        "24: b    {quiet}",

        quiet       = sym quiet_stop,
        uart_hi     = const (super::platform::UART0_BASE >> 16),
        dr_off      = const super::pl011::BootConsole::DR,
        fr_off      = const super::pl011::BootConsole::FR,
        txff_bit    = const super::pl011::BootConsole::FR_TXFF.trailing_zeros(),
        poll_lo     = const (super::pl011::BootConsole::POLL_BUDGET & 0xffff),
        poll_hi     = const (super::pl011::BootConsole::POLL_BUDGET >> 16),
    )
}

/// Rung three: stop the machine without touching a device.
///
/// Reached when the marker path itself faulted, and as the ordinary end of that
/// path. Claims rung four first, so a fault in the `hvc` lands on
/// [`terminal_stop`] instead of trying the same `hvc` again forever — which is
/// what a three-rung ladder did, and why there are four.
///
/// # Safety
/// Reached from a vector entry or from `emergency_report`. Takes nothing, and
/// advances nothing — the entry did that before branching here. An earlier
/// version of this comment said the function claimed a rung.
///
/// Not "uncallable from Rust" — an earlier version of this comment said that
/// of these three functions, having just withdrawn the identical claim about
/// two others forty lines away. `#[link_name]` reaches any symbol.
#[unsafe(naked)]
#[unsafe(link_section = ".failpath")]
unsafe extern "C" fn quiet_stop() -> ! {
    naked_asm!(
        "  movz x0, #{psci_off_lo}",
        "  movk x0, #{psci_off_hi}, lsl #16",
        "  hvc  #0",
        // PSCI SYSTEM_OFF does not return. If it ever does, stop here rather
        // than branch anywhere — there is nothing left that can be trusted.
        "1: wfi",
        "   b    1b",
        psci_off_lo  = const (super::psci::PSCI_SYSTEM_OFF & 0xffff),
        psci_off_hi  = const ((super::psci::PSCI_SYSTEM_OFF >> 16) & 0xffff),
    )
}

