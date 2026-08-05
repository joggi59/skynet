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
     * The layout, as `objdump -h` reports it at the time of writing. Read it
     * from the tool rather than from here; the ASSERTs below are what actually
     * hold the order, and they are checked at every link.
     *
     *   .vectors   0x40080000    2012 bytes
     *   .guard     0x400807e0       4 bytes
     *   .failpath  0x400807e8      96 bytes
     *   .rodata    0x40080848     740 bytes
     *   .text      0x40080b30    2448 bytes
     *   .bss       0x400814c0       0 bytes
     *   .stack     0x400814c0   65536 bytes
     *
     * The stack grows down from `__stack_top`, so it destroys `.text` first and
     * the vector table last. What each depth costs is ARITHMETIC on the section
     * table above, not a probe reading — every probe here changes the image it
     * measures, three times over: one destroyed its own writing loop, one
     * counted from a floor read out of a different build, and one put its own
     * code in the bytes whose destruction was the thing being measured.
     *
     * So the distances are derived, and anyone can re-derive them with objdump:
     *
     *        4 B   `bl fault_stop`, the LAST word of .text. Past this depth no
     *            full fault report is possible; the best remaining is the marker.
     *     3280 B   `quiet_stop`'s `hvc`. Past this the machine cannot power
     *            itself off: bounded at four exceptions, silent, exit 124.
     *     4800 B   vector entry 4. Past this the processor branches into
     *            rubbish and storms — millions of exceptions, nothing printed.
     *
     * Reproduced under QEMU at those depths, and the first row is why two rows
     * of an earlier table were false in the reassuring direction: they claimed a
     * full report at 16 and 800 bytes, and a full report has been impossible
     * past four bytes since `.text` came to end at the stack floor.
     *
     * Three things this table says that the prose it replaced did not.
     *
     * The ladder keeps bounding exceptions long after it stops being able to
     * speak: from 3,280 to 4,700 it takes exactly four and then stops dead. That
     * is not a fault in the ladder. The overrun has destroyed the failure path's
     * CODE, so no report is possible — and a machine that stops silently with
     * exit 124 is exactly the CI signature this milestone exists to remove. The
     * exceptions being bounded did not buy a report.
     *
     * The edge is 3,280, not a round number, and it is where `quiet_stop`'s
     * `hvc` dies rather than anything about distance. At 3,264 the machine is
     * already silent and still powers itself off.
     *
     * And past 4,800 nothing here helps at all: that is vector entry 4, and a
     * single stack frame larger than the distance reaches it in one instruction
     * without touching anything in between. That is ordinary Rust, no ordering
     * of sections prevents it, and the answer is a guard page — which needs the
     * MMU.
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
     * Measured, on a build where every other ASSERT in this file passed: revert
     * `.rodata` above `.text` and the tree still links cleanly, passes clippy,
     * passes all five boot-test assertions and all nine constitution checks —
     * while `fault_stop`'s jump table sits flush against the stack floor. A
     * 728-byte overrun then zeroes one table entry, `add x14,x14,0` branches the
     * instruction to itself, and no exception is ever raised for any guard to
     * catch. Every mechanical check in the repository is green while the machine
     * spins in a single instruction. */
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
