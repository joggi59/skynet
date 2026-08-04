/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This script lives under src/arch/aarch64/ rather than at the crate root
 * because it contains hardware addresses, and constitutional invariant 6 says
 * "not one address constant" outside the HAL directory. The mechanical check
 * greps only Rust constructs under kernel/src and cannot see a linker script;
 * the invariant forbids it regardless. A crate-root kernel.ld was a blocking
 * finding on contribution C-0001.
 */

ENTRY(_start)

KERNEL_BASE = 0x40080000;   /* QEMU virt RAM base + 512 KiB. The offset follows the
                               aarch64 Linux boot protocol's convention and leaves
                               the low region for the device tree QEMU builds. */
STACK_SIZE  = 0x10000;      /* 64 KiB */

SECTIONS
{
    . = KERNEL_BASE;

    /* The vector table FIRST, and the guard byte immediately after it.
     *
     * Not an ordering preference. `.stack` is the highest section and grows
     * down, and with no MMU there is no page beneath it that faults. So the
     * question was never whether an overflow reaches something — it is what it
     * reaches FIRST, and how far it must travel to destroy the two things that
     * make a fault reportable at all: the guard, and the table the processor
     * branches to.
     *
     * Review measured the old order, where `.bss` held the guard directly below
     * the stack and `.vectors` sat just below that: 1,495,553 exceptions in
     * three seconds, an empty console, exit 124, and `-d int` showing an
     * undefined instruction taken AT vector entry 4 and vectoring straight back
     * into itself. The overflow had eaten the handler for its own fault.
     *
     * Both now sit at the bottom of the image, so an overflow must destroy every
     * other section before it arrives — and it dies executing rubbish in `.text`
     * long beforehand, with the guard and the table intact to report it.
     *
     * Two other layouts were considered and rejected. `.vectors` above
     * `__stack_top` puts PROGBITS above NOBITS, and `objcopy -O binary` pads
     * across the whole 64 KiB stack — the hazard already described below.
     * `.stack` at RAM base lands in the low 512 KiB QEMU builds the device tree
     * into, which objective 0002's second success criterion needs.
     *
     * VBAR_EL1's low 11 bits are RES0: a table that is not 2 KiB aligned
     * produces no link error, no warning and no fault — the processor truncates
     * the address and vectors somewhere else. KERNEL_BASE is 2 KiB aligned, so
     * this lands with no padding, and the ASSERT below checks rather than trusts.
     *
     * KEEP because nothing in the object graph roots it: it is reached only by
     * the processor taking an exception, so --gc-sections would remove it.
     *
     * Named `.vectors`, not `.text.vectors`: output sections claim input
     * sections in script order, and `.text`'s wildcard below would match
     * `.text.vectors` and swallow it. That produced no `.vectors` section at
     * all, aligned only by an assembler directive inside the function, and it
     * linked cleanly. */
    .vectors ALIGN(2048) : { KEEP(*(.vectors)) }

    /* The re-entrancy guard, in its own section, below everything the stack can
     * reach before it has already destroyed the code that would read it.
     *
     * PROGBITS rather than NOBITS: one word carried in the image and initialised
     * by the loader, not by a `.bss` clear the boot path would have to run
     * before the vector table is usable. A guard zeroed after VBAR_EL1 is
     * written reads as garbage during exactly the window it exists for.
     *
     * KEEP: reached by `sym` from the vector table's assembly and by name from
     * fail.rs, neither of which roots it for --gc-sections. */
    .guard : ALIGN(8) { KEEP(*(.guard)) }

    .text : ALIGN(8) {
        /* KEEP so _start survives --gc-sections.
         *
         * It no longer sits at KERNEL_BASE and does not need to: QEMU's -kernel
         * loads an ELF by its program headers and jumps to e_entry. The comment
         * here used to say it must, which is true of a raw binary and was never
         * true of this one. */
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    /* A link error, not a check that can be skipped.
     *
     * ci/constitution-check.sh measures this too, but a CI check has to find the
     * section before it can measure it: rename the input section and the check
     * reports SKIP with exit 0 while the table sits where the hardware reads it
     * as the middle of _start. reviewer-safety demonstrated exactly that,
     * including that build, clippy and the boot test all still pass.
     *
     * ASSERT cannot fail open. If .vectors is absent its address is 0, which is
     * 2 KiB aligned — so the size is asserted too. */
    ASSERT((ADDR(.vectors) & 2047) == 0,
           "vector table is not 2 KiB aligned: VBAR_EL1's low 11 bits are RES0")
    ASSERT(SIZEOF(.vectors) > 0x780,
           "vector table is truncated: fewer than sixteen entries")

    /* The stride detent, and the reason it is an upper bound.
     *
     * `.align 7` before each entry aligns it; it does not CAP it. An entry that
     * grows past 128 bytes pushes the next one to the following boundary, and
     * the table silently becomes sixteen entries at a 256-byte stride. The
     * processor still indexes by 128, so every fault reports the wrong slot —
     * cur_sp0_fiq where cur_spx_sync happened — and nothing else changes: it
     * links, it boots, the alignment check passes, the report is simply false.
     *
     * Fifteen padded entries plus a final unpadded one is at most 16 * 128. One
     * oversized entry anywhere puts the total above it. */
    ASSERT(SIZEOF(.vectors) <= 0x800,
           "a vector entry exceeds 128 bytes: the table's stride has doubled and every fault will name the wrong slot")

    /* The layout property this task exists to establish, as a link error rather
     * than as a comment that describes an ordering someone can reverse.
     *
     * A stack overflow descends from __stack_top. Whatever sits directly beneath
     * it is destroyed first. These two say: not the guard, and not the table. */
    ASSERT(ADDR(.guard) < ADDR(.text),
           "the re-entrancy guard is not below .text: a stack overflow reaches it before it reaches anything else")
    ASSERT(ADDR(.vectors) < ADDR(.text),
           "the vector table is not below .text: a stack overflow destroys the handler for its own fault")
    ASSERT(SIZEOF(.guard) >= 4,
           "the re-entrancy guard section is empty or too small: nothing is holding the flag")

    .rodata : ALIGN(8) { *(.rodata .rodata.*) }
    .got    : ALIGN(8) { *(.got) *(.got.plt) }
    .data   : ALIGN(8) { *(.data .data.*) }

    /* Every NOBITS section is last, and every allocated PROGBITS section above
     * is placed explicitly. objcopy -O binary skips NOBITS but pads across them
     * if a loadable section follows at a higher address — an orphan section
     * placed after .bss would turn a 64 KiB stack into 64 KiB of image. */
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
