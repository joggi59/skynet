// SPDX-License-Identifier: GPL-3.0-or-later

//! Entry path: from the platform's first instruction to portable code.

use core::arch::naked_asm;

use crate::hal::BootResources;

use super::pl011::BootConsole;
use super::platform;
use super::psci::PowerControl;

/// Kernel entry point, and the first 64 bytes of it are the image header.
///
/// Entry is at EL1: `virt` defaults to `virtualization=off`, so no EL2 exists.
///
/// **The same binary boots two ways, and `x0` differs between them.** Booted as
/// an ELF — which is what `ci/boot-test.sh` does today — QEMU treats the image
/// as non-Linux, writes no bootloader stub, places no device tree, and resets
/// every general-purpose register: `x0` is zero. Booted as a flat Linux-format
/// `Image`, the loader places the blob and `x0` holds its physical address,
/// which moves with the machine's RAM size. RFC-0003 section 1a measured six
/// different addresses from one binary, and RFC-0001's O-2 is answered by
/// changing the artefact rather than the contract.
///
/// Nothing here reads `x0`, or may: validating it would fail the ELF boot, where
/// zero is correct. `_start` touches only `x9`–`x12` and ends in a tail branch,
/// so whatever the loader left in `x0` reaches `boot_rust` untouched.
///
/// # Safety
///
/// Not callable from Rust. This is the reset entry point: it runs with no stack,
/// an unzeroed `.bss`, and no guarantee about which exception level it was
/// entered at. Everything it needs, it establishes.
#[unsafe(naked)]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".text.boot")]
unsafe extern "C" fn _start() -> ! {
    naked_asm!(
        // ─── the aarch64 Linux boot protocol image header ───────────────────
        //
        // Sixty-four bytes of data at the front of a function, the way Linux's
        // head.S does it: `code0` is a real branch over the rest, so the header
        // and the entry symbol are the same address. `nm` still places _start at
        // KERNEL_BASE and an ELF boot, which jumps to e_entry and never reads a
        // header, executes the branch and continues below.
        //
        // The linker script pins this section to KERNEL_BASE, which is offset 0
        // of the flat image — the only place a loader looks for these bytes.
        "b    9f",              // code0: branch past the header
        ".word 0",              // code1: unused, second half of code0's slot
        ".quad 0x80000",        // text_offset: KERNEL_BASE minus the RAM base.
                                // The one number this file adds, and it is a
                                // property of the link, not of a board.
        ".quad __image_size",   // image_size: __kernel_end - KERNEL_BASE, from
                                // the linker script. Zero here makes the loader
                                // ignore text_offset and place the image where
                                // it likes, so it is a symbol and not a literal.
        ".quad 0",              // flags, the value RFC-0003 section 1 specifies.
                                // Bit 0 clear: little-endian. Bits 1-2 clear:
                                // page size unspecified — Linux's own head.S
                                // encodes 4 KiB as 1 here, and this kernel says
                                // nothing because it has no MMU to say it about.
                                // Bit 3 clear: place the image at text_offset
                                // from the base of usable RAM, not anywhere.
        ".quad 0",              // res2
        ".quad 0",              // res3
        ".quad 0",              // res4
        ".ascii \"ARM\\x64\"",  // magic, at offset 56. The loader checks these
                                // four bytes and nothing else identifies the
                                // format.
        ".word 0",              // res5: PE/COFF header offset. There is no EFI
                                // stub, so zero.
        "9:",

        // Mask D, A, I and F before anything else.
        "msr  daifset, #0xf",

        // Zero .bss. Done in assembly rather than Rust: the Rust form needs
        // `__bss_start` and `__bss_end` as extern statics, which are immutable
        // as `static` (writing through them is not defensible) and would be the
        // only `static mut` in the kernel otherwise. Seven instructions removes
        // the question. The linker script guarantees both bounds are 8-byte
        // aligned, so the loop cannot overrun.
        //
        // The kernel does not rely on the loader zeroing anything: QEMU happens
        // to zero a PT_LOAD segment's memsz/filesz gap, but no hardware loader
        // promises to.
        "adrp x10, __bss_start",
        "add  x10, x10, #:lo12:__bss_start",
        "adrp x11, __bss_end",
        "add  x11, x11, #:lo12:__bss_end",
        "0:  cmp  x10, x11",
        "    b.hs 1f",
        "    str  xzr, [x10], #8",
        "    b    0b",
        "1:  adrp x12, __stack_top",
        "    add  x12, x12, #:lo12:__stack_top",

        // EL1 is the only supported entry level. Anything else parks.
        //
        // An earlier revision dropped from EL2 to EL1 for robustness. Review
        // refused it as a blocking finding, correctly: QEMU sets
        // the PSCI conduit to SMC when virtualization=on and disables an HVC
        // conduit whenever the boot EL is 2 or above, so a kernel that dropped
        // from EL2 would boot and then be unable to shut down — its hvc traps to
        // an uninitialised VBAR_EL2. The drop falsified the precondition
        // PowerControl documents, in the same patch that established it.
        // RFC-0001, O-3 (closed).
        "mrs  x9, CurrentEL",
        "lsr  x9, x9, #2",
        "cmp  x9, #1",
        "b.ne 4f",

        // SCTLR_EL1 = 0x30d0_0800: every bit RES1 in ARMv8.0 — 11 (EOS),
        // 20 (TSCXT), 22 (EIS), 23 (SPAN), 28 (nTLSMD), 29 (LSMAOE) — with
        // M, C, I, A, SA and SA0 clear: MMU off, caches off, little-endian,
        // alignment and stack-alignment checks off. On ARMv8.1+ each of those
        // bits set to 1 selects the ARMv8.0 behaviour, so the value stays
        // correct on newer cores.
        //
        // The kernel requires the MMU and caches to be off at entry, as the
        // arm64 Linux boot protocol does. M0 does not attempt to turn a running
        // MMU off: doing so while executing changes the translation of the
        // program counter.
        "movz x9, #0x0800",
        "movk x9, #0x30d0, lsl #16",
        "msr  sctlr_el1, x9",

        // Take control of faults before running any Rust.
        //
        // VBAR_EL1 holds whatever reset left there — zero on QEMU virt — so
        // until this write, any exception vectors into the middle of .text and
        // executes what it finds. Review measured that: 10,262,934
        // undefined-instruction exceptions in four seconds, silently.
        //
        // The window between reset and here cannot be closed without firmware,
        // which M0's non-goals exclude. It is a handful of instructions long.
        "adrp x9, {vectors}",
        "add  x9, x9, #:lo12:{vectors}",
        "msr  vbar_el1, x9",

        // Writing SCTLR_EL1 and VBAR_EL1 are context-changing operations;
        // without the barrier the processor may already have fetched under the
        // old configuration. One isb covers both.
        "isb",

        "mov  sp, x12",
        "b    {rust}",

        // Entered at EL2, EL3, or anything else: park in the same wfi loop the
        // failure path uses. Untested robustness code in a privileged path is
        // not robustness.
        "4:  wfi",
        "    b    4b",

        rust = sym boot_rust,
        vectors = sym super::exception::vector_table,
    )
}

/// Second stage of boot: still architecture-specific, now in Rust.
///
/// Mints the platform's device tokens and hands them to the portable kernel.
/// No `take()`, no `Once`, no atomic flag: uniqueness is a property of the
/// control flow, which has exactly one path here, and not of a runtime guard
/// that would itself be a global.
///
/// `_dtb` is `x0` as the loader left it: the physical address of a device tree
/// blob when this binary was booted as a flat `Image`, and zero when it was
/// booted as an ELF. **It is carried and dropped.** Nothing dereferences it,
/// stores it, compares it against a constant or passes it on, and nothing may
/// until `ci/` boots the flat image — a kernel that rejected `x0 == 0` here
/// would fail the gate's ELF boot, where zero is the correct value. The
/// underscore is that state, not a suppressed warning; the parameter exists now
/// so the ABI stops changing once it has a reader. RFC-0003 section 8, step 1.
///
/// A `u64` and not a pointer: no address arrives in Rust's type system before
/// anything is entitled to follow it.
///
/// # Safety
///
/// Reached only from `_start`, exactly once, at EL1, with interrupts masked, a
/// valid stack and a zeroed `.bss`. It mints device tokens, which is sound only
/// because there is exactly one call site.
unsafe extern "C" fn boot_rust(_dtb: u64) -> ! {
    let resources = BootResources {
        // SAFETY: single call site, reached once, before any other code has
        // touched the PL011. `UART0_BASE` is the platform console's MMIO base.
        console: unsafe { BootConsole::new(platform::UART0_BASE) },
        // SAFETY: single call site, reached once, and `_start` has already
        // established that we are at EL1 — where QEMU virt's PSCI conduit is
        // HVC. Any other exception level parked and never reached here.
        power: unsafe { PowerControl::new() },
    };
    crate::kernel_main(resources)
}
