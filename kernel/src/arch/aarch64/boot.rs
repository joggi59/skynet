// SPDX-License-Identifier: GPL-3.0-or-later

//! Entry path: from the platform's first instruction to portable code.

use core::arch::naked_asm;

use crate::hal::{BootResources, Console, MemoryMap, Power};

// `skynet_kernel::fdt` and not `crate::fdt`: `main.rs` binds only `hal` at the
// crate root, and `main.rs` is not this task's to edit. Both names reach the
// same library module.
use skynet_kernel::fdt;

use super::pl011::BootConsole;
use super::platform;
use super::psci::PowerControl;

/// Kernel entry point, and the first 64 bytes of it are the image header.
///
/// Entry is at EL1: `virt` defaults to `virtualization=off`, so no EL2 exists.
///
/// **The same binary boots two ways, and `x0` differs between them.** Booted as
/// an ELF — which `ci/boot-test.sh` no longer does — QEMU treats the image as
/// non-Linux, writes no bootloader stub, places no device tree, and resets every
/// general-purpose register: `x0` is zero, and `boot_rust` now reports that as
/// its own failure rather than ignoring it. Booted as a flat Linux-format
/// `Image`, the loader places the blob and `x0` holds its physical address,
/// which moves with the machine's RAM size. RFC-0003 section 1a measured six
/// different addresses from one binary, and RFC-0001's O-2 is answered by
/// changing the artefact rather than the contract.
///
/// Nothing here reads `x0`, and nothing here should: this is the one register
/// the kernel did not choose, and every decision taken about it belongs where it
/// can be made in Rust with a failure path to report on. `_start` touches only
/// `x9`–`x12` and ends in a tail branch, so whatever the loader left in `x0`
/// reaches `boot_rust` untouched.
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
/// `dtb` is `x0` as the loader left it: the physical address of a device tree
/// blob when this binary was booted as a flat `Image`, and zero when it was
/// booted as an ELF. It is the one input this kernel did not choose, and until
/// [`blob_at`] has finished with it, it is an integer and not an address — which
/// is why the parameter is a `u64`. Nothing in Rust's type system is entitled to
/// follow it before then.
///
/// The order is RFC-0003 section 5's and no other: mint the two devices, turn
/// `x0` into a bounded window of bytes, parse it. A failure anywhere in that
/// sequence writes `SKYNET_MEM_FAIL` and one compile-time reason, and powers the
/// machine off — before the boot marker, so the gate fails on the absent marker
/// while the console says why.
///
/// # Safety
///
/// Reached only from `_start`, exactly once, at EL1, with interrupts masked, a
/// valid stack and a zeroed `.bss`. It mints device tokens, which is sound only
/// because there is exactly one call site.
unsafe extern "C" fn boot_rust(dtb: u64) -> ! {
    let resources = BootResources {
        // SAFETY: single call site, reached once, before any other code has
        // touched the PL011. `UART0_BASE` is the platform console's MMIO base.
        console: unsafe { BootConsole::new(platform::UART0_BASE) },
        // SAFETY: single call site, reached once, and `_start` has already
        // established that we are at EL1 — where QEMU virt's PSCI conduit is
        // HVC. Any other exception level parked and never reached here.
        power: unsafe { PowerControl::new() },
    };

    // Parsed and dropped. The allocator that reads it is T-0007's, where
    // RFC-0003 section 5 puts the third field of `BootResources` and where
    // RFC-0001's argument about that struct becoming a registry is re-checked.
    // Binding it rather than discarding it is the honest shape: the value
    // exists, it has no consumer yet, and no `#[allow]` or placeholder reader
    // pretends otherwise.
    //
    // One consequence worth stating, because it is invisible: with the map
    // unobserved, nothing but the error paths of `fdt::parse` is load-bearing in
    // this build, and the optimiser is entitled to discard the work of filling a
    // value nobody reads. What the failure path reports is unaffected — every
    // check still runs, because its result is observed here.
    let _map: MemoryMap = match memory_map(dtb) {
        Ok(map) => map,
        Err(reason) => mem_fail(resources, reason),
    };

    crate::kernel_main(resources)
}

/// One of a fixed set of compile-time strings. Never a value read from the blob.
///
/// The same `&'static [u8]` the panic path takes, for the same reason: invariant
/// 5 is about what the kernel can be made to say, and a type that only accepts
/// program text cannot be handed a fact about the operator's machine. CI does
/// not check this until M6; the bound is what carries it until then.
type Reason = &'static [u8];

/// `x0` was zero. Its own reason, and deliberately not "bad magic".
///
/// It means the kernel was booted as an ELF — QEMU places no blob and zeroes
/// every register — which is a misconfiguration in `ci/`, not a corrupt tree.
/// Reporting it as bad magic sends whoever reads the console to the wrong file.
const NO_BLOB: Reason = b"x0 was zero: booted as an ELF, no device tree was placed";

/// The blob's address is not 8-byte aligned, which the boot protocol requires.
///
/// It is also load-bearing here rather than pedantry: the reservation block is
/// `u64` pairs, the MMU is off so every access is Device-nGnRnE, and the target
/// is built `+strict-align`.
const MISALIGNED: Reason = b"device tree address is not 8-byte aligned";

/// `x0`, or `x0 + totalsize`, does not fit in a 64-bit address.
///
/// Reached only from a value no loader would produce, and reported rather than
/// wrapped: `overflow-checks = true`, so an unchecked add here would be a panic,
/// and `SKYNET_PANIC` is the marker that means the kernel has a bug rather than
/// that its input was garbage.
const ADDRESS_SPACE: Reason = b"device tree window runs past the end of the address space";

/// `totalsize` is above [`fdt::MAX_BLOB_LEN`].
///
/// Checked here as well as in the parser because it is the bound on the window
/// this file constructs, so it has to hold before the slice exists rather than
/// after. The parser's own [`fdt::Error::TotalSizeTooLarge`] maps to this same
/// string: it is the same diagnosis, and the second check is defence in depth.
const TOO_LARGE: Reason = b"device tree totalsize is above the blob size bound";

/// Byte offset of `totalsize` in `fdt_header`.
///
/// The whole of what this file knows about the device tree format, and it is
/// here under protest: the boot path cannot ask the parser for the length of a
/// window that does not exist yet, so the one field that sizes the window has to
/// be read before the portable code takes over. Everything else about the
/// header — magic, the version pair, every offset and every extent — is checked
/// by `fdt::parse` against the slice, before it reads a byte of the structure
/// block. Devicetree Specification v0.4 section 5.2 puts `totalsize` second.
const TOTALSIZE_OFFSET: u64 = 4;

/// The width of that field. It is a big-endian `u32`, like every header field.
const TOTALSIZE_LEN: u64 = 4;

/// Turn `x0` into a memory map, or into the reason it could not become one.
fn memory_map(dtb: u64) -> Result<MemoryMap, Reason> {
    let blob = blob_at(dtb)?;
    fdt::parse(blob).map_err(reason_for)
}

/// Turn a raw physical address into a bounded window of bytes.
///
/// **This is where the kernel first trusts something it did not write**, and the
/// order below is the whole of the argument for why that is survivable.
///
/// The parser is hardened against hostile bytes, but every test that proved it
/// so handed it a slice that already existed. Here the slice has to be built,
/// and its length comes from a field inside the very blob whose validity is in
/// question. So the sequence is: reject the addresses that cannot be followed at
/// all; read exactly the four bytes that give the length, and nothing else;
/// bound that length against a compile-time ceiling before it is used as a
/// length; construct the window once; hand it to the parser, which re-checks the
/// header it can now see in full.
///
/// Two properties are worth naming because they are what make the double read of
/// `totalsize` — once here, once in `fdt::parse` — harmless rather than a
/// time-of-check hazard:
///
///   - the window's length is fixed by the read taken *here*, so nothing the
///     second read returns can widen it;
///   - the parser compares its own reading of `totalsize` against the slice it
///     was given, so a second reading that is larger is
///     [`fdt::Error::TotalSizeBeyondBlob`] and not an over-read.
///
/// What cannot be checked, and is not: whether `[dtb, dtb + totalsize)` is
/// memory at all. Knowing where RAM is, is what the blob is for, and a range
/// check against a constant would be the fallback constant RFC-0003 section 1
/// refuses, wearing a different hat. With the MMU off, an address that is not
/// memory raises a synchronous external abort, which the vector table reports as
/// `SKYNET_FAULT` and shuts down cleanly — measured in RFC-0003 section 1a, and
/// the fault path RFC-0002 built doing the job it was built for.
fn blob_at(dtb: u64) -> Result<&'static [u8], Reason> {
    if dtb == 0 {
        return Err(NO_BLOB);
    }
    if !dtb.is_multiple_of(8) {
        return Err(MISALIGNED);
    }

    // The only bytes read before the window exists: `[dtb + 4, dtb + 8)`. Both
    // ends are checked against the address space first, because
    // `overflow-checks = true` turns the alternative into a panic.
    let field = match dtb.checked_add(TOTALSIZE_OFFSET) {
        Some(field) => field,
        None => return Err(ADDRESS_SPACE),
    };
    if field.checked_add(TOTALSIZE_LEN).is_none() {
        return Err(ADDRESS_SPACE);
    }

    // SAFETY: `field` is `dtb + 4`, which is 4-byte aligned because `dtb` was
    // just proved to be 8-byte aligned, and does not wrap because both ends were
    // just checked — so this is a single naturally aligned 4-byte load, which is
    // what Device-nGnRnE memory permits and what `+strict-align` requires.
    // Volatile, and one access rather than a plain load, for the same reason:
    // the compiler may not split, merge or duplicate a read of memory it knows
    // nothing about, and gathering is architecturally prohibited on this memory
    // type. Whether the address is memory at all cannot be established here —
    // see this function's doc comment; the outcome if it is not is a synchronous
    // external abort reported by the vector table, not a silent wrong answer.
    let raw = unsafe { core::ptr::read_volatile(field as *const u32) };
    // The blob is big-endian whatever the CPU is. Read as a native word and
    // swapped, rather than cast through a typed pointer at an unproved
    // alignment, which is the same discipline `fdt.rs` applies to every field.
    let totalsize = u32::from_be(raw) as u64;

    // A length, at last — and bounded before it is used as one. `MAX_BLOB_LEN`
    // is portable and lives with the parser, because it is a statement about how
    // much input this kernel is willing to read and not a fact about a board.
    if totalsize > fdt::MAX_BLOB_LEN {
        return Err(TOO_LARGE);
    }
    if dtb.checked_add(totalsize).is_none() {
        return Err(ADDRESS_SPACE);
    }

    // SAFETY: the one construction site, and the only place in this kernel where
    // a slice is made out of memory the kernel does not own.
    //
    // Soundness, clause by clause:
    //
    //   - non-null and aligned: `dtb != 0` and `dtb % 8 == 0` were checked
    //     above, and `[u8]` needs alignment 1 in any case;
    //   - the length is not the blob's opinion of itself: it was proved
    //     `<= MAX_BLOB_LEN` (2 MiB) before this line, so it is far below
    //     `isize::MAX` and `as usize` is exact on this target;
    //   - the window does not wrap: `dtb + totalsize` was proved representable;
    //   - no aliasing and no mutation for the lifetime of the borrow. This is a
    //     shared reference and nothing here takes a mutable one. The kernel
    //     writes nothing to physical memory outside its own image at M1 — there
    //     is no allocator yet, which is precisely what this map is for — and it
    //     is single-core with interrupts masked and no DMA engine running, so
    //     there is no other writer to race with.
    //
    // Why `&'static` is defensible over memory the kernel does not own. The
    // lifetime is a claim about how long the bytes stay valid, and it is true
    // for a stronger reason than usual: the region was installed by the loader
    // at machine reset, nothing in this kernel can free, move or reuse it, and
    // `boot_rust` never returns, so no code that could invalidate it will ever
    // run. `'static` also costs nothing that could be spent elsewhere — the
    // borrow does not escape `memory_map`, because `fdt::parse` copies what it
    // needs into a `MemoryMap` and retains no reference to the blob.
    //
    // What this does NOT claim is that the window is memory. It cannot; see the
    // doc comment above. Rust's model has no vocabulary for a region a
    // bootloader placed, and the honest statement is that soundness here rests
    // on the boot protocol's promise plus the checks above, with a synchronous
    // external abort as the backstop when the promise is broken.
    Ok(unsafe { core::slice::from_raw_parts(dtb as *const u8, totalsize as usize) })
}

/// The parser's diagnosis, as one of a fixed set of strings.
///
/// One string per variant rather than "the blob is bad": `fdt::Error` was given
/// twenty-nine variants specifically so that this function could exist, and a
/// console that says "the reservation block never terminates" sends the reader
/// to one place instead of to all of them. Every arm is program text, so the
/// exhaustive match is also the enumeration — adding a variant to `fdt::Error`
/// fails to compile until someone decides what the console should say about it.
fn reason_for(err: fdt::Error) -> Reason {
    match err {
        fdt::Error::HeaderTruncated => b"blob is shorter than a 40-byte header",
        fdt::Error::BadMagic => b"magic is not d00dfeed",
        fdt::Error::TotalSizeTooSmall => b"totalsize is below the header length",
        fdt::Error::TotalSizeTooLarge => TOO_LARGE,
        fdt::Error::TotalSizeBeyondBlob => b"totalsize is beyond the window x0 named",
        fdt::Error::UnsupportedVersion => b"version is below 17",
        fdt::Error::UnsupportedCompatibleVersion => b"last_comp_version is above 17",
        fdt::Error::MisalignedStructBlock => b"off_dt_struct is not 4-byte aligned",
        fdt::Error::MisalignedReservations => b"off_mem_rsvmap is not 8-byte aligned",
        fdt::Error::StructBlockOutOfBounds => b"structure block runs past totalsize",
        fdt::Error::StringsBlockOutOfBounds => b"strings block runs past totalsize",
        fdt::Error::ReservationsOutOfBounds => b"reservation block runs past totalsize",
        fdt::Error::ReservationsUnterminated => b"reservation block never terminates",
        fdt::Error::TooManyReservations => b"more reservations than the map holds",
        fdt::Error::ReservationEndOverflows => b"a reservation ends past the address space",
        fdt::Error::StructTruncated => b"structure block is truncated",
        fdt::Error::StructEndMissing => b"structure block has no FDT_END",
        fdt::Error::UnknownToken => b"unknown structure block token",
        fdt::Error::NodeNameUnterminated => b"node name is not terminated",
        fdt::Error::NodeUnterminated => b"FDT_END with a node still open",
        fdt::Error::UnbalancedEndNode => b"FDT_END_NODE outside any node",
        fdt::Error::TooDeep => b"node nesting is deeper than the bound",
        fdt::Error::NameOffsetOutOfBounds => b"property nameoff is outside the strings block",
        fdt::Error::NameUnterminated => b"property name is not terminated",
        fdt::Error::MalformedCellCount => b"a cell count property is not one cell",
        fdt::Error::UnsupportedCellCount => b"a cell count is zero or above two",
        fdt::Error::MalformedReg => b"memory node reg is empty or not whole pairs",
        fdt::Error::TooManyRegions => b"more memory regions than the map holds",
        fdt::Error::RegionEndOverflows => b"a memory region ends past the address space",
    }
}

/// Say why the machine's memory could not be learned, and stop the machine.
///
/// No new authority: it is handed the console and the power token the boot path
/// already holds, which is why `ci/constitution-check.sh --check minting-sites`
/// still counts four call sites and not five. It is not [`crate::hal::FailStop`]
/// either — that is the panic path's, behind a re-entrancy guard, and this is an
/// ordinary boot-time refusal on a path where nothing has gone wrong with the
/// kernel itself.
///
/// Every byte it writes is program text. `SKYNET_MEM_FAIL` comes before the boot
/// marker and the marker is never reached, so `ci/boot-test.sh` fails on the
/// absent marker while the console says which of a fixed set of things was
/// wrong. It is deliberately not `SKYNET_PANIC` and not `SKYNET_FAULT`: those two
/// mean the kernel has a bug, and this means its input was not usable.
fn mem_fail(resources: BootResources<BootConsole, PowerControl>, reason: Reason) -> ! {
    let BootResources {
        mut console,
        power,
    } = resources;
    console.write(b"\nSKYNET_MEM_FAIL\r\n  reason  ");
    console.write(reason);
    console.write(b"\r\n");
    power.off()
}
