# RFC-0002: Taking control of faults

- Objective: 0002 (memory, and the ground isolation stands on)  Status: draft
- Author: architect                        Model: claude-opus-5[1m]
- Milestone: M1, first part

## Motivation

The kernel does not handle faults. `VBAR_EL1` is never written, so it holds whatever reset left
there — zero on QEMU virt — and any exception vectors into the middle of `.text` and executes
whatever it finds.

This is not theoretical. Reviewing M0, `reviewer-safety` measured it: an overflow injected into the
console write path produced **10,262,934 undefined-instruction exceptions in four seconds, with no
console output at all**. The same reviewer noted, twice, that the re-entrancy guard added in C-0003
bounds *panic* re-entry and does nothing for a *fault* inside the failure path — the storm is
reachable from the one code path whose entire job is to report that something went wrong.

So the kernel's current behaviour on any hardware fault is: silence, then a CI timeout. A developer
learns that something broke, thirty seconds late, with no indication of what.

M1 needs the MMU, a frame allocator and a heap. Every one of those produces faults while it is being
written — a bad page table entry is a data abort, and a data abort today is an unbreakable silent
loop. Debugging the rest of M1 without this is possible in the way that debugging without a compiler
error message is possible.

A Guardian ruling on the previous contribution observed that M0's last two contributions were both
about the project's own claims, and that a third would read as drift toward process over product.
Whether this work answers that signal is for a panel to decide, not for this document to assert.
Recorded here so the question is in front of them.

## Design

### 1. The vector table

AArch64 defines sixteen exception entries, each 128 bytes, in a 2 KiB-aligned table addressed by
`VBAR_EL1`. Four groups of four — Synchronous, IRQ, FIQ, SError — for:

| Offset | Taken from | Reachable at M1 |
| --- | --- | --- |
| `0x000` | Current EL, SP_EL0 | no — the kernel runs at EL1h, using SP_EL1 |
| `0x200` | Current EL, SP_ELx | **yes, all four** |
| `0x400` | Lower EL, AArch64 | no — no EL0 until M3 |
| `0x600` | Lower EL, AArch32 | no — and never; AArch32 is not supported |

**Every one of the sixteen is populated anyway.** The twelve that cannot occur are exactly the ones
that will occur if something is wrong about an assumption above, and an entry that cannot happen is
the entry you most want to be legible when it does. Each records which slot it was, so the report
distinguishes "a data abort in the kernel" from "an exception from an EL0 that does not exist yet".

Entries are 128 bytes and the table is `.align 11`. Both are architectural requirements, not
preferences: a misaligned `VBAR_EL1` write is `RES0` in its low bits and silently lands somewhere
else.

### 2. What an entry does

Each entry stores the general-purpose registers it is about to clobber, loads the slot number, and
branches to one shared Rust handler. It does **not** attempt to return.

Nothing at M1 is resumable. There is no scheduler to reschedule onto, no page table to fix up, no
user process to kill. A fault is a bug in the kernel, and the honest response is to say what happened
and stop. Resumable faults arrive with the MMU, in a later part of M1, and will need a different
entry sequence — one that saves and restores a full frame. Writing that now, untested, in a
privileged path, is the mistake RFC-0001 closed O-3 over.

**Corrected after review: the entry writes no stack at all, and sets the failure flag first.**

An earlier revision had the entry push x0–x30 "because the report reads them". Review established
that nothing reads them — the frame is write-only — and, more seriously, that the push happens
*before* the re-entrancy guard is consulted, eighteen faultable stores upstream of it. A fault caused
by a bad stack pointer therefore loops in the entry forever with the guard never reached. Measured:
2,328,136 exceptions in six seconds, no console output, killed by timeout.

The entry now does the opposite of what it did. Ten instructions, no stack access:

```
adrp x0, IN_FAILURE       ; test-and-set BEFORE touching anything
add  x0, x0, #:lo12:IN_FAILURE
ldrb w1, [x0]
mov  w2, #0xa5
strb w2, [x0]
cbnz w1, 1f               ; already failing: stop, without a stack
mov  x0, #<slot>
b    exception_entry
1:  wfi
    b 1b
```

Two consequences worth stating. Because the entry sets the flag, `fault_stop` no longer checks it —
checking twice would halt on the first fault and print nothing. And because the entry touches no
stack, a fault whose cause *is* the stack cannot recurse here at all; it recurses at worst once, in
the Rust handler's own prologue, where the flag is already set.

The flag holds `0xa5` rather than a bit. That is a mitigation, not a fix, and it is worth being
precise about which: `.bss` sits immediately below `.stack`, so a stack overflow writes over the flag
before anything else — review demonstrated an overflow setting it and turning the *first* real fault
into a silent halt. A one-byte pattern makes an accidental set less likely and does not make it
impossible. The structural answer is a guard page, which needs the MMU. Recorded as O-9.

### 3. The report

The handler is architecture-specific and reads three registers:

- **`ESR_EL1`** — the syndrome. Bits [31:26] are the exception class (EC), which says what kind of
  fault this is. Bits [24:0] carry class-specific detail.
- **`FAR_EL1`** — the faulting virtual address, for aborts. Meaningless for other classes, and the
  report says so rather than printing a stale value as though it meant something.
- **`ELR_EL1`** — the instruction that faulted.

Output shape, fixed-width so it can be read at a glance and matched by a test:

```
SKYNET_FAULT
  slot  cur_spx_sync
  esr   0x96000045  data abort, same EL
  far   0x0000000000000000
  elr   0x0000000040080094
```

**Exception class decoding** covers the classes a kernel at M1 can produce, and prints the raw EC for
anything else rather than guessing:

| EC | Meaning |
| --- | --- |
| `0x00` | unknown — usually an undefined instruction |
| `0x0E` | illegal execution state |
| `0x15` | SVC from AArch64 — a system call, which does not exist until M3 |
| `0x21` | instruction abort, same EL |
| `0x25` | data abort, same EL |
| `0x2F` | SError |
| `0x3C` | BRK — a debugger breakpoint |

### 4. Formatting, without `core::fmt`

The report needs hex. It must not pull in `core::fmt`.

RFC-0001 kept formatting out of the failure path for two reasons: image size, and keeping arbitrary
runtime data off an outward channel. The first still holds — `core::fmt` is kilobytes against a
192 KiB budget that must also fit an MMU. The second holds differently here: a fault report *is*
runtime data, deliberately, and that is the point of it.

So: a sixteen-byte lookup table and a shift loop, in `arch/aarch64/hex.rs`, emitting fixed-width
values. Forty lines, no dependency, no allocation, and nothing that can itself fault.

The distinction worth stating: `fail_stop` writes a compile-time constant because a *panic message*
is program text that could contain anything a future author puts in it. A fault report writes
register values, which are facts about the machine.

**Corrected after review.** An earlier revision said those values are "chosen by this design and not
by a caller". They are parameters. Whether a caller can choose them is a question about who can call
the function, not about what the function does with what it receives — and with `fault_stop` public,
a caller could choose all of them. `pub(super)` is what makes the sentence true; the sentence was
doing work the visibility had not yet done.

### 5. Where the authority comes from

The handler needs a console. `fail.rs` already owns the one place outside the boot path that mints
devices, with the re-entrancy guard C-0003 added.

**The fault path goes through it.** `Failure` gains `fault_stop`, in the same module, behind the same
`IN_FAILURE` guard. It is not a new minting *module*.

**Correction, after review.** An earlier revision claimed more: that this "does not weaken" the
reachability finding. Two judges compiled the counter-example. `fault_stop` was `pub` on a type
re-exported at crate scope, and `Slot` being private does not help because `None` needs no name — so
portable code could call it, put 160 bits of caller-chosen data on the operator's console, and power
the machine off, with the HAL check passing. The hole did not close; it widened, because
`fail_stop`'s `'static` bound had reduced portable-reachable output to zero bits of runtime state and
this restored it.

The RFC answered *which module holds the constructor call* — true when written, and no longer the
whole answer (see "The third device-access site" below) —
and presented that as an answer to a question about *reachability*. It was not. `fault_stop` is
`pub(super)`, the idiom already used two files away, and the claim narrows to what visibility
actually delivers.

This matters more than it looks. `reviewer-constitution` found that C-0003 closed the constructor
reach-around and left `Failure::fail_stop` reachable from portable code — the hole moved rather than
closing. Adding a second *constructor* call in `exception.rs` would move it again. One module
constructs devices, and that remains true. It is not the same claim as "one module reaches devices",
which this RFC does weaken — deliberately, and the next section is the accounting.

## The third device-access site

`exception.rs`'s vector table reaches two devices without holding either. When an exception arrives
while the kernel is already failing, the entry forms the PL011 base with a single `movz`, writes the
data register directly, and then issues PSCI `SYSTEM_OFF` with an immediate function ID. No
`BootConsole`, no `PowerControl`, no constructor call — and therefore invisible to
`check_minting_sites`, which greps for constructors.

Four earlier statements in this document said no such site was added. They were written before the
emergency path existed and were not revised when it did, which is worse than an error: the RFC's
hash is pinned into the append-only ledger, so a false design record outlives the design.

**Why the path cannot hold a capability.** It runs with no stack. A `BootConsole` cannot be
constructed without one, and the whole reason this path exists is that the fault being reported may
*be* the stack — that is the case review measured at 2,328,136 exceptions. Anything that needs a
frame to report a broken frame reports nothing.

**What it costs at M4.** Every other authority in the kernel becomes a capability the holder was
handed. This one cannot: it is assembly, the address is an immediate in the instruction stream, and
there is no holder to hand anything to. When capabilities arrive, this is the site that will need an
argument rather than a mechanism — most likely that the vector table is part of the trusted computing
base by construction, since it is the code the processor branches to whether or not anyone granted it
anything. That argument is not made here. It is recorded as owed.

**What contains it meanwhile.** It is reachable only with `IN_FAILURE` already set, which only the
vector entry and `fail_stop` write; it writes a fixed sixteen-byte string from `.rodata` and cannot
be made to write anything else; and its last instruction stops the machine. It is not a console. It
is a sixteen-byte epitaph.

**O-10.** `check_minting_sites` greps for constructor names and is therefore blind to this path, and
to any raw MMIO write from any file — review demonstrated the same blindness from a portable one.
Counting constructors was never the invariant; reaching a device is. The check needs to look for the
address, not the name.

The guard covers both entries. A fault inside `fault_stop` reaches the guard and halts, which is
precisely the storm `reviewer-safety` measured and the gap it flagged in the C-0003 guard.

### 6. Installing it

`boot.rs` writes `VBAR_EL1` after `SCTLR_EL1` and before the `isb`, so one barrier covers both. Two
instructions:

```
"adrp x9, {vectors}",
"add  x9, x9, #:lo12:{vectors}",
"msr  vbar_el1, x9",
```

Before this point a fault is still unhandled, and cannot be otherwise — the window is the handful of
instructions between reset and the write, and closing it requires firmware, which M0's non-goals
exclude.

### 7. The HAL boundary

Nothing here crosses it. Exception handling is architecture-specific in its entirety: the table
layout, the syndrome encoding, the register names. `hal.rs` is unchanged, and no portable file gains
a line.

That is the correct answer and worth stating, because the tempting alternative — a portable
`FaultReport` trait — would be an abstraction over one implementation whose shape is dictated by
aarch64's syndrome register. RFC-0001 made this argument for the HAL and it applies again: a
contract defined by its only implementation is not a contract.

## Non-goals

- **Resumable faults.** Nothing at M1 can be resumed; the handler reports and stops.
- **Interrupts.** The IRQ and FIQ entries exist and report. Enabling interrupts is M2.
- **The MMU, page tables, a frame allocator, a heap.** Later parts of M1. This part exists so those
  are debuggable.
- **Stack traces or symbolisation.** Needs unwind tables and a symbol table in the image. `ELR_EL1`
  plus `objdump` is enough at this size.
- **EL0, system calls, user space.** M3.
- **Saving a restorable frame.** The entry saves registers to report them, not to return.

## Constitutional impact

**Invariant 4, frugality.** The table is 2 KiB of `.text` and the handler a few hundred bytes. Against
`nano`'s 192 KiB with 191 bytes used, comfortable — and it is the first contribution to spend real
budget, which is worth watching rather than waving through.

**Invariant 1, no ambient authority (pending, M4).** No new *constructor* call, and one new
device-access site that holds nothing — the stackless emergency path, accounted for above and
recorded as owed at M4. The handler routes through
`fail.rs`. The `IN_FAILURE` guard's scope widens from "the panic path" to "the failure path", which
is what it should have been.

**Invariant 5, zero telemetry (pending, M6).** The report goes to the local console, the same one the
boot marker uses. No outward path exists to carry it anywhere.

**Invariant 6, HAL boundary.** Entirely inside `arch/aarch64/`. No portable file changes.

## Conformance criteria

1. `ci/build.sh`, `--lint`, `ci/boot-test.sh` all pass; a successful boot is byte-for-byte unchanged
   in output
2. `SKYNET_PROFILE=nano ci/build.sh --size` within budget
3. `readelf -S` shows the vector table 2 KiB-aligned
4. `VBAR_EL1` is written before any Rust runs, and the disassembly shows it
5. **PROOF:** an undefined instruction injected into `kernel_main` produces a `SKYNET_FAULT` report
   naming `cur_spx_sync`, an EC of `0x00`, and an `ELR` matching the injection site — then stops.
   Run it, do not assert it
6. **PROOF:** a fault injected *inside* `fault_stop` halts on the guard instead of storming. This is
   the defect `reviewer-safety` measured at 10.2 million exceptions per four seconds; show the number
   is now one
7. `ci/constitution-check.sh --check hal-boundary` and `--check no-kernel-deps` pass
8. `REVIEW:` no new device *constructor* call exists; `grep` for the constructors still finds two call
   sites, both in `fail.rs`
9. `REVIEW:` the hex formatter cannot itself fault — no indexing that can go out of bounds, no
   arithmetic that can overflow under `overflow-checks`

## Alternatives considered

**One handler per entry rather than a shared one with a slot number.** Sixteen handlers is sixteen
places for the report format to drift. The slot number costs one immediate.

**Reporting through a portable trait.** Rejected in §7. An abstraction over one implementation,
shaped by that implementation.

**Using `core::fmt` and accepting the size.** Tempting, and it would make later reports much easier
to write. Rejected because the budget must also fit an MMU, page tables and an allocator in the same
milestone, and because "we can afford it now" is how a 192 KiB ceiling is spent.

**Halting silently, as today, and relying on the debugger.** This is the current behaviour and it is
what produced a ten-million-exception storm nobody could see. `ci/boot-test.sh --gdb` exists for
diagnosis; it does not help when the failure happens in CI, or on hardware, or to someone who does
not yet know something is wrong.

## Open questions

**O-1.** The handler runs on the faulting stack. If the fault was a stack overflow — which M0 can
produce, since `.stack` sits directly above `.bss` with no guard page and the MMU off — the handler
pushes 256 bytes further into whatever is below. A dedicated fault stack fixes it and needs the MMU
to be worth doing properly. Recorded; it belongs with the MMU part of M1.

**O-2.** `SError` is asynchronous and may arrive from a much earlier instruction, so `ELR_EL1` names
where execution happened to be rather than what caused it. The report should say so for EC `0x2F`,
and this RFC does not specify that text. Left to the implementer with a `REVIEW:` criterion rather
than guessed at here.

**O-9.** *(partly addressed — the harm is now visible, the cause is not fixed.)*

`IN_FAILURE` lives in `.bss`, immediately below `.stack`, so a stack overflow overwrites the
re-entrancy flag before it overwrites anything else — and a set flag turns the first genuine fault
into a silent halt, which is the failure this whole RFC exists to remove. The `0xa5` pattern lowers
the probability and changes nothing structural. Without an MMU there is no guard page and no way to
make the stack's overflow land somewhere harmless. This belongs with the MMU part of M1, and whoever
builds it should treat an unmapped page below the stack as a requirement rather than a nicety.

What shipped instead changes the *consequence* rather than the cause. The re-entrancy path no longer
halts in silence: it writes `SKYNET_REFAULT` to the UART — no stack, address built with a single
`movz`, TXFF polled so a full FIFO drops nothing — and then issues PSCI SYSTEM_OFF. A corrupted
guard byte therefore turns the first genuine fault into a machine that stops and says why, instead
of a machine that stops. `ci/boot-test.sh` has its own top-level check for the marker, because the
shutdown is clean and exits 0 exactly like a successful boot.

Measured, with `qemu -d int`, on the case review built: wild SP plus one `udf` took **2,328,136
exceptions in six seconds and printed nothing**; it now takes **three** — the fault, the re-fault,
and the `hvc` that stops the machine — and prints `SKYNET_REFAULT`. Review's own fix measured two,
because it ended in a `wfi` loop; the third exception is the price of exiting instead of hanging,
and a hang is what a timeout cannot distinguish from a hardware failure.

**O-3.** Nothing writes `VBAR_EL1` for a second core. Secondary cores are parked at M0 and brought up
at M2; whoever does that must install vectors per core before releasing one. Recorded so it is a
decision rather than a discovery.
