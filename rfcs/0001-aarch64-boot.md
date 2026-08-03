# RFC-0001: aarch64 boot to marker and clean shutdown

- Objective: 0001            Status: draft
- Author: architect          Model: claude-opus-5[1m]
- Milestone: M0

## Motivation

Nothing runs. There is a constitution, a forge, and a gate that can judge contributions, but no kernel
for them to judge. `kernel/` contains no `Cargo.toml`, so `ci/build.sh`, `ci/boot-test.sh` and half of
`ci/constitution-check.sh` report PENDING, and `ci/gate.sh` refuses any merge with a pending check.
Nothing can land until something boots.

M0 is the smallest thing that changes that: a kernel that comes up on `qemu-system-aarch64 -M virt`,
writes `SKYNET_BOOT_OK` to the PL011 console, and shuts the machine down through PSCI so QEMU exits 0.
The shutdown is not a flourish — a kernel that spins forever after printing cannot be distinguished
from one that hung, so "it printed something" is not evidence that it works.

The objective's `common_good` names three properties that are almost impossible to retrofit:
capability discipline, provenance, and portability discipline. Two of them are decided here, and both
are decided by structure rather than by effort.

**Portability discipline.** With one architecture in the tree, a HAL boundary is free to be fictional:
a module named `arch` that everything reaches around. The boundary has to be load-bearing on the day
it has nothing to abstract over, because the day it has two architectures is the day it is too late.

**Capability discipline.** The first console in a kernel is where ambient authority is normally born.
It arrives as a convenience — a `static CONSOLE`, a `print!` macro, an `arch::console()` accessor —
and after that every line of the kernel can talk to the outside world by virtue of being kernel code.
Invariant 1 says nothing is reachable by default. A kernel whose very first device is reachable by
default has already decided the answer at M4, and nobody will remember it was decided here.

This RFC therefore spends more of its design budget on a seam with nothing behind it, and on the
ownership of two devices, than two hundred lines of boot code would normally justify.

## Design

### 0. What the environment fixes

These are not choices. They are verified facts about the target, recorded so an implementer does not
have to rediscover them and a reviewer can check them.

| Fact | Value | Verified against |
| --- | --- | --- |
| Target triple | `aarch64-unknown-none-softfloat` | `profiles/*.toml`; `rustc --print target-list` |
| Target features | `+v8a,+strict-align,-neon`; softfloat ABI | rustc target spec `aarch64_unknown_none_softfloat.rs` |
| Target default linker | `rust-lld`, flavour `Gnu(Cc::No, Lld::Yes)` | same |
| Target panic strategy | `abort` (built in; no `eh_personality` needed) | same |
| Relocation model | `static`, non-PIE | same |
| RAM base / link address | `0x4000_0000` / `0x4008_0000` | QEMU `hw/arm/virt.c`, `base_memmap[VIRT_MEM] = { GiB, .. }` |
| PL011 UART0 | `0x0900_0000`, 4 KiB; DR at `+0x000`, FR at `+0x018` | QEMU `hw/arm/virt.c`, `base_memmap[VIRT_UART0]` |
| PSCI conduit | HVC, because `-M virt` defaults to `secure=off`, `virtualization=off` | QEMU `hw/arm/virt.c`: `else { vms->psci_conduit = QEMU_PSCI_CONDUIT_HVC; }` |
| PSCI `SYSTEM_OFF` | `0x8400_0008` (`QEMU_PSCI_0_2_FN_BASE 0x84000000` + 8) | QEMU `target/arm/kvm-consts.h` |
| Entry exception level | EL1 — virt with `secure=off, virtualization=off` implements neither EL3 nor EL2 | QEMU `hw/arm/boot.c`, `arm_load_kernel` |
| Entry register state | **x0 is zero, not a DTB pointer** | QEMU `hw/arm/boot.c` — see below |
| Secondary cores | started in PSCI powered-down state whenever the conduit is enabled | QEMU `hw/arm/boot.c`: `object_property_set_bool(cpuobj, "start-powered-off", true)` |
| Naked functions | `#[unsafe(naked)]` + `naked_asm!` stable since Rust 1.88; toolchain here is 1.97.1 | Rust release notes; `rustc --version` |
| Boot contract markers | `SKYNET_BOOT_OK` must appear on the console; `SKYNET_PANIC` must not | `ci/lib.sh` `BOOT_MARKER`, `PANIC_MARKER`; `ci/boot-test.sh` |

Two of these contradict what is written elsewhere in the repository, and the implementer must not be
surprised by them.

**x0 does not hold a device tree pointer.** `ci/boot-test.sh --contract` states `entry state x0 =
device tree blob pointer`. That is true for a raw `Image` and false for an ELF. `hw/arm/boot.c`
carries the comment `/* Assume that raw images are linux kernels, and ELF images are not. */`; when
`arm_load_elf()` succeeds, `is_linux` stays 0, the bootloader stub that loads the DTB address into x0
is never written — it sits inside `if (is_linux) { ... }` — and `do_cpu_reset()` takes the
`!info->is_linux` branch, which does `cpu_reset()` followed by `cpu_set_pc(cs, entry)` and nothing
else. Every general-purpose register is zero at entry. QEMU still *builds* a device tree and loads
it, at `info->dtb_start`, which for an image linked above `loader_start` is `0x4000_0000` with a
limit of `0x4008_0000` — but it does not tell the kernel where. **M0 must not read x0 and must not
depend on a device tree existing.** Recorded as open question O-2; it becomes load-bearing at M1.

**The default linker is not present on the reference machine.** Fedora's `rust` package ships no
`rust-lld` (`/usr/lib/rustlib/*/bin/` does not exist, and
`rust-std-static-aarch64-unknown-none-softfloat` contains only `lib/*.rlib`). Nothing inside
`kernel/` can fix this. Open question O-1, and the one blocking item in this RFC.

### 1. Crate and file layout

A single crate, not a workspace. Invariant 7 is checked against the resolved graph in
`kernel/Cargo.lock` as well as the manifest; a workspace would give the kernel a lock file that can
acquire entries it never declared.

```
kernel/
├── Cargo.toml              package "skynet-kernel"; no dependency sections at all
├── Cargo.lock              committed; exactly one [[package]]
├── build.rs                linker-script wiring (arch-selection point 1 of 2)
├── .cargo/config.toml      OPTIONAL, and may contain only [build] target = "..."
└── src/
    ├── main.rs             #![no_std] #![no_main]; kernel_main; the boot marker
    ├── hal.rs              the portable contract: Console, Power, Cpu, FailStop, BootResources
    ├── panic.rs            #[panic_handler]; the panic marker
    └── arch/
        ├── mod.rs          architecture selection (arch-selection point 2 of 2)
        └── aarch64/
            ├── mod.rs      assembles the aarch64 implementation of the contract
            ├── boot.rs     _start, exception-level handling, .bss, stack, handoff
            ├── cpu.rs      Processor: halt
            ├── fail.rs     Failure: the panic path's narrow authority
            ├── pl011.rs    BootConsole
            ├── psci.rs     PowerControl
            ├── platform.rs QEMU virt address constants
            └── link.ld     the linker script
```

`kernel/src/arch/` must be a **directory containing `mod.rs`**, never a file `kernel/src/arch.rs`.
`ci/constitution-check.sh` excludes HAL hits with `grep -v "^kernel/src/arch/"`, a directory prefix;
a file named `arch.rs` would be scanned as ordinary kernel source and every `asm!` in it would fail
gate condition 6.

`link.ld` lives under `kernel/src/arch/aarch64/` because it contains addresses, and invariant 6 says
"not one address constant" outside the HAL directory. The mechanical check greps only `kernel/src`
for six named constructs and would not catch a linker script placed at `kernel/kernel.ld`; the
invariant still forbids it.

### 2. The HAL boundary

The seam has three parts: a contract that names nothing architectural, an implementation, and a
compile-time proof that the second satisfies the first.

**`kernel/src/hal.rs` — the contract.** Portable by construction: no register name, no address, no
instruction, no `cfg`.

```rust
/// A byte sink reaching the operator's boot console.
pub trait Console {
    /// Write every byte of `bytes`, in order, returning only once the device
    /// has accepted all of them.
    fn write(&mut self, bytes: &[u8]);
}

/// Authority to change the machine's power state.
///
/// `off` takes `self` by value: exercising this authority consumes it. There is
/// no way to hold a `Power` and use it twice, and no way to obtain one except
/// from the boot path.
pub trait Power {
    /// Power the machine off. Does not return.
    fn off(self) -> !;
}

/// Operations on the executing processor.
///
/// Deliberately an associated function with no receiver: halting the current
/// processor grants access to nothing -- it removes the caller's own ability to
/// continue -- so it requires no token.
pub trait Cpu {
    /// Stop this processor permanently, with interrupts masked. Does not return.
    fn halt() -> !;
}

/// The failure path, and the narrowest authority in the kernel.
///
/// `#[panic_handler]` is handed a `&PanicInfo` and nothing else, so the failure
/// path is the one caller the language refuses to hand anything to. Rather than
/// give it a global console to reach for, it is given this: an operation that
/// takes bytes, emits them on the platform's failure console, stops the machine,
/// and cannot do anything else. It is not a `Console` and must never become one.
pub trait FailStop {
    /// Emit `bytes`, then stop the machine. Does not return.
    ///
    /// # Safety
    /// Callable only from the panic handler. The implementation may alias a
    /// console owned elsewhere, which is sound only because the kernel has
    /// already failed and no other code will run again.
    unsafe fn fail_stop(bytes: &[u8]) -> !;
}

/// Everything the boot path found, on its way to `kernel_main`.
pub struct BootResources<C: Console, P: Power> {
    pub console: C,
    pub power: P,
}
```

**`kernel/src/arch/mod.rs` — the selection point.** This module and `build.rs` are the only two places
in the kernel that may name an architecture.

```rust
#[cfg(target_arch = "aarch64")]
mod aarch64;
#[cfg(target_arch = "aarch64")]
pub use aarch64::{BootConsole, Failure, PowerControl, Processor};

#[cfg(not(target_arch = "aarch64"))]
compile_error!(
    "no HAL implementation for this target architecture; \
     add one under kernel/src/arch/ and a linker script in build.rs"
);
```

**The conformance proof**, at the bottom of `hal.rs` so it is checked from the portable side:

```rust
const _: () = {
    const fn implements_console<T: Console>() {}
    const fn implements_power<T: Power>() {}
    const fn implements_cpu<T: Cpu>() {}
    const fn implements_failstop<T: FailStop>() {}
    implements_console::<crate::arch::BootConsole>();
    implements_power::<crate::arch::PowerControl>();
    implements_cpu::<crate::arch::Processor>();
    implements_failstop::<crate::arch::Failure>();
};
```

This costs zero bytes and no runtime work, and it is what makes the seam real rather than
conventional: a port that omits a piece nobody currently calls fails to compile, instead of silently
narrowing the boundary until the second architecture arrives and discovers it. Verified on 1.97.1,
edition 2024: it compiles with a conforming type and rejects a non-conforming one.

**Why traits rather than a module of free functions.** This is the design's most arguable decision,
and the alternative is genuinely attractive — see *Alternatives*. The deciding argument is that a
module's contract is defined by its call sites. `arch::console_write_byte` exists because something
calls it; the HAL therefore silently equals "whatever M0 happened to need", and a second port
satisfies it by accident. The trait plus the const assertion states the whole contract independently
of who currently calls what. Fifteen lines, zero bytes, and the difference between a boundary and a
habit.

**Why `kernel_main` is generic.** `kernel_main<C: Console, P: Power>(res: BootResources<C, P>)`
cannot name `BootConsole`, so it cannot acquire one by any route other than the one it was handed.
Portable code reaching for an aarch64 type would not type-check. Monomorphisation makes this free.

### 3. The portable kernel

`kernel/src/main.rs`:

```rust
#![no_std]
#![no_main]

mod arch;
mod hal;
mod panic;

use hal::{BootResources, Console, Power};

/// The bytes that mean "this kernel is alive".
///
/// Defined by BOOT_MARKER in ci/lib.sh and looked for by ci/boot-test.sh. It
/// lives in portable code because it is a project contract, not a fact about
/// aarch64.
const BOOT_MARKER: &[u8] = b"SKYNET_BOOT_OK\n";

pub fn kernel_main<C: Console, P: Power>(mut res: BootResources<C, P>) -> ! {
    res.console.write(BOOT_MARKER);
    res.power.off()
}
```

That is the entire portable kernel at M0. No globals, no statics, no initialisation phase, and no way
to obtain a device it was not given.

`no_std` costs exactly two items: `#![no_std]` swaps the `std` prelude for `core`, and `#![no_main]`
removes the requirement for a `fn main` with the platform startup contract. No external crate is
involved in either. `core` and `compiler_builtins` come from the installed `rust-std` for the target
and do not appear in `Cargo.lock`. `panic = "abort"` is already this target's built-in strategy, so
no `eh_personality` lang item is required.

`kernel/src/panic.rs`:

```rust
use crate::arch::Failure;
use crate::hal::FailStop;

/// The bytes that mean "this kernel failed".
///
/// Defined by PANIC_MARKER in ci/lib.sh; ci/boot-test.sh fails the run if it
/// appears. A compile-time constant and nothing else: no formatting, no
/// `PanicInfo`, no private state on the wire.
const PANIC_MARKER: &[u8] = b"SKYNET_PANIC\n";

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    // SAFETY: reached only from the panic handler, which never returns. No
    // other code will run again, so aliasing the boot console is sound.
    unsafe { Failure::fail_stop(PANIC_MARKER) }
}
```

The panic handler is the one place the language forces a global entry point: it is called with a
`&PanicInfo` and nothing else, so it cannot be handed a console. This design gives it the narrowest
authority that satisfies the contract rather than the most convenient one.

**Why it announces itself rather than halting silently.** The boot contract in `ci/lib.sh` now names
`PANIC_MARKER` and requires `BOOT_MARKER` present *and* `PANIC_MARKER` absent. That is worth the
machinery, because the two failure shapes it catches are otherwise both bad: a panic that halts is
caught by the 30-second timeout, correctly but slowly and with nothing in the log to read, while a
panic that shuts down cleanly exits 0 and is indistinguishable from success to a test checking only
the exit code. With the marker, a panic before the boot marker fails on the missing boot marker and a
panic after it fails on the panic marker — fail-closed in both directions, in milliseconds, with a
legible reason. `ci/boot-test.sh --gdb` is then for diagnosis, not for discovering that something went
wrong at all.

**Why it does not print the panic message.** `_info` is ignored. Formatting it would pull `core::fmt`
into the kernel image, and it would put whatever a future panic string happens to contain onto an
outward channel. The marker is a compile-time constant, which keeps invariant 5 exactly true and the
image small. Richer diagnostics need a design, not a `write!` — see O-4.

**Why it powers the machine off.** Because the contract says "prints PANIC_MARKER and then shuts
down", and because with the marker present the shutdown is what turns a 30-second CI timeout into an
immediate failure. It is a bring-up behaviour, not a product behaviour: a kernel in a car should
reset under a watchdog, not power off. That is recorded as O-8 rather than quietly inherited.

**What this costs, stated for reviewer-constitution.** `fail_stop` mints a console from a compile-time
address instead of receiving one. That is the single place in the kernel where authority is created
outside the boot path, and it is bounded deliberately: one function, one caller, one compile-time
constant written, never returns, not a `Console`, and unusable for ordinary output. The full argument
is in the invariant 1 section below, including why it is not the same thing as a global console and
what would make it become one.

### 4. The aarch64 implementation

**`arch/aarch64/platform.rs`** — the board's map, kept separate from the ISA:

```rust
/// PL011 UART0 on QEMU virt.
pub const UART0_BASE: usize = 0x0900_0000;
```

Architecture and board are different axes of variation. One extra file now keeps a QEMU virt address
out of the PL011 driver.

**`arch/aarch64/boot.rs`** — `_start`, a naked function in section `.text.boot`, `KEEP`-ed by the
linker script and rooted by `ENTRY(_start)`. The following sequence has been assembled and
disassembled on stable 1.97.1, edition 2024:

```rust
#[unsafe(naked)]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".text.boot")]
unsafe extern "C" fn _start() -> ! {
    naked_asm!(
        "msr  daifset, #0xf",              // mask D, A, I, F before anything else
        // zero .bss (the linker script guarantees both bounds are 8-byte aligned)
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
        "mrs  x9, CurrentEL",
        "lsr  x9, x9, #2",
        "cmp  x9, #2",
        "b.ne 2f",
        // --- entered at EL2: drop to EL1h ---
        "movz x9, #0x8000, lsl #16",       // HCR_EL2.RW = 1: EL1 is AArch64
        "msr  hcr_el2, x9",
        "movz x9, #0x0800",                // SCTLR_EL1 = 0x30d0_0800
        "movk x9, #0x30d0, lsl #16",
        "msr  sctlr_el1, x9",
        "mov  x9, #0x3c5",                 // SPSR_EL2: D,A,I,F masked, M = EL1h
        "msr  spsr_el2, x9",
        "adr  x9, 3f",
        "msr  elr_el2, x9",
        "msr  sp_el1, x12",
        "eret",
        // --- entered at EL1: configure in place ---
        "2:  cmp  x9, #1",
        "    b.ne 4f",
        "    movz x9, #0x0800",
        "    movk x9, #0x30d0, lsl #16",
        "    msr  sctlr_el1, x9",
        "    isb",
        "3:  mov  sp, x12",
        "    b    {rust}",
        // --- anything else (EL3): unsupported ---
        "4:  wfi",
        "    b    4b",
        rust = sym boot_rust,
    )
}
```

Details that are not obvious, and that a reviewer should check:

- **`SCTLR_EL1 = 0x30d0_0800`** is every bit that is RES1 in ARMv8.0 — 11 (EOS), 20 (TSCXT),
  22 (EIS), 23 (SPAN), 28 (nTLSMD), 29 (LSMAOE) — with M, C, I, A, SA and SA0 clear: MMU off, caches
  off, little-endian, alignment and stack-alignment checks off. On ARMv8.1+ each of those bits set to
  1 selects the ARMv8.0 behaviour, so the value remains correct on newer cores. It differs from
  Linux's `INIT_SCTLR_EL1_MMU_OFF` (`0x3050_0800`) in bit 23 alone: Linux clears SPAN because it
  wants PAN set automatically on exception entry. M0 has no exceptions and no user space, so it takes
  the RES1 value.
- **The kernel requires the MMU and caches to be off at entry**, as the arm64 Linux boot protocol
  does. M0 does not attempt to turn a running MMU off; doing so while executing changes the
  translation of the program counter.
- **x12 survives the `eret`.** `eret` does not alter general-purpose registers, so the EL2 path and
  the EL1 path share the single `mov sp, x12` at label 3.
- **`.bss` is zeroed in assembly, not in Rust.** The Rust alternative requires declaring
  `__bss_start` and `__bss_end` as `extern` statics: as `static` they are immutable and writing
  through them is not defensible, and as `static mut` they would be the only `static mut` in the
  kernel. Seven instructions removes the question entirely. The kernel does not rely on the loader
  zeroing anything — QEMU happens to zero the `memsz`/`filesz` gap of a PT_LOAD segment, but no
  hardware loader promises to.
- **EL3 is not supported.** It cannot occur under the boot contract's invocation, and an EL3 drop is
  speculative code in a privileged path. The unsupported case parks the processor in the same `wfi`
  loop the panic path uses.
- **Dropping from EL2 is for robustness only, and does not make PSCI work at EL2.** QEMU sets the
  conduit to SMC when `virtualization=on`, and `arm_load_kernel` disables an HVC conduit outright
  whenever the boot EL is 2 or above. A kernel entered at EL2 on QEMU virt must therefore discover
  its conduit rather than assume HVC. Under the contract M0 is only ever entered at EL1. Open
  question O-3.

The Rust half of the boot path, in the same file:

```rust
/// Second stage of boot: still architecture-specific, now in Rust.
///
/// # Safety
/// Reached only from `_start`, exactly once, at EL1, with interrupts masked, a
/// valid stack and a zeroed .bss. It mints the platform's device tokens, which
/// is sound only because there is exactly one call site.
unsafe extern "C" fn boot_rust() -> ! {
    let resources = hal::BootResources {
        // SAFETY: single call site, reached once, before any other code has
        // touched the PL011 or issued a PSCI call.
        console: unsafe { BootConsole::new(platform::UART0_BASE) },
        power:   unsafe { PowerControl::new() },
    };
    crate::kernel_main(resources)
}
```

No `take()`, no `Once`, no atomic flag: uniqueness is a property of the control flow, which has
exactly one path here, and not of a runtime guard that would itself be a global.

**`arch/aarch64/pl011.rs`:**

```rust
pub struct BootConsole {
    base: *mut u8,          // private: no safe construction outside this module
}

impl BootConsole {
    const DR: usize = 0x000;
    const FR: usize = 0x018;
    const FR_TXFF: u32 = 1 << 5;

    /// # Safety
    /// `base` must be the MMIO base of a PL011 that no other code touches, and
    /// this must be called at most once for that device.
    pub const unsafe fn new(base: usize) -> Self { /* ... */ }
}

impl hal::Console for BootConsole { fn write(&mut self, bytes: &[u8]) { /* ... */ } }
```

Per byte: read FR volatile, spin while `FR_TXFF` is set, then write the byte to DR volatile. Polling
rather than writing blind is not optional — a blind write is correct only while the FIFO has room,
and the failure mode is silent truncation at an unpredictable length, discovered by whoever first
prints something substantial rather than by whoever wrote it.

No initialisation of LCR_H, IBRD, FBRD or CR is performed. QEMU's PL011 transmits without it (the
boot contract says so explicitly), on real hardware the firmware has already configured the port it
was printing its own messages on, and writing a configuration sequence nobody can test against real
hardware is not something M0 should do.

The private `base` field is what makes a `BootConsole` unforgeable in safe code: holding one is
evidence that someone entitled to create it did.

**`arch/aarch64/psci.rs`:**

```rust
pub struct PowerControl { _private: () }

impl PowerControl {
    /// # Safety
    /// The platform's PSCI conduit must be HVC and callable from the current
    /// exception level. True for QEMU virt entered at EL1; see RFC-0001 O-3.
    pub const unsafe fn new() -> Self { Self { _private: () } }
}

impl hal::Power for PowerControl {
    fn off(self) -> ! {
        // SAFETY: SMC32 SYSTEM_OFF takes its function ID in x0. QEMU virt
        // implements PSCI at the HVC conduit when the guest runs at EL1 with
        // no EL2 and no secure firmware, which is the contract's configuration.
        unsafe { asm!("hvc #0", in("x0") 0x8400_0008u64, options(nomem, nostack)) };
        // Unreachable if PSCI honoured the call. Reached only if it did not, in
        // which case halting is correct and `options(noreturn)` would have been
        // an unsound claim.
        Processor::halt()
    }
}
```

**`arch/aarch64/cpu.rs`:**

```rust
pub struct Processor;

impl hal::Cpu for Processor {
    fn halt() -> ! {
        unsafe { asm!("msr daifset, #0xf", options(nomem, nostack)) };
        loop { unsafe { asm!("wfi", options(nomem, nostack)) } }
    }
}
```

`wfi` rather than a spin: it is what the instruction is for, and a bare `loop {}` would trip
`clippy::empty_loop` under `-D warnings`.

**`arch/aarch64/fail.rs`** — the failure path, and the only place outside `boot_rust` that mints a
device:

```rust
pub struct Failure;

impl hal::FailStop for Failure {
    /// # Safety
    /// Callable only from the panic handler. See RFC-0001, invariant 1.
    unsafe fn fail_stop(bytes: &[u8]) -> ! {
        // SAFETY: the kernel has already failed and this function never
        // returns, so no other owner of the PL011 or of PSCI will run again.
        // Aliasing them here cannot race with anything.
        let mut console = unsafe { BootConsole::new(platform::UART0_BASE) };
        console.write(bytes);
        unsafe { PowerControl::new() }.off()
    }
}
```

Four lines, no static, no accessor, no formatting. `PowerControl::off` ends in `Processor::halt()`,
so a machine whose PSCI call does not honour `SYSTEM_OFF` stops rather than continuing after a panic.

### 5. Linker script

`kernel/src/arch/aarch64/link.ld`:

```ld
ENTRY(_start)

KERNEL_BASE = 0x40080000;   /* QEMU virt RAM base + 512 KiB. The offset is the
                               aarch64 Linux boot protocol's convention, and it
                               is where QEMU leaves room for the device tree it
                               builds at the RAM base. */
STACK_SIZE  = 0x10000;      /* 64 KiB */

SECTIONS
{
    . = KERNEL_BASE;

    .text : ALIGN(8) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
    .rodata : ALIGN(8) { *(.rodata .rodata.*) }
    .got    : ALIGN(8) { *(.got) *(.got.plt) }
    .data   : ALIGN(8) { *(.data .data.*) }

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
```

Four properties this script must hold, all budget-relevant because `ci/build.sh --size` measures
`objcopy -O binary`, not the ELF:

1. **Every NOBITS section is last.** `objcopy -O binary` skips NOBITS sections but pads across them
   if a loadable section follows at a higher address. `.bss` and `.stack` after everything else means
   a 64 KiB stack costs zero bytes of image.
2. **Every allocated PROGBITS section is placed explicitly.** An orphan section LLD places after
   `.bss` reintroduces the padding in (1). `.got` is listed for that reason, even though a
   `relocation-model = static` build should not produce one. Verify with `readelf -S`.
3. **No page alignment.** `ALIGN(8)` and `ALIGN(16)` only. Page alignment arrives with the MMU at
   M1/M2 and will cost budget then; it buys nothing with the MMU off.
4. **`__bss_start` and `__bss_end` are 8-byte aligned**, which is what makes the seven-instruction
   zeroing loop in `_start` correct.

### 6. Build wiring

**`kernel/build.rs`** is the second and last place that names an architecture:

```rust
use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();

    let script = match arch.as_str() {
        "aarch64" => manifest.join("src/arch/aarch64/link.ld"),
        other => panic!("no linker script for target architecture `{other}`"),
    };

    println!("cargo::rustc-link-arg=-T{}", script.display());
    println!("cargo::rustc-link-arg=--nmagic");
    println!("cargo::rustc-link-arg=--gc-sections");
    println!("cargo::rerun-if-changed={}", script.display());
    println!("cargo::rerun-if-changed=build.rs");
}
```

**Why a build script and not `kernel/.cargo/config.toml`.** Cargo discovers `.cargo/config.toml` by
walking up from the *current directory*, not from the manifest. `ci/build.sh` runs

```
cd "$REPO_ROOT"; cargo build --release --manifest-path kernel/Cargo.toml --target "$TARGET"
```

so `kernel/.cargo/config.toml` is **not read**. Verified empirically: a config setting `rustflags`
under a package directory took effect when cargo was invoked inside that directory and was silently
ignored when invoked from the parent with `--manifest-path`. Putting the linker script there would
produce a kernel that links correctly for a developer and differently — or not at all — in CI, from
identical sources. `CARGO_MANIFEST_DIR` gives a build script an absolute path regardless of where
cargo was invoked; verified working from the parent directory.

The `cargo::` double-colon form is deliberate: unknown keys are a hard error, so a typo fails the
build rather than becoming inert metadata. Verified.

**`--nmagic` is not optional.** LLD's default max-page-size for AArch64 is 64 KiB and it aligns
PT_LOAD segments to it. Without `--nmagic`, `.rodata` and `.data` land on separate 64 KiB boundaries
and `objcopy -O binary` emits the gaps: a kernel of a few kilobytes measures over 128 KiB against
nano's 192 KiB budget. This is the largest budget risk in M0 and it is entirely a link-flag question.

If `kernel/.cargo/config.toml` exists at all, it may contain nothing but
`[build] target = "aarch64-unknown-none-softfloat"` as a developer convenience. Anything affecting
the produced artefact belongs in `build.rs`, because only `build.rs` is read by CI.

**`kernel/Cargo.toml`:**

```toml
[package]
name = "skynet-kernel"          # ci/lib.sh:kernel_binary() depends on this exact name
version = "0.1.0"
edition = "2024"
rust-version = "1.88"           # #[unsafe(naked)] / naked_asm!
publish = false
build = "build.rs"

[[bin]]
name = "skynet-kernel"
path = "src/main.rs"

[profile.release]
opt-level = "s"
lto = true
codegen-units = 1
panic = "abort"                 # already the target default; stated so it cannot drift
overflow-checks = true
debug = false
strip = false                   # keeps .symtab for ci/boot-test.sh --gdb, and costs
                                # nothing: the budget is taken from objcopy -O binary,
                                # which never contains a symbol table
```

No `[dependencies]`, `[build-dependencies]` or `[dev-dependencies]` sections exist — not even empty
ones. `build.rs` uses only the host `std`, which is not a manifest dependency and ships nothing into
the kernel image.

`overflow-checks = true` in release is deliberate for a kernel intended to run in cars. Its failure
mode at M0 is the silent halt described above; that is a cost, recorded in O-4 rather than avoided by
turning the checks off.

If the link reports undefined `memcpy`, `memset` or `memcmp`, they are written in a new portable
module `kernel/src/mem.rs` and never obtained from a crate. `rust-std` for `*-none` targets normally
ships `compiler_builtins` with these as weak symbols, so this is expected to be unnecessary; it is
stated so the implementer does not reach for a dependency under time pressure.

### 7. Boot sequence, end to end

1. QEMU loads the ELF at `0x4008_0000`, builds a device tree at `0x4000_0000`, resets the CPU (all
   general-purpose registers zero) and sets PC to `_start`. Entry is at EL1.
2. `_start` masks D, A, I and F; zeroes `.bss`; loads `__stack_top`.
3. It reads `CurrentEL`. At EL2 it sets `HCR_EL2.RW`, `SCTLR_EL1`, `SPSR_EL2`, `ELR_EL2` and `SP_EL1`
   and `eret`s to EL1h. At EL1 it writes `SCTLR_EL1` and `isb`s. Anything else parks.
4. It sets SP and branches to `boot_rust`.
5. `boot_rust` mints `BootConsole` and `PowerControl`, packs them into `BootResources`, and calls
   `kernel_main`.
6. `kernel_main` writes `SKYNET_BOOT_OK\n` to the console and consumes `power` with `off()`.
7. `off()` issues `hvc #0` with x0 = `0x8400_0008`. QEMU calls
   `qemu_system_shutdown_request(SHUTDOWN_CAUSE_GUEST_SHUTDOWN)` and exits 0.
8. `ci/boot-test.sh` greps the log for the marker and checks the exit code. Both pass.

## Non-goals

Everything in `roadmap/0001-foundations.toml` `non_goals` applies unchanged. In addition, the
following are explicitly outside this RFC, so a patch containing them is scope creep and not a matter
of opinion:

- **Device tree parsing.** M0 uses fixed addresses from `platform.rs`. x0 is not read and not
  threaded to `kernel_main`: it is zero, and preserving a register that does not contain what the
  contract claims would be preserving a fiction. See O-2.
- **An exception vector table.** `VBAR_EL1` is not set. Interrupts are masked at entry, so only a
  synchronous exception can occur, and at M0 that means a kernel bug. The CI outcome is identical
  either way — an exception loop and a halt both produce a 30-second timeout and a FAIL — so a 2 KiB
  table plus up to 2 KiB of alignment padding buys only debugger convenience today. It is the first
  thing M1 should add, in `arch/aarch64/vectors.rs`.
- **Secondary-core parking.** No `MPIDR_EL1` check. QEMU starts every non-primary CPU
  `start-powered-off` whenever the PSCI conduit is enabled, which it is here, so a park loop would be
  unreachable code in the privileged image. SMP is M2's problem and belongs with the code that will
  actually bring cores up.
- **MMU, caches, page tables, TLB management.** The kernel runs with `SCTLR_EL1.M = 0`, which makes
  every data access Device-nGnRnE. `+strict-align` in the target keeps the compiler from emitting
  unaligned accesses, which would fault in that state.
- **FP and SIMD.** The target is softfloat with `-neon`, so no FP or SIMD instructions are emitted
  and `CPACR_EL1` is never touched.
- **Formatted output.** No `core::fmt`, no `write!`, no `print!` macro, no `console.rs`. M0 writes two
  constant byte strings, one on success and one on failure, and never formats anything. `core::fmt`
  is a size cost, in macro form it is the usual vector for a global console, and in the panic path it
  is an outward channel carrying whatever the failure was holding — see invariants 1 and 5.
- **Panic diagnostics.** `PanicInfo` is ignored: no message, no file, no line, no backtrace. The
  panic path emits its marker and stops. See O-4.
- **Unit tests and a `kernel/tests/` directory.** `ci/build.sh --test` runs `cargo test` for the
  *host*, which a `no_std`/`no_main` binary crate cannot satisfy. M0 defines no `#[cfg(test)]`, so the
  check reports SKIP, which is honest: there is no portable logic here to test on a host, and the
  behaviour is exactly what `ci/boot-test.sh` exercises. See O-5.
- **Timers, `CNTVOFF_EL2`, `CNTHCTL_EL2`.** No timekeeping at M0.
- **Real hardware, UART initialisation, UART receive, other boards.** QEMU virt only, per the
  objective.
- **Any capability object, address space, scheduler or process.** M3 and M4 territory.

## Constitutional impact

### Invariant 6 — HAL boundary *(enforced from M0)*

This RFC is largely about this invariant. Architecture-specific material is confined to
`kernel/src/arch/`: the assembly, the register names, `0x0900_0000`, `0x8400_0008`, the linker script
and its addresses. Portable code (`main.rs`, `hal.rs`, `panic.rs`) contains none of the six forbidden
constructs and no address literal.

The mechanical check has a property implementers must know about. It filters hits with
`grep -v '^\s*//'` applied to `grep -rnF` output, and that output begins with the file path, so the
comment filter never matches. **A comment mentioning `asm!`, `naked_asm!`, `global_asm!`,
`core::arch::`, `#[naked]` or `target_arch` outside `kernel/src/arch/` will fail gate condition 6.**
Portable files must therefore describe these concepts in prose without naming them. That is a defect
in `ci/constitution-check.sh`, not in the invariant; the architect cannot edit `ci/` and records it
here and in O-6.

A second observation, offered as an note rather than a request: `forbidden_outside_hal` lists
`#[naked]`, the pre-1.88 spelling. The stable spelling is `#[unsafe(naked)]` and does not contain that
substring. Coverage survives only because a naked function must also contain `naked_asm!`, which is
listed.

Beyond the letter, the spirit: no trait method takes a parameter that only makes sense on aarch64.
`Console::write` takes bytes, `Power::off` takes nothing, `Cpu::halt` takes nothing. No portable
structure assumes a page size, an interrupt model, or a word size beyond what `usize` already implies.
`main.rs`, `hal.rs` and `panic.rs` would compile unchanged against a second architecture — criterion
C21 makes that a review item rather than a hope.

### Invariant 7 — No kernel dependencies *(enforced from M0)*

`kernel/Cargo.toml` declares no dependency sections at all, and a single crate rather than a
workspace keeps `kernel/Cargo.lock` resolving exactly one package. `core` and `compiler_builtins`
come from the sysroot and are not manifest dependencies. Nothing here is copied from an existing
crate: the PL011 sequence, the exception-level drop and the PSCI call are each a handful of
instructions written from the QEMU source and the architecture reference, not vendored.

### Invariant 4 — Frugality, per profile *(enforced from M0)*

The measured artefact is `objcopy -O binary` of the release ELF, against 384 KiB (standard) and
192 KiB (nano). The design targets the smaller number by construction: `opt-level = "s"`, LTO, one
codegen unit, `--gc-sections`, no `core::fmt`, no vector table, one device driver. The expected image
is a few kilobytes; the margin is not an invitation.

The two ways M0 could still miss the budget are both link-level and both handled above: a missing
`--nmagic` (64 KiB segment alignment, roughly 128 KiB of padding) and NOBITS sections placed before
loadable ones (the 64 KiB stack becoming 64 KiB of image). Both appear in the conformance criteria so
they are checked rather than assumed.

Nothing here fits `standard` but not `nano`. The kernel is the same kernel on both.

### Invariant 1 — No ambient authority *(pending, enforced from M4)*

This is the section this RFC most wants scrutinised, and the honest framing is: at M0 there is no
capability system, so nothing here can *implement* invariant 1. What it can do is refuse to build the
structures that make it unreachable.

**What the design does not contain, deliberately:**

- No `static` or `static mut` anywhere in `kernel/src`, including `arch/`. Linker symbols are
  referenced from assembly, not declared as Rust statics, which is why the count is zero and not
  "zero except three".
- No lazily-initialised singleton, no `Once`, no atomic "already taken" flag. Those are globals with
  a guard, and the guard is not the part invariant 1 objects to.
- No accessor of the form `arch::console()` or `Platform::current()`, and no free function such as
  `arch::console_write_byte` or `arch::shutdown`. There is no function anywhere that returns
  authority to whoever calls it. This is the sharpest difference between the trait-based HAL and the
  free-function HAL considered in *Alternatives*: two public free functions in `arch/` are, precisely,
  two pieces of authority reachable by position from every line of the kernel.
- No `print!`/`println!` macro. This is the specific thing that ends the discussion in most kernels:
  once it exists, every line can talk to the outside world by virtue of being kernel code, and by M4
  removing it means touching every file. M0 does not create one, and M1 should not either without
  deciding what backs it.
- No `arch::init()` that stores handles somewhere for later retrieval.

**What it contains instead:** device tokens are values with private fields, created by `unsafe fn`s
at one call site in the boot path, moved into `kernel_main`, and — for `Power` — consumed by use.
Ownership does the work a capability will later do: unforgeable, because safe code cannot construct
one; delegable, because it can be moved; and, for `Power`, single-use. Attenuation, revocation and
expiry are not expressible in this shape, and this RFC does not claim otherwise. `BootResources` is a
precursor to capabilities, not an implementation of them.

**Where this design could still go wrong, stated now so it is on the record:** `BootResources` is a
bundle handed wholesale to `kernel_main`. With two devices that is a parameter list; with twenty it
becomes a root from which authority descends by position — the exact shape invariant 1 forbids,
merely inside the kernel rather than across a syscall boundary. The intended evolution is that
`BootResources` remains a *boot-time* artefact, decomposed at the top of `kernel_main` and handed to
the subsystems that need each piece, and never becomes a registry, a lookup table, or a long-lived
value later code reaches into. If a future RFC adds a method to `BootResources` returning a device by
name or index, that is the moment this went wrong.

The boot path is bootstrap code in the sense reviewer-constitution's prompt allows: it runs before
any capability system can exist and is unreachable afterwards — `_start` is entered once, from reset,
and `boot_rust` never returns. The exemption is used for the code that genuinely precedes
capabilities and for nothing else.

**The one exception, named rather than buried.** `FailStop::fail_stop` mints a console and a
`PowerControl` from compile-time constants instead of receiving them. It is the only place in the
kernel that creates authority outside the boot path, and it exists because `#[panic_handler]` is the
one function signature the language will not let anything be passed to.

The case for allowing it is that it is the mirror image of the bootstrap exemption. Bootstrap code is
exempt because it runs before capabilities can exist and is unreachable afterwards; `fail_stop` runs
after everything else has stopped mattering and is likewise unreachable afterwards — it never
returns, and by the time it runs the kernel has already failed. It is also bounded in every direction
that matters:

- one function, called from one place, which is the panic handler;
- it emits one compile-time constant and cannot be asked to emit anything else, because the only
  caller passes `PANIC_MARKER` and there is no second caller;
- it is not a `Console` and does not implement `Console`, so it cannot be used for ordinary output;
- it never returns, so nothing can be built on top of it;
- there is still no `static`, no accessor and no namespace to walk. Nothing *reaches* authority
  through it; it does one terminal thing.

The case against it, which a reviewer is entitled to press: it establishes that kernel code may
construct a device from an address constant when it finds that convenient. If that pattern is used a
second time, ownership has stopped meaning anything and this RFC's whole invariant 1 argument
collapses. **The rule this design asserts is that `fail_stop` is the only such site, and that a
second one is not a code review comment but a design failure requiring an RFC.** Mechanically, that
rule is criterion C23: `BootConsole::new` and `PowerControl::new` have exactly two call sites between
them each, in `boot.rs` and `fail.rs`, and nowhere else.

**Answering the question directly — when the capability system exists, will this have to be
rewritten?** `hal::Console` and `hal::Power` become the interfaces a capability *wraps*; the traits
survive. `BootResources` is replaced by whatever mints the initial capability set, a change to one
struct and one call site. `Power::off(self)` is already the right shape. `FailStop` survives as-is,
because the failure path is precisely where a capability check is indefensible — a check that can
itself fail is worse than no check when the thing being reported is that the kernel has already
failed. The piece that will need real work is the eventual richer diagnostic path, which is why O-4
flags it before it is built rather than after.

### Invariant 2 — User sovereignty *(pending, enforced from M5)*

*See.* This kernel emits exactly two things, both compile-time constants, both on the console the
operator is already watching: `SKYNET_BOOT_OK` when it is alive and `SKYNET_PANIC` when it is not.
There is no hidden channel, no retained state, no persistence of any kind, and no third path by which
anything else could reach the console. A machine that stops says so, which is the smallest honest
version of "see" that M0 can provide. What it does not yet say is *why* it stopped; that needs a
diagnostic design rather than a `write!`, and it is O-4.

*Revoke.* The design creates no cached authority. A device token is held by exactly one owner, in one
place, reachable through the call graph rather than through a global. That is the precondition for
revocation ever meaning anything: you cannot revoke what anyone can re-acquire from a static. A
kernel that had started with `static CONSOLE` would have made revocation impossible for the console
specifically — and the console is the operator's own channel, the worst possible thing to have
un-revokable.

*Refuse.* Nothing here performs an attested action, so there is no attestation point to omit.

Nothing in this design requires the operator to trust an update, a vendor or a manufacturer, and
nothing creates a code path that could later become conditional on one.

### Invariant 5 — Zero telemetry *(pending, enforced from M6)*

There is no network stack and no outbound path other than the boot console, which is the operator's
own terminal. Worth stating plainly because it will matter later: the boot console *is* an outward
channel. At M0 it carries exactly two compile-time constants, both named by CI and both visible in
the source. It is already modelled as an owned resource rather than an ambient one, which is what
will make it possible to place it behind a capability at M6 instead of discovering it is everywhere.

The panic path is where this invariant would normally start leaking, and the design closes it
deliberately: `_info` is ignored, so no panic message, no source location, no register state and no
value from the failing computation reaches the wire. A panic emits the same fourteen bytes whatever
caused it. That is also why `core::fmt` is absent — a formatter in the failure path is a channel that
carries whatever the failure happened to be holding.

No counters, no timing measurements, no diagnostic accumulators. `overflow-checks = true` produces a
panic marker and a shutdown, not a report.

### Invariant 3 — Total provenance *(enforced now)*

Nothing in this design impedes it. The contribution record must set `rfc = "0001"`; `ci/gate.sh` reads
that field and writes it into the ledger line. This RFC records one thing that is *not* true of the
environment the boot contract describes — x0 does not hold a DTB pointer — because a record that is
merely well-formed is not the same as one that is true.

### Invariant 10 — English repository *(advisory in CI, binding in review)*

All identifiers, comments and documents in English.

## Conformance criteria

**Mechanical — the gate runs these.**

| # | Command | Required result |
| --- | --- | --- |
| C1 | `ci/build.sh` | PASS; `kernel/target/aarch64-unknown-none-softfloat/release/skynet-kernel` exists |
| C2 | `ci/build.sh --lint` | PASS; clippy clean under `-D warnings` |
| C3 | `ci/build.sh --test` | SKIP (no unit tests at M0). Must not FAIL |
| C4 | `ci/boot-test.sh` | PASS on all three: `SKYNET_BOOT_OK` present, `SKYNET_PANIC` absent, QEMU exited 0 |
| C5 | `ci/build.sh --size` | PASS |
| C6 | `SKYNET_PROFILE=nano ci/build.sh --size` | PASS — under 196608 bytes |
| C7 | `ci/constitution-check.sh --check hal-boundary` | PASS |
| C8 | `ci/constitution-check.sh --check no-kernel-deps` | PASS |

**Mechanical — additional, checkable by anyone with a shell.**

- C9. `grep -rn 'static mut' kernel/src` is empty, and no `static` item of any kind exists in the
  kernel (`const` declarations are not statics and are permitted).
- C10. `grep -rn 'target_arch' kernel/src kernel/build.rs` returns exactly two locations:
  `kernel/src/arch/mod.rs` and `kernel/build.rs` (as `CARGO_CFG_TARGET_ARCH`).
- C11. `grep -rc 'SKYNET_BOOT_OK' kernel/src` totals 1, and the hit is in `kernel/src/main.rs`.
  `grep -rc 'SKYNET_PANIC' kernel/src` totals 1, and the hit is in `kernel/src/panic.rs`. Both
  markers live in portable code, because both are project contracts rather than facts about aarch64.
- C12. `python3 -c "import tomllib;d=tomllib.load(open('kernel/Cargo.toml','rb'));print([k for k in d
  if 'dependencies' in k])"` prints `[]`.
- C13. `grep -c '^\[\[package\]\]' kernel/Cargo.lock` is 1.
- C14. `readelf -S` on the built ELF shows no PROGBITS section at or above `__bss_start`, and the
  `objcopy -O binary` output is within a few kilobytes of `.text + .rodata + .data` — proving
  `--nmagic` took effect and no padding was emitted.
- C15. `grep -rnE 'asm!|naked_asm!|global_asm!|core::arch::|#\[naked\]|target_arch' kernel/src |
  grep -v '^kernel/src/arch/'` is empty, **including comments** (see the invariant 6 section).
- C16. `nm` on the built ELF places `_start` at `0x40080000`.
- C17. Building for an unsupported `--target` fails with the `compile_error!` from
  `kernel/src/arch/mod.rs` or the `panic!` from `build.rs`, not with a linker error.

**REVIEW — judgement, stated in advance so nobody is ambushed by it.**

- C18. No architecture detail appears in the public interface of `hal.rs`. No trait method has a
  parameter or return type that only makes sense on aarch64.
- C19. Every `unsafe` block and every `unsafe fn` carries a `# Safety` or `// SAFETY:` comment naming
  the invariant that makes it sound — not a restatement of what the code does — and that invariant is
  actually upheld on every path reaching it.
- C20. No global, no singleton, no accessor returns authority. Every device is reached only through a
  value that was passed in. (Approximated mechanically by C9; the judgement is whether some other
  shape of ambient reach was invented.)
- C21. `kernel/src/main.rs`, `hal.rs` and `panic.rs` would compile unmodified against a second
  architecture.
- C22. The panic handler performs no I/O and does not power the machine off.

## Alternatives considered

**A module-shaped HAL instead of traits** — `arch::console_write_byte(u8)`, `arch::shutdown() -> !`,
re-exported through `hal.rs`. This was the most tempting option by a wide margin: it is smaller, needs
no generics, needs no const assertion, and every existing small kernel is written this way. The
argument for it is real — a trait with one implementation is a layer whose only content is
indirection, and the migration cost later is confined to two files.

It was rejected for two reasons that compound. First, the contract it defines is implicit: a module
satisfies its callers, so "the HAL" silently becomes "whatever M0 called", and a second port
satisfies it by accident rather than by construction. Second, and decisively, two public free
functions in `arch/` *are* ambient authority — the ability to write to the console and to power the
machine off, reachable by position from every line of the kernel, with no token and no owner. The
free-function HAL does not merely postpone invariant 1; it starts the codebase on the far side of it.
The trait version costs about fifteen lines and zero bytes.

**A `Platform` trait with associated types** — one trait with `type Console`, `type Power`,
`type Cpu`, and `arch::Platform` as the single concrete type. More conventional, and genuinely better
once there are ten device classes. Rejected as premature at M0: it adds a layer whose only current
job is to name three types `arch/mod.rs` already re-exports. Worth revisiting at M1, when the device
tree introduces a real board-versus-architecture distinction.

**A global console, honestly declared** — a `static` behind an accessor, documented as the kernel's
one ambient authority, with `print!` on top and `core::fmt::Write` in a portable `console.rs`.
Tempting because the diagnostic value is immediate: a panic could say what happened, boot could
narrate itself, and every subsequent milestone would be easier to debug. Rejected because it is the
single decision most likely to make invariant 1 unreachable, and because "documented as the one
exception" is how every ambient-authority system begins. The cost of refusing is real and is recorded
in O-4 rather than hidden.

**Panic handler prints a marker and powers off** — attractive because a panic would fail CI in
milliseconds rather than after a 30-second timeout, and because `ci/boot-test.sh` could then assert
"boot marker present and panic marker absent", which fails closed in both directions. Rejected on
authority rather than merit: asserting the panic marker requires editing `ci/boot-test.sh`, which
neither the architect nor the implementer may touch, and a design whose correctness depends on an
edit outside its own authority cannot be judged as written. Without that edit the scheme is actively
harmful — a panic after the marker exits 0 and is scored a pass. If `ci/` is changed by someone who
may change it, this becomes the better design and should be adopted then.

**Writing the marker with a blind store to `UARTDR`** — three instructions shorter and correct until
the first output longer than the FIFO. Rejected because the failure mode is silent truncation at an
unpredictable length, discovered by whoever first prints something substantial rather than by whoever
wrote it.

**Semihosting for the exit status** — would give QEMU a real exit code rather than inferring success
from console content plus PSCI. Rejected: it makes the kernel depend on a debugger-adjacent facility
absent on real hardware, and the boot contract already specifies PSCI, which is the mechanism a real
machine uses.

**`kernel/.cargo/config.toml` for the linker script** — the standard embedded-Rust arrangement, and
the empty `kernel/.cargo/` directory in the repository suggests it was the expected one. Rejected on
evidence: cargo resolves that file relative to the invoking directory, and `ci/build.sh` invokes
cargo from the repository root with `--manifest-path`. It would work for a developer inside `kernel/`
and be ignored by CI — identical sources producing different artefacts depending on where the build
ran, which is the worst available outcome for a project whose central claim is reproducible
provenance.

**A raw binary as the boot artefact instead of an ELF** — QEMU would then treat the image as a Linux
kernel, restoring x0 as a DTB pointer and making the boot contract's description true. Rejected
because `ci/lib.sh:kernel_binary()` names the ELF and `ci/boot-test.sh` passes exactly that path to
`-kernel`; producing a different artefact requires changing `ci/`. It is the likely resolution of O-2
and should be considered on its merits at M1, not worked around now.

**An exception vector table at M0** — argued for on the grounds that a kernel for cars should never
run with `VBAR_EL1` unset. What decided it: with interrupts masked, the only reachable exception is a
synchronous fault caused by a kernel bug, and the observable CI outcome is a 30-second timeout either
way. It buys debugger convenience, not safety, and costs up to 4 KiB in the privileged image. Named
as M1's first item so the decision is deferred, not lost.

## Open questions

**O-1 (blocking, environment).** The reference machine cannot link this kernel. The target's default
linker is `rust-lld`, and Fedora's `rust` package ships no such binary (`/usr/lib/rustlib/*/bin/` does
not exist; `rust-std-static-aarch64-unknown-none-softfloat` contains only `lib/*.rlib`). No mechanism
inside `kernel/` can fix it: build scripts have no `rustc-linker` directive — verified, cargo rejects
it as an unknown key — and `kernel/.cargo/config.toml` is not read by `ci/build.sh`. Three options,
none of which the architect or the implementer has the authority to enact:

1. Export `CARGO_TARGET_AARCH64_UNKNOWN_NONE_SOFTFLOAT_LINKER` in the environment CI runs in. GNU
   `ld` from binutils is aarch64-capable on this aarch64 host; `ld.lld` from the `lld` package also
   works. Smallest change, but it lives outside the repository, which sits badly with provenance.
2. A repository-root `.cargo/config.toml` with a `[target.…] linker` key. Cargo *does* read this one,
   because `ci/build.sh` runs from the repository root. Requires the BDFL: no agent role may write
   there.
3. One line in `ci/build.sh` to run cargo from inside `kernel/`, which would make
   `kernel/.cargo/config.toml` authoritative for CI and developers alike and would also make
   `build.rs` unnecessary. The cleanest durable fix, and a change to `ci/`.

Related: `ci/lib.sh`'s `INSTALL_HINT` names no linker, so a fresh machine that follows it gets a
PENDING toolchain check followed by a failing build.

**O-2.** `ci/boot-test.sh --contract` states `x0 = device tree blob pointer`. Verified against QEMU's
`hw/arm/boot.c`, that holds for a raw `Image` and not for the ELF the contract itself specifies. M0
does not care. M1 will, the moment it wants a device tree. Resolving it means changing the artefact
(see *Alternatives*), reading the DTB from its observed placement at `0x4000_0000` (fragile — QEMU's
placement rule depends on where the image links), or correcting the contract. The architect cannot
edit `ci/`.

**O-3.** The EL2-to-EL1 drop is written for robustness on hardware, but it is untestable under the
boot contract, which always enters at EL1 — and if it *were* exercised on QEMU virt with
`virtualization=on`, PSCI would not work, because QEMU sets the conduit to SMC in that configuration
and `arm_load_kernel` disables an HVC conduit whenever the boot EL is 2 or above. The EL2 path is
therefore correct for entry and wrong for shutdown, and nothing in CI will notice. Is untested
robustness code in a privileged path worth its bytes? The alternative is to reject any entry that is
not EL1, which is smaller and more honest but fails on real hardware that boots at EL2. This RFC
keeps the drop and flags it; a reviewer may reasonably disagree.

**O-4.** The panic handler is silent, by design and at a real cost, and the same is true of any
failure between reset and the first UART write — there is no way to report it and it is
indistinguishable from a hang. An operator, and invariant 2's "see", eventually need to know why a
kernel stopped. When a diagnostic path is designed it must not be an unrestricted global console. The
shape this RFC would suggest is a single write-only emergency sink installed once by the boot path,
explicitly documented as the kernel's one ambient authority, strictly narrower than `Console`, and
unusable for ordinary output. That deserves its own RFC, and it should happen before the first
`print!` macro is proposed rather than after. The pre-console case probably needs a watchdog and
becomes tractable at M2.

**O-5.** `ci/build.sh --test` runs `cargo test --manifest-path kernel/Cargo.toml` with no `--target`,
i.e. for the host, guarded by a grep for `#[cfg(test)]` or `[[test]]` under `kernel/src` and
`kernel/tests`. A `no_std`/`no_main` binary crate cannot be built for the host, so the moment anyone
adds the first `#[cfg(test)]` the check stops being SKIP and becomes FAIL. The shape of the answer —
a host-testable library crate, or `#[cfg(not(test))]` gating of `no_std`, `no_main` and the panic
handler — should be settled *before* the first unit test is written, because retrofitting it means
restructuring the crate. Out of scope for M0, named here so it is not discovered by whoever writes
test number one.

**O-6.** Two defects in the mechanical checks, recorded because the architect cannot fix them.
`ci/constitution-check.sh` applies `grep -v '^\s*//'` to `grep -rnF` output whose lines begin with a
file path, so the comment exclusion never matches and any comment mentioning a forbidden construct
outside `kernel/src/arch/` fails gate condition 6. And `forbidden_outside_hal` lists `#[naked]`,
which is not the stable spelling (`#[unsafe(naked)]`); coverage survives only because `naked_asm!` is
also listed.

**O-7.** The PL011 write path spins on `FR.TXFF` with no bound. Under QEMU the flag is effectively
never set, so this is theoretical today, but an unbounded wait on a device flag in a boot path is
exactly the kind of thing that becomes a hang in a car ten years from now. Bounding it needs a notion
of time, which M0 does not have, and dropping bytes on timeout would make the marker check flaky. It
interacts with the boot-duration budget enforced from M2 and should be settled then.
