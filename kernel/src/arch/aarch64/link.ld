/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Lives under src/arch/aarch64/ rather than at the crate root because it holds
 * hardware addresses, and invariant 6 forbids those outside the HAL directory.
 * The mechanical check greps Rust constructs and cannot see a linker script; the
 * invariant binds regardless.
 *
 * ─── THE ONE RULE THIS FILE EXISTS TO HOLD ──────────────────────────────────
 *
 * The stack is the highest section and grows down. With no MMU there is no page
 * beneath it that faults, so the only question is what it destroys first.
 * Everything the failure path needs is placed BELOW everything it does not:
 *
 *     .text.boot  .vectors  .guard  .failpath  .rodata  .text  .got  .data
 *     .bss  .stack
 *
 * Code before the data it reads, because destroying an instruction raises an
 * exception promptly while destroying a jump-table entry can turn a branch into
 * a loop on itself that raises nothing at all.
 *
 * `.text.boot` is the one section here that is NOT placed by that reasoning, and
 * it is placed lower than everything the failure path needs. It holds `_start`,
 * whose first 64 bytes are the aarch64 Linux boot protocol's image header, and
 * the loader reads that header at offset 0 of the flat image — which is
 * KERNEL_BASE, the address `.vectors` would otherwise occupy. The ASSERT below
 * pins it there. Being lowest costs the ordering nothing: `_start` runs once,
 * before a stack exists, and is unreachable afterwards, so a descending stack
 * that reached it would have destroyed the vector table first and there would be
 * nothing left to report with.
 *
 * WHICH of those orderings is enforced is not summarised here. Read the ASSERTs.
 *
 * Seven attempts to summarise them have been written and six were false — the
 * last claimed "every adjacent pair except one" when four of eight pairs were
 * unasserted, and was written to correct a claim of "all seven pairs" which was
 * written to correct one before that. A sentence that enumerates can drift from
 * what it enumerates; a pointer cannot. This is the pointer.
 *
 * ─── WHAT IT BUYS, AND WHERE IT STOPS ───────────────────────────────────────
 *
 * Three distances decide what a stack overflow costs. They are SUBTRACTIONS on
 * the section table — `objdump -h`, `objdump -d` and `nm` give them, and they
 * are not quoted here because a number in a comment goes stale and a derivation
 * does not:
 *
 *     __stack_top - STACK_SIZE  minus  the last word of .text
 *         past this, no full fault report: that word is `bl fault_stop`
 *     ... minus the address of the `hvc` in the quiet rung. `nm` does NOT give
 *         this one and is not meant to: the rung is an assembler label inside
 *         `.failpath` carrying no symbol, so that no name reaches it from
 *         anywhere. `objdump -d --section=.failpath` gives the address.
 *         past this, the machine cannot power itself off: bounded, silent, 124
 *     ... minus the address of vector entry 4
 *         past this, the processor branches into rubbish and storms
 *
 * A single stack frame larger than the last distance would reach the vector table
 * without touching anything on the way, and no ordering prevents that. Whether
 * this compiler emits such a frame is a separate question, and the answer
 * measured on the bare-metal target is NO: rustc 1.97.1 emits a probe loop that
 * steps 4,096 bytes and touches every page, so the descent faults on the way
 * down rather than landing.
 *
 * An earlier version of this paragraph said "that is ordinary Rust", which two
 * independent measurements now contradict. It stays as a hazard rather than a
 * fact because it is a property of the compiler and not of the architecture: a
 * flag, a version or a different backend removes the probe and nothing here
 * would notice. The answer that does not depend on a compiler is a guard page,
 * which needs the MMU. Carried in tasks/open/T-0008.toml.
 *
 * The history of how these were got wrong — three probes, each of which changed
 * the image it measured — is in .provenance/ledger.jsonl, which is append-only
 * and where a record belongs. It is not repeated here: a linker script that
 * carries a research narrative is a surface that has to be re-verified at every
 * review, and it was the source of most findings against this file.
 */

ENTRY(_start)

KERNEL_BASE = 0x40080000;   /* QEMU virt RAM base + 512 KiB.
                             *
                             * The offset follows the aarch64 Linux boot
                             * protocol's convention. It does NOT leave room for
                             * a device tree, which is what this comment used to
                             * say: dumping 0x40000000 on a halted machine gives
                             * zeros at every RAM size, x0 is zero, and QEMU
                             * builds a 1 MiB blob for `virt` that it never
                             * places in guest memory for an ELF `-kernel`.
                             * Established by T-0006's first acceptance
                             * criterion, which released the task rather than
                             * work around it. Ledger, event `correction`.
                             *
                             * For a Linux-format `Image` the blob IS placed, and
                             * not below the kernel: the loader puts it at the
                             * RAM base plus min(half the RAM, 128 MiB), so it
                             * moves with the machine's size and no constant here
                             * or in the kernel may name it. It arrives in `x0`
                             * instead. RFC-0003 section 1a measured six
                             * different addresses from one binary. */
STACK_SIZE  = 0x10000;      /* 64 KiB */

SECTIONS
{
    . = KERNEL_BASE;

    /* `_start`, and nothing else. Its own output section for one reason: the
     * first 64 bytes of `_start` are the boot protocol's image header, which the
     * loader reads at offset 0 of the flat image. Left inside `.text` it would
     * sit above `.vectors`, and byte 56 of the image — where the loader checks
     * for `ARM\x64` — would be four bytes of vector entry 0.
     *
     * KEEP because nothing calls `_start`: --gc-sections would take it and leave
     * an image whose first bytes are whatever landed there instead.
     *
     * The cost is the gap this opens below `.vectors`, which the 2 KiB alignment
     * turns into fill in the flat image. It is a real cost, it is stated in the
     * contribution that added it, and it is the price of the ordering above: no
     * other section may be placed in the gap without reversing one of the
     * ASSERTs that keep the failure path below the code it reports on. */
    .text.boot : ALIGN(8) { KEEP(*(.text.boot)) }

    /* Not an ordering, which is what every other ASSERT in this file holds. The
     * loader does not search for the header; it reads offset 0. An `.text.boot`
     * that is merely BELOW `.vectors` is not enough, and a `<` here would pass
     * for any gap at all. */
    ASSERT(ADDR(.text.boot) == KERNEL_BASE,
           "_start is not at KERNEL_BASE: the image header is not at offset 0 of the flat image and the loader will reject or mis-place the kernel")
    ASSERT(SIZEOF(.text.boot) >= 64,
           "the boot section is smaller than the image header it must contain")

    /* KEEP: reached only by the processor taking an exception, so --gc-sections
     * would remove it. Named `.vectors`, not `.text.vectors`, or `.text`'s
     * wildcard below claims it first and no section is created at all.
     *
     * VBAR_EL1's low 11 bits are RES0: a misaligned table produces no error, no
     * warning and no fault — the processor truncates the address. */
    /* THE ENTRY-COUNT ASSERT IS HERE, AND IT DEFINES NO SYMBOL.
     *
     * It used to read `__vectors_entries_end - __vectors_entries > 0x780`, with
     * both names assigned at the two `.` positions below. A plain `sym = .` in a
     * linker script is GLOBAL DEFAULT, and `__vectors_entries` was the address of
     * vector entry 0 — the first byte of executable code in the image. Reaching
     * it needed no `#[link_name]`, no `asm!` and no architecture construct, only
     *
     *     unsafe extern "C" { fn __vectors_entries() -> !; }
     *
     * in a portable file. Measured: `kernel_main` calling it printed
     * SKYNET_BOOT_OK, then a full SKYNET_FAULT report naming slot cur_sp0_sync,
     * and powered the machine off, on a boot where no exception had occurred.
     * Same defect as the two mangled rung symbols removed one commit earlier, and
     * an easier reach than either.
     *
     * `HIDDEN(...)` WAS TRIED FIRST AND DOES NOT CLOSE IT. It does everything it
     * advertises — both symbols become NOTYPE LOCAL HIDDEN at unchanged addresses
     * and the flat image stays byte-identical — and the reach-around above still
     * links and still runs, because visibility governs what leaves a link, not
     * what resolves inside one. Recorded because it looks like a fix and measures
     * as one on every instrument except the one that matters.
     *
     * `. - ADDR(.vectors)` needs no name, so there is nothing to spell. The
     * expression is evaluated where the entries end and before the padding below,
     * which is the position the two symbols existed to mark. Verified to still
     * bite: a table built with one ENTRY instead of sixteen stops the link with
     * this ASSERT's own message.
     *
     * WHAT THIS DOES NOT DO, stated because the last three claims this branch
     * made about its own work were withdrawn for being wider than the evidence.
     * It closes ONE reach: the one needing no attribute. `vector_table` itself is
     * still a `FUNC LOCAL HIDDEN` symbol at this same address, and a portable
     * file naming it through `#[link_name]` still links and still runs — measured
     * on this commit. Reach is not closed and cannot be closed by arranging
     * symbols, because VBAR_EL1 is an address and the processor needs no name to
     * branch. RFC-0002 section 5 says so and this file does not contradict it. */
    .vectors ALIGN(2048) : {
        KEEP(*(.vectors))
        ASSERT(. - ADDR(.vectors) > 0x780,
               "the vector table has fewer than sixteen real entries: padding would make its SIZEOF look right while the processor branches into fill")
        /* Pad to the full sixteen entries, so the size is an EQUALITY below
         * rather than a range with slack to argue about.
         *
         * A truncated entry 15 becomes zero bytes, and all-zero is a
         * permanently-undefined AArch64 encoding: the processor traps into the
         * ladder instead of falling off the end of the table into `.guard`.
         * Padding turns a silent overrun into the one behaviour this whole file
         * is built around. */
        . = ALIGN(2048);
    } =0x00000000

    /* PROGBITS, not NOBITS: one word carried in the image and initialised by the
     * loader, so it is valid before any .bss clear runs. A guard zeroed after
     * VBAR_EL1 is written reads as garbage during the window it exists for. */
    .guard : ALIGN(8) { KEEP(*(.guard)) }

    /* The emergency rungs and the marker they print. Down here so the code and
     * the text of the last thing this kernel says are as hard to destroy as the
     * table that reaches them. */
    .failpath : ALIGN(8) { KEEP(*(.failpath)) }

    .rodata : ALIGN(8) { *(.rodata .rodata.*) }

    /* `.text.boot` is claimed by the output section of the same name above, so
     * the wildcard here never sees it. Order of output sections is what decides
     * that, not the wildcard's shape. */
    .text : ALIGN(8) {
        *(.text .text.*)
    }

    /* ─── DETENTS ────────────────────────────────────────────────────────────
     *
     * Link errors, not checks that can be skipped. ci/constitution-check.sh
     * measures alignment too, but a CI check must FIND the section first: rename
     * the input section and it reports SKIP with exit 0 while the table sits
     * where the hardware reads it as the middle of _start.
     *
     * An absent section has address 0, which is 2 KiB aligned — so size is
     * asserted beside address, and neither can fail open. */

    ASSERT((ADDR(.vectors) & 2047) == 0,
           "vector table is not 2 KiB aligned: VBAR_EL1's low 11 bits are RES0")
    /* An equality, not a range.
     *
     * `> 0x780` admitted a sixteenth entry one byte long, and nothing anywhere
     * said that entry 15 could run off the end of the table into `.guard`. The
     * two "derivations" that were supposed to state the remaining slack were the
     * same expression written twice — `0x800 - S` and `128 - (S - 1920)` both
     * reduce to `2048 - S` — which is what an unevaluated derivation looks like.
     *
     * With the section padded above, the size is architectural: sixteen entries
     * of 128 bytes, or a link error. Nothing to state, nothing to go stale. */
    /* TWO assertions, because either alone is defeated by the other's fix.
     *
     * `== 0x800` alone is vacuous on the truncation side: the padding brings any
     * table to 2 KiB, so ONE entry of sixteen links clean, passes every check,
     * and then storms — measured at 691,392 undefined-instruction exceptions
     * with a silent console, because the trap target is itself padding. The
     * `> 0x780` it replaced refused that identical build.
     *
     * So the ENTRIES are measured before the padding, and the SECTION after it.
     * The first says sixteen real entries exist; the second says the table
     * occupies its full 2 KiB so a short entry 15 cannot spill into `.guard`.
     *
     * `=0x00000000` pins the fill. An all-zero word is a permanently-undefined
     * AArch64 encoding — verified on cortex-a72: ESR 0x02000000, slot
     * cur_spx_sync, full report, clean PSCI stop — so landing in the pad traps
     * into the ladder. Without the explicit fill that behaviour is an lld
     * default, which is not a guarantee. */
    ASSERT(SIZEOF(.vectors) == 0x800,
           "the vector table does not occupy its full 2 KiB: a short final entry can spill into the guard")

    /* `.align 7` aligns an entry; it does not CAP one. An oversized entry pushes
     * the next to the following boundary and the table becomes sixteen entries
     * at a 256-byte stride, which the processor still indexes by 128 — so every
     * fault names the wrong slot and nothing else changes. It links, it boots,
     * the alignment check passes, the report is simply false. */
    ASSERT(SIZEOF(.vectors) <= 0x800,
           "a vector entry exceeds 128 bytes: the table's stride has doubled and every fault will name the wrong slot")


    /* The ordering, as link errors. Reverting any of these passes build, clippy,
     * every boot-test assertion and every constitution check. */
    ASSERT(ADDR(.rodata) < ADDR(.text),
           "read-only data is above the code that reads it: a stack overflow will zero a jump table before it zeroes an instruction, and a branch-to-self raises no fault for any guard to catch")
    ASSERT(ADDR(.guard) < ADDR(.text),
           "the re-entrancy guard is not below .text: a stack overflow reaches it before it reaches anything else")
    ASSERT(ADDR(.vectors) < ADDR(.text),
           "the vector table is not below .text: a stack overflow destroys the handler for its own fault")
    ASSERT(ADDR(.failpath) < ADDR(.text),
           "the failure path is not below .text: a stack overflow destroys the code that reports it, and the marker CI greps for")
    ASSERT(SIZEOF(.failpath) > 0,
           "the failure path section is empty: the emergency rungs are somewhere else")
    ASSERT(ADDR(.vectors) < ADDR(.guard),
           "the vector table is not below the guard: the ordering these ASSERTs exist to hold has been reversed")
    ASSERT(ADDR(.guard) < ADDR(.failpath),
           "the guard is not below the failure path: the ordering these ASSERTs exist to hold has been reversed")
    ASSERT(ADDR(.failpath) < ADDR(.rodata),
           "the failure path is not below .rodata: it moves closer to the stack, which is the one thing this layout exists to prevent")
    /* The founding premise, which nothing held until it was demonstrated: place
     * `.stack` between `.guard` and `.failpath` and it grows down through the
     * guard and the whole vector table, while the build, clippy, all twelve
     * other ASSERTs, the alignment check, the size budget at 36% and the boot
     * test with a clean PSCI shutdown are every one of them green. */
    /* `.text` below everything the failure path does NOT need. Moving it under
     * `.bss` links, passes every other ASSERT and every check, and collapses the
     * distance from the stack floor to `bl fault_stop` — the report dies sooner
     * with nothing to say so.
     *
     * No figure here. The previous version quoted one, in the file whose header
     * says distances are derived and not written down, and the figure was wrong:
     * review measured the distance as four bytes where this comment claimed
     * eighty-four. `objdump -h` and `nm` give it. */
    ASSERT(ADDR(.text) < ADDR(.got),
           "code is above data the failure path does not need: the distance from the stack to the last instruction of .text collapses, and no other check sees it")
    /* Highest, with nothing after it — and the second half is the part that
     * needed saying. `ADDR(.stack) > ADDR(.text)` only compares against a named
     * section, so an ORPHAN placed above the stack passed it: review linked one
     * at 70,884 bytes with every check green and the size budget reporting 36%
     * used. Comparing `__stack_top` with `__kernel_end` names nothing and
     * therefore misses nothing. */
    ASSERT(ADDR(.stack) > ADDR(.text),
           "the stack is not above the code: it grows down through the failure path and the vector table")
    ASSERT(SIZEOF(.guard) >= 4,
           "the re-entrancy guard section is empty or too small: nothing is holding the flag")

    .got    : ALIGN(8) { *(.got) *(.got.plt) }
    .data   : ALIGN(8) { *(.data .data.*) }

    /* Every NOBITS section is last and every allocated PROGBITS above is placed
     * explicitly. objcopy -O binary skips NOBITS but pads across them if a
     * loadable section follows at a higher address — an orphan after .bss would
     * turn a 64 KiB stack into 64 KiB of image. */
    .bss (NOLOAD) : ALIGN(8) {
        __bss_start = .;
        *(.bss .bss.* COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }

    .stack (NOLOAD) : ALIGN(16) {
        . += STACK_SIZE;
        __stack_top = .;
    }

    __kernel_end = .;

    /* The boot protocol's `image_size`, read out of the header by the loader:
     * how much memory the kernel occupies, not how long its file is. It includes
     * .bss and the 64 KiB stack, which are in neither. Defined from the symbol
     * rather than from a number so that moving anything above moves it too.
     *
     * It must be non-zero or the loader ignores text_offset and places the image
     * wherever it likes. Nothing asserts that here because nothing can make it
     * zero: __kernel_end is above KERNEL_BASE by at least the stack. */
    __image_size = __kernel_end - KERNEL_BASE;

    ASSERT(__stack_top == __kernel_end,
           "something is placed above the stack: it is no longer the highest section, and an orphan there inflates the image while the size budget still reports PASS")

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) *(.eh_frame_hdr) }
}
