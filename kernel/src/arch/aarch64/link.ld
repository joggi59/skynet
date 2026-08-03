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
