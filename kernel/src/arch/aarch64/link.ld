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
 *     .vectors  .guard  .failpath  .rodata  .text  .got  .data  .bss  .stack
 *
 * Code before the data it reads, because destroying an instruction raises an
 * exception promptly while destroying a jump-table entry can turn a branch into
 * a loop on itself that raises nothing at all.
 *
 * Every ordering above is an ASSERT below. None of it is held by script order,
 * which anyone can reverse.
 *
 * ─── WHAT IT BUYS, AND WHERE IT STOPS ───────────────────────────────────────
 *
 * Three distances decide what a stack overflow costs. They are SUBTRACTIONS on
 * the section table — `objdump -h` and `nm` give them, and they are not quoted
 * here because a number in a comment goes stale and a derivation does not:
 *
 *     __stack_top - STACK_SIZE  minus  the last word of .text
 *         past this, no full fault report: that word is `bl fault_stop`
 *     ... minus the address of `quiet_stop`'s `hvc`
 *         past this, the machine cannot power itself off: bounded, silent, 124
 *     ... minus the address of vector entry 4
 *         past this, the processor branches into rubbish and storms
 *
 * A single stack frame larger than the last distance reaches the vector table in
 * one instruction, touching nothing on the way, so nothing detects it. That is
 * ordinary Rust and no ordering prevents it. The answer is a guard page, which
 * needs the MMU. Carried with its measurements in tasks/open/T-0008.toml.
 *
 * The history of how these were got wrong — three probes, each of which changed
 * the image it measured — is in .provenance/ledger.jsonl, which is append-only
 * and where a record belongs. It is not repeated here: a linker script that
 * carries a research narrative is a surface that has to be re-verified at every
 * review, and it was the source of most findings against this file.
 */

ENTRY(_start)

KERNEL_BASE = 0x40080000;   /* QEMU virt RAM base + 512 KiB, leaving the low
                               region for the device tree QEMU builds. */
STACK_SIZE  = 0x10000;      /* 64 KiB */

SECTIONS
{
    . = KERNEL_BASE;

    /* KEEP: reached only by the processor taking an exception, so --gc-sections
     * would remove it. Named `.vectors`, not `.text.vectors`, or `.text`'s
     * wildcard below claims it first and no section is created at all.
     *
     * VBAR_EL1's low 11 bits are RES0: a misaligned table produces no error, no
     * warning and no fault — the processor truncates the address. */
    .vectors ALIGN(2048) : { KEEP(*(.vectors)) }

    /* PROGBITS, not NOBITS: one word carried in the image and initialised by the
     * loader, so it is valid before any .bss clear runs. A guard zeroed after
     * VBAR_EL1 is written reads as garbage during the window it exists for. */
    .guard : ALIGN(8) { KEEP(*(.guard)) }

    /* The emergency rungs and the marker they print. Down here so the code and
     * the text of the last thing this kernel says are as hard to destroy as the
     * table that reaches them. */
    .failpath : ALIGN(8) { KEEP(*(.failpath)) }

    .rodata : ALIGN(8) { *(.rodata .rodata.*) }

    .text : ALIGN(8) {
        /* KEEP so _start survives --gc-sections. It need not sit at
         * KERNEL_BASE: -kernel loads an ELF by program headers and jumps to
         * e_entry. */
        KEEP(*(.text.boot))
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
    ASSERT(SIZEOF(.vectors) > 0x780,
           "vector table is truncated: fewer than sixteen entries")

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

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) *(.eh_frame_hdr) }
}
