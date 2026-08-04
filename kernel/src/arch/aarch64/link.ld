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

    .text : ALIGN(8) {
        /* _start must sit at the entry address, and must survive --gc-sections */
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    /* The vector table, aligned by the linker rather than by an assembler
     * directive inside a function. VBAR_EL1's low 11 bits are RES0: a table that
     * is not 2 KiB aligned produces no link error, no warning and no fault — the
     * processor truncates the address and vectors somewhere else.
     *
     * KEEP because nothing in the object graph roots it: it is reached only by
     * the processor taking an exception, so --gc-sections would remove it.
     *
     * Named `.vectors`, not `.text.vectors`: output sections claim input
     * sections in script order, and `.text`'s `*(.text .text.*)` wildcard above
     * matches `.text.vectors` and swallows it before this section is reached.
     * The result linked cleanly, produced no `.vectors` section at all, and was
     * aligned only by an assembler directive inside the function. */
    .vectors ALIGN(2048) : { KEEP(*(.vectors)) }

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
