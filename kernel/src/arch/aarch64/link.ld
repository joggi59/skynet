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
     * What this buys, exactly, and what it does not.
     *
     * It buys DISTANCE against an overflow that descends a frame at a time.
     *
     * An earlier version of this comment said "about 2.9 KiB before anything the
     * failure path needs is touched". With `.rodata` above `.text` the real
     * figure was 728 bytes — wrong by a factor of four, in the reassuring
     * direction, which is the direction this file has now been wrong in four
     * times. It was wrong because every probe used to find it destroyed its own
     * writing loop, so each depth reported the writer's address rather than the
     * parameter.
     *
     * Measured with a writer relocated to 0x44100000, outside everything it
     * destroys, on this ordering. These are bracketing points, not thresholds:
     *
     *   up to 3,072 B          3 exceptions, report or marker, exit 0
     *   about 3,200 - 4,400    4 exceptions, bounded, SILENT, exit 124
     *   from about 4,800       millions of exceptions, exit 124
     *
     * The middle and last rows are a reviewer's sweep, not this author's: the
     * first draft of this table said the storm began at 5,300 and it begins near
     * 4,800, where vector entry 4 is destroyed. Wrong in the reassuring
     * direction, which is the direction every distance in this file has been
     * wrong in — five times now, including the sentence that said so.
     *
     * The middle band is the one worth staring at. It is bounded, it is not a
     * storm, and it is silent with exit 124 — which is precisely the CI
     * signature objective 0002 exists to remove. Bounding the exceptions did not
     * buy a report there.
     *
     * Nothing in a linker script closes any of this. The answer is a guard page,
     * and that needs the MMU. Measured against the ordering
     * this replaced, where the guard sat directly beneath the stack: the same
     * gradual overflow gave between 2.2 and 4.0 million exceptions with an empty
     * console and exit 124, and gives three exceptions and a clean stop here.
     *
     * The exact threshold is NOT stated, and an earlier version of this comment
     * stated one. A probe that writes downward destroys its own loop before it
     * reaches the depth it was asked for, so every depth past that point
     * measures the same event — the numbers such a probe reports are its own
     * address, not the parameter. Whoever needs the real threshold must write a
     * probe whose writing code cannot be destroyed by its own writes.
     *
     * It buys NOTHING against a single frame larger than the distance. A 4 KiB
     * local array steps over `.text`, `.failpath` and `.guard` in one instruction
     * and lands on the vector table: 3,804,172 exceptions, the identical
     * signature. That is a stack clash, it is ordinary Rust, and no ordering of
     * sections prevents it.
     *
     * The structural answer is a guard page and it needs the MMU — RFC-0002 O-9,
     * which said so before this section was reordered, and which an earlier
     * version of this comment replaced with a claim that an overflow "must
     * destroy every other section before it arrives". That was false, and it was
     * false in the reassuring direction, which is worse than the gap it papered
     * over.
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

    /* The failure path's code and the string it prints, protected with them.
     *
     * These three functions used to live in `.text`, which this layout does not
     * protect — and the marker they print is `.asciz` inside one of them. Review
     * found both halves: zeroing `.text` while leaving the guard and the table
     * intact still stormed, because the first instruction of the rung is what
     * advances the ladder; and a stack overflow that clipped the string made
     * `ci/boot-test.sh` pass five checks on a kernel that had overflowed and
     * taken three faults, because the marker it greps for was no longer there.
     *
     * The advance moved into the vector entry, so these functions now hold no
     * state. They are here so that the code and the text of the last thing this
     * kernel ever says are as hard to destroy as the table that reaches them. */
    .failpath : ALIGN(8) { KEEP(*(.failpath)) }

    /* Read-only data BELOW the code that reads it.
     *
     * The failure path does not only need instructions. `fault_stop` compiles to
     * a jump table — `adr x14,.` / `ldrsw x15,[x13,x12,lsl #2]` / `add x14,x14,x15`
     * / `br x14` — and that table is `.rodata`. With `.rodata` above `.text` it
     * sat 728 bytes under the stack, and zeroing one entry made `add x14,x14,0`
     * branch the instruction to itself **forever, taking no exception at all**.
     * No ladder can advance on a fault that is never raised; review measured one
     * exception, twenty-three NUL bytes, and a timeout.
     *
     * Below `.text`, a descending stack destroys instructions before it destroys
     * the data they read — and destroying instructions raises an exception
     * promptly, which is the event the whole ladder is built on.
     *
     * The general rule this file is converging on, stated because it has been
     * rediscovered four times at four different distances: everything the
     * failure path depends on must be further from the stack than everything it
     * does not. Code before data, and the failure path's own code and data
     * furthest of all. */
    .rodata : ALIGN(8) { *(.rodata .rodata.*) }

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
     * as the middle of _start. Review demonstrated exactly that, including that
     * build, clippy and the boot test all still pass.
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
    /* Slack, stated because a bound nobody has measured against is a bound
     * nobody knows the distance to. Measured at the time of writing — objdump
     * first, sentence second, which is the order this file's history says was
     * not followed: an entry is 92 bytes of the 128 available, 36 spare, and
     * the table 2,012 of 2,048, 36 spare. Whoever spends it should say so here. */
    ASSERT(SIZEOF(.vectors) <= 0x800,
           "a vector entry exceeds 128 bytes: the table's stride has doubled and every fault will name the wrong slot")

    /* The layout property this task exists to establish, as a link error rather
     * than as a comment that describes an ordering someone can reverse.
     *
     * A stack overflow descends from __stack_top. Whatever sits directly beneath
     * it is destroyed first. These two say: not the guard, and not the table. */
    /* The ordering this revision exists for, and the last one held by nothing.
     *
     * Four judges found it independently and one measured the cost: revert
     * `.rodata` above `.text` and the tree links cleanly, passes clippy, passes
     * all five boot-test assertions, all nine constitution checks and every
     * other ASSERT in this file — while `fault_stop`'s jump table sits flush
     * against the stack floor and a 728-byte overrun branches an instruction to
     * itself forever, raising no exception any guard could catch. A reviewer
     * reproduced exactly that on a build where every ASSERT here passed. */
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
