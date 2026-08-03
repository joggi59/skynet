# RFC-0001: aarch64 boot

- Objective: 0001 (sovereign foundations)  Status: draft
- Author: architect                        Model: claude-opus-5[1m]
- Milestone: M0

## Motivation

Nothing runs. There is a constitution, a forge, and a gate that can judge contributions, but no kernel
for them to judge.

M0 is the smallest thing that makes every later milestone possible: a kernel that boots on aarch64
under QEMU `virt`, announces itself on the console, and shuts down deliberately. That last part is
what makes it testable — a kernel that spins forever after printing cannot be distinguished from one
that hung, so "it printed something" is not evidence that it works.

The objective's `common_good` names three properties that are almost impossible to retrofit:
capability discipline, provenance, and portability discipline. Only the third is directly at stake
here, and it is at stake immediately: the HAL boundary either holds from the first commit or has
already leaked by the time anyone attempts a second architecture. This RFC therefore spends more of
its design budget on a seam that has nothing behind it yet than a 200-line kernel would normally
justify.

## Design

### Crate layout

A single crate, not a workspace. A workspace would introduce a shared `Cargo.lock` whose resolved
graph could acquire entries the kernel manifest does not declare, and invariant 7 is checked against
that graph.

```
kernel/
├── Cargo.toml
├── kernel.ld
├── .cargo/config.toml
└── src/
    ├── main.rs          #![no_std] #![no_main]; kernel_main
    ├── console.rs       portable: core::fmt::Write over the HAL byte sink
    ├── hal.rs           THE PORTABLE INTERFACE — the only thing portable code may call
    └── arch/
        ├── mod.rs       selects the implementation for the target
        └── aarch64/
            ├── mod.rs
            ├── boot.rs  _start, EL2→EL1, stack, BSS, secondary-core parking
            ├── uart.rs  PL011
            └── psci.rs  SYSTEM_OFF
```

`Cargo.toml` declares no dependencies of any kind. Release profile is tuned for size (`opt-level =
"s"`, `lto = true`, `codegen-units = 1`, `strip = true`) because the `nano` budget of 192 KiB is the
binding constraint, not `standard`'s 384 KiB.

Package name `skynet-kernel`, so the binary lands at
`kernel/target/aarch64-unknown-none-softfloat/release/skynet-kernel`, which is what
`ci/lib.sh:kernel_binary` looks for.

### The HAL boundary

This is the part worth arguing about.

`hal.rs` declares what portable code may use. It contains no architecture-specific construct and no
`cfg`. It is a re-export surface, and its shape is the contract:

```rust
// kernel/src/hal.rs
//
// The portable interface. Portable code calls this and nothing else.
// Widening this interface is a design decision; reaching around it is a
// constitutional violation (invariant 6).

pub use crate::arch::{console_write_byte, shutdown};
```

`arch/mod.rs` performs the selection, and is the only place a `cfg(target_arch)` appears:

```rust
// kernel/src/arch/mod.rs
#[cfg(target_arch = "aarch64")]
mod aarch64;
#[cfg(target_arch = "aarch64")]
pub use aarch64::{console_write_byte, shutdown};
```

Two decisions here deserve stating.

**Free functions, not a trait.** A `Platform` trait with only associated functions buys nothing at
M0: there is exactly one implementation, selected at compile time, and a trait would add a layer
whose only content is indirection. The cost of switching to a trait later — when a second
architecture or a runtime-selected platform appears — is a mechanical change confined to `hal.rs` and
`arch/mod.rs`. The cost of a premature trait is paid by every reader between now and then.

**A byte sink, not a formatter.** The HAL provides `console_write_byte`. Formatting lives in
`console.rs`, portable, implementing `core::fmt::Write` over that one primitive. This is the seam in
the right place: every architecture has a way to emit a byte; none of them should reimplement
`core::fmt`.

The surface at M0 is two functions. That is correct. A HAL designed for hardware nobody has attempted
is a guess, and the discipline being established here is that portable code cannot reach past the
seam — not that the seam is already wide.

### Boot path

QEMU's `-kernel` accepts an ELF and loads its segments at their physical addresses, entering at the
ELF entry point with `x0` holding the address of a device tree blob QEMU generated. On `virt` with
`virtualization=off` — the default — the CPU is created without EL2 and entry is at EL1.

`_start` is `#[unsafe(naked)]` with `naked_asm!`. Both are stable as of Rust 1.88; verified compiling
on the 1.97.1 toolchain this project targets. Sequence:

1. **Park secondary cores.** Read `MPIDR_EL1`; anything whose Aff0 is not zero enters a `wfe` loop.
   Under the default `-smp 1` this is dead code, but it costs four instructions and its absence is
   the kind of thing that produces a memorably confusing bug at M2.
2. **Drop to EL1 if entered at EL2.** Read `CurrentEL`. The default configuration enters at EL1 and
   this branch is not taken; it exists because `-M virt,virtualization=on` is one flag away and a
   kernel that silently misbehaves under it is worse than one that handles it. Configure `HCR_EL2`
   for AArch64 EL1, set `SPSR_EL2`, point `ELR_EL2` at the continuation, `eret`.
3. **Set the stack.** `SP` ← `__stack_top` from the linker script.
4. **Zero BSS**, `__bss_start` to `__bss_end`.
5. **Call `kernel_main(dtb: usize)`** with `x0` preserved throughout.

`x0` is passed through and named `_dtb` at M0. It is unused, and it is threaded anyway: the device
tree is how every later milestone learns what hardware it is on, and dropping it here would mean
recovering it later from a register that has long since been clobbered.

### Console

PL011 UART0 at `0x0900_0000`. Write to `UARTDR` (offset 0) after polling `UARTFR` (offset 0x18) for
`TXFF` (bit 5) clear.

No initialisation. QEMU's PL011 accepts writes without programming the baud rate divisors or enabling
the transmitter, and on real hardware the firmware has already configured the port it was printing
its own messages on. Initialising it at M0 would mean writing a configuration sequence nobody can
test against real hardware yet.

Polling `UARTFR` rather than writing blind is not optional. A blind write is correct only while the
FIFO has room, which is true for a short marker and stops being true the first time someone prints
a backtrace.

### Shutdown and panic

PSCI `SYSTEM_OFF`, function ID `0x8400_0008`, conduit HVC. QEMU exits 0.

```rust
pub fn shutdown() -> ! {
    const PSCI_SYSTEM_OFF: u64 = 0x8400_0008;
    // SAFETY: PSCI SYSTEM_OFF takes its function ID in x0 and does not return.
    // QEMU virt implements PSCI at the HVC conduit when the guest runs at EL1
    // with no EL2 and no secure firmware, which is the default configuration.
    unsafe { core::arch::asm!("hvc #0", in("x0") PSCI_SYSTEM_OFF, options(nostack)); }
    // Unreachable if PSCI honoured the call. Reached only if it did not, in
    // which case halting is the correct thing to do and `options(noreturn)`
    // would have been an unsound claim.
    loop { unsafe { core::arch::asm!("wfi", options(nomem, nostack)); } }
}
```

The panic handler prints `SKYNET_PANIC: ` followed by the panic message, then calls `shutdown()`.

This is the one place M0's design is not obvious. A panic that halts would be caught by the boot
test's timeout, correctly but thirty seconds later, on every panic, forever. A panic that shuts down
cleanly exits 0 and looks exactly like success to a test checking only the exit code. So the panic
must be *visible in the output*: the boot test asserts the boot marker is present **and** the panic
marker is absent. Fast, unambiguous, and it fails closed — a panic before the marker fails on the
missing marker, a panic after it fails on the panic marker.

This requires `ci/boot-test.sh` to check for the panic marker. That is a change to `ci/`, which the
implementer may not touch (invariant on role authority, `governance/roles.toml`), so it belongs to
the forge and must land before the implementation is judged.

### Linker script

Link at `0x4008_0000`: RAM base on `virt` is `0x4000_0000`, and the 512 KiB offset is the convention
the aarch64 Linux boot protocol establishes for the image, leaving the low region for the DTB and
whatever QEMU places there.

`.text.boot` is `KEEP`-ed first so `_start` is at the entry address. BSS bounds and a 16 KiB boot
stack top are exported as symbols.

## Non-goals

Explicitly outside this RFC. A contribution implementing any of these is out of scope regardless of
quality:

- Exception vectors, the MMU, page tables, any allocator — M1
- Interrupts, timers, the GIC, any scheduling — M2
- EL0, address spaces, system calls, user space — M3
- Capabilities, IPC — M4
- Parsing the device tree. `x0` is preserved and ignored.
- UART initialisation, baud rate configuration, receive
- Any architecture other than aarch64
- Real hardware. QEMU `virt` is sufficient and correct for this objective.
- Performance work of any kind

## Constitutional impact

**Invariant 6 — HAL boundary.** The central design concern, addressed above. Every architecture-specific
construct lives under `kernel/src/arch/`, including the single `cfg(target_arch)`. `main.rs` and
`console.rs` name no register, no address and no instruction.

**Invariant 7 — no kernel dependencies.** Empty manifest. `core::fmt::Write` is `core`, not a
dependency. Formatting is the one place a crate would normally be reached for, and it is the one
place `core` already suffices.

**Invariant 4 — frugality.** Release profile tuned for size. The binding budget is `nano`'s 192 KiB;
M0 should land in single-digit kilobytes, and the margin is not an invitation.

**Invariant 1 — no ambient authority (pending, M4).** M0 introduces two global entry points,
`console_write_byte` and `shutdown`, callable from anywhere with no capability check. This is
genuinely ambient authority, and it is worth being precise about why it is acceptable rather than
waving at "bootstrap".

The exemption is narrow: this is code that runs before a capability system exists and must remain
reachable only from privileged kernel context afterwards. When M4 lands, console output becomes a
capability held by whichever userspace component owns the console, and the kernel's direct access is
confined to the panic path — which is the one place ambient authority is defensible, because a
capability check during a panic is a capability check that can itself fail.

What M0 must **not** do, and does not: expose these through any interface a future non-kernel caller
could reach, or build any structure that assumes global console access. Two free functions in
`arch/` can be reduced to a capability-mediated service without restructuring anything. That is the
test this design is required to pass, and it does.

**Invariant 2 — user sovereignty (pending, M5).** No state is created that the ledger would later
need to record, and no action is taken that will need attestation. M0 is genuinely neutral here.

**Invariant 5 — zero telemetry (pending, M6).** The console is a local UART. No outward path exists
because no network stack exists.

**Invariant 3 — total provenance.** Satisfied by process, not by this design.

## Conformance criteria

Mechanically checkable:

1. `ci/build.sh` exits 0 for profile `standard`
2. `ci/build.sh --lint` reports zero clippy warnings
3. `ci/boot-test.sh` finds `SKYNET_BOOT_OK` on the console, does **not** find `SKYNET_PANIC`, and
   QEMU exits 0 within the timeout
4. `ci/build.sh --size` is within budget for `nano` (192 KiB), the tightest profile
5. `ci/constitution-check.sh --check hal-boundary` passes
6. `ci/constitution-check.sh --check no-kernel-deps` passes, and `kernel/Cargo.lock` resolves exactly
   one package

Requiring judgement:

7. `REVIEW:` `hal.rs` names no register, address, instruction or architecture. `main.rs` and
   `console.rs` are compilable, unmodified, against a hypothetical second architecture.
8. `REVIEW:` every `unsafe` block carries a `// SAFETY:` comment stating an invariant that is
   actually upheld on every path reaching it — not a restatement of what the code does.
9. `REVIEW:` nothing here makes invariant 1 harder to satisfy at M4, per the argument above.

## Alternatives considered

**A `Platform` trait instead of free functions.** The most tempting alternative, and rejected on
timing rather than merit: it is the right shape once there is a second implementation or a
runtime-selected platform, and premature at one. The migration is confined to two files. Committing
now to an abstraction whose requirements are unknown is how HALs acquire the shape of their first
implementation permanently.

**Writing the marker with a blind store to `UARTDR`.** Three instructions shorter and correct until
the first output longer than the FIFO. Rejected because the failure mode is silent truncation at an
unpredictable length, which is a genuinely unpleasant thing to debug and will be discovered by
whoever first prints something substantial rather than by whoever wrote it.

**Halting after panic instead of shutting down.** Simpler, and it makes every panic cost a
thirty-second timeout. Rejected in favour of a panic marker the boot test can see, which costs one
extra assertion in `ci/` and turns a timeout into an immediate, legible failure.

**Entering at EL2 and staying there.** QEMU's default does not enter at EL2, so this would be dead
code addressing a configuration we do not use. Rejected — but the *detection* is kept, because
`virtualization=on` is one flag away and the failure it produces is obscure.

**Semihosting for exit codes.** Would give a real exit status rather than inferring from console
content. Rejected: it makes the kernel depend on a debugger-adjacent facility absent on real
hardware, to solve a problem the panic marker solves inside the existing contract.

## Open questions

**The kernel's own error path before the console exists.** If `_start` fails between entry and the
first UART write, there is no way to report it and the failure is indistinguishable from a hang. M0
does not solve this and probably should not. It becomes tractable at M2 with a watchdog, and it is
recorded here so the eventual solution is a decision rather than a discovery.

**Whether `hal.rs` should be a trait, and when.** Deliberately deferred, argued above. The trigger is
the second architecture — M10. Whoever attempts that port should treat a `hal.rs` that has grown
awkward as expected rather than as a defect in this RFC.

**Where the DTB pointer should live once something uses it.** Threaded to `kernel_main` and dropped
at M0. Storing it in a global at M1 would be ambient authority of exactly the kind invariant 1
forbids. This needs an answer before M1, and this RFC does not have one.

**Whether `strip = true` is compatible with the debugging story.** It shrinks the artefact that gets
measured, and `ci/boot-test.sh --gdb` wants symbols. Probably the answer is an unstripped build for
debugging and a stripped one for measurement, which is a small change to `ci/build.sh` and not to the
kernel. Flagged rather than resolved.
