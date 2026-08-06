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
a caller could choose all of them.
**Withdrawn.** `pub(super)` makes no sentence true. The counter-example declared
`extern "C" { #[link_name = "<v0-mangled symbol>"] fn f(..); }` in a portable file and reached
`fault_stop` with arguments of its own choosing, through a build that passes clippy `-D warnings` and
the full constitution check. `#[link_name]` reaches any symbol in the binary and nothing in the
language, the lints or CI closes it. Visibility confines accidents and idioms; it has never confined
intent. See `fail.rs`, which now records all three versions of this claim and why each was false.

This is the general statement, and §5 does not restate it in a weaker form. A claim of this shape has
now been falsified twice — once for a visibility modifier, once for a guard word — and the second
time is recorded there rather than answered with a third narrowing.

### 5. Where the authority comes from

The handler needs a console. `fail.rs` already owns the one place outside the boot path that mints
devices, with the re-entrancy guard C-0003 added.

**The fault path goes through it.** `Failure` gains `fault_stop`, in the same module, behind the same
`IN_FAILURE` guard. It is not a new minting *module*.

**Correction, after review.** An earlier revision claimed more: that this "does not weaken" the
reachability finding. The counter-example was compiled and booted. `fault_stop` was `pub` on a type
re-exported at crate scope, and `Slot` being private does not help because `None` needs no name — so
portable code could call it, put 160 bits of caller-chosen data on the operator's console, and power
the machine off, with the HAL check passing. The hole did not close; it widened, because
`fail_stop`'s `'static` bound had reduced portable-reachable output to zero bits of runtime state and
this restored it.

The RFC answered *which module holds the constructor call* — true when written, and no longer the
whole answer (see "The third device-access site" below) —
and presented that as an answer to a question about *reachability*. It was not. `fault_stop` is
`pub(super)`, the idiom already used two files away, and that buys nothing against the question this
section asked: §4 withdrew the claim that visibility confines reachability, and this paragraph does
not reinstate it in a smaller font. The modifier is worth having because it stops an accident and an
idiom. It is not an answer.

This matters more than it looks. Review found that C-0003 closed the constructor reach-around and
left `Failure::fail_stop` reachable from portable code — the hole moved rather than closing. Adding
a second *constructor* call in `exception.rs` would move it again. One module
constructs devices, and that remains true. It is not the same claim as "one module reaches devices",
which this RFC does weaken — deliberately, and the next section is the accounting.

## The third device-access site

`exception.rs`'s vector table reaches two devices without holding either. When an exception arrives
while the kernel is already failing, the emergency path forms the PL011 base with a single `movz`,
writes the data register directly, and then issues PSCI `SYSTEM_OFF` with an immediate function ID.
No `BootConsole`, no `PowerControl`, no constructor call — and therefore invisible to
`check_minting_sites`, which greps for constructors. Whether that path is instructions inside the
vector entry or a function the entry branches to is a factoring decision and does not change this
paragraph.

Four earlier statements in this document said no such site was added. They were written before the
emergency path existed and were not revised when it did, which is worse than an error: the RFC's
hash is pinned into the append-only ledger, so a false design record outlives the design.

**Why the path cannot hold a capability.** It uses no stack — measured in the disassembly of the
linked image, where neither rung references `sp` at all. A `BootConsole` cannot be constructed
without one, and the whole reason this path exists is that the fault being reported may *be* the
stack — that is the case review measured at 2,328,136 exceptions. Anything that needs a frame to
report a broken frame reports nothing.

"Uses no stack", not "runs with no stack", and the difference is not pedantry. Entered from a vector
entry there may be no usable SP; entered any other way there is one. The property the argument needs
is that the code does not depend on it, and that property holds either way. The earlier wording was
a claim about the machine's state, which is a claim about who called.

**What it costs at M4.** Every other authority in the kernel becomes a capability the holder was
handed. This one cannot: it is assembly, the address is an immediate in the instruction stream, and
there is no holder to hand anything to. When capabilities arrive, this is the site that will need an
argument rather than a mechanism — most likely that the vector table is part of the trusted computing
base by construction, since it is the code the processor branches to whether or not anyone granted it
anything. That argument is not made here. It is recorded as owed, and the next paragraph widens what
it is owed for: the code the processor branches to is also code anything linked into the image can
branch to, and only the first half of that is a hardware fact.

**What contains it meanwhile — withdrawn, not narrowed.**

The previous version of this paragraph read: *"It is reachable only with `IN_FAILURE` already set,
which only the vector entry and `fail_stop` write; it writes a fixed sixteen-byte string from
`.rodata` and cannot be made to write anything else."* Of that, the first clause is false; the
`.rodata` is wrong and was never right for long — the bytes are `.asciz` inside the vector entry when
the path is inlined and a `static` in `.failpath` beside its reader when it is split, and neither is
`.rodata`. An output section is the linker script's to decide, and naming one here was drift waiting
to happen. Only "cannot be made to write anything else" survives, for reasons given below that have
nothing to do with the guard.

The first clause has been measured false, and it is §4's withdrawn claim with the guard substituted
for the visibility modifier. §4 states the general form: **`#[link_name]` reaches any symbol present
in the binary, and nothing in the language, the lints or CI closes it.** A guard word is a
precondition written in the source. A symbol is an address in the image. A caller that binds the
address never reads the source, so no precondition stated in the source is a bound on who arrives.

Measured, on a build of this design in which the two emergency rungs are separate functions in
`.failpath` — `emergency_report` and `quiet_stop`, split out of the vector entry to make room inside
128 bytes. A portable file with no `asm!`, no `naked_asm!`, no `core::arch::`, no `target_arch`, no
`cfg` and no constructor call declares `extern "C" { #[link_name = "<the v0-mangled symbol>"] fn f()
-> !; }`; `kernel_main` calls it. The console prints `SKYNET_BOOT_OK`, then `SKYNET_REFAULT`, and the
machine powers off through PSCI with QEMU exiting 0. `IN_FAILURE` is zero throughout and no fault is
taken — `-d int` traces exactly one exception, the `hvc` itself — and neither rung reads the guard at
any point, which the disassembly shows directly. `ci/build.sh`, clippy under `-D warnings` and the
full `ci/constitution-check.sh` all pass. Naming the stop rung instead powers the machine off writing
nothing at all, and then `ci/boot-test.sh` passes too — five checks, all green, on an image whose
portable half shuts the operator's machine down by naming a symbol.

**Removing those two symbols does not make the sentence true. That is why it is withdrawn rather than
narrowed a third time.** Measured on the revision that has neither of them, both rungs inlined into
the sixteen entries: the same portable file naming `vector_table` runs entry 0's ladder, takes the
untaken rung, prints a full `SKYNET_FAULT` report and powers off — guard at zero, no fault taken,
build and clippy clean and the whole constitution check green. On the split revision the table
additionally carries a **global** linker-script symbol at its base, which needs no mangled name and
no crate hash to bind, and reaches the same code the same way. Four names, two revisions, one
outcome: a portable file reaches a device.

What caught three of the four was `ci/boot-test.sh`, and only because they printed. It matched
`SKYNET_REFAULT` or `SKYNET_FAULT` on the console and reported, variously, that the kernel took a
fault and that the kernel faulted inside its own failure path — of three machines that took no fault
at all. A marker check measures output, not reach: it names the wrong cause when it fires, and it
says nothing when the code that was reached is silent. That is not a criticism of the boot test,
which was built to catch a storm and catches one. It is the reason O-12 below asks for a measurement
on the image rather than another string to grep for.

Two things are being confused whenever this claim is restated, and only one of them is fixable at M1:

- **An artefact accident:** how many symbols the emergency rungs occupy. Two here, because they were
  factored out of a full entry; zero when they are folded back in. That is a fact about code shape
  and it changes with the next patch. Nothing constitutional turns on it.
- **A design property:** the vector table has an address, because `VBAR_EL1` *is* that address, and
  an address in the image is reachable by anything else linked into the image. Every rung of the
  ladder sits downstream of an address this design is obliged to publish. No factoring removes that,
  and neither does any visibility modifier, section attribute or guard value.

So what this design guarantees is a bound on **effect**, not a bound on **reach**, and only the first
survives a caller that arrives by name:

- The marker rung takes no arguments, forms its pointer with `adr` to a symbol in its own section,
  and counts down a compile-time length. Sixteen fixed bytes come out and nothing else can — the
  reach-around above put `SKYNET_REFAULT` on the console and had no way to put anything else there.
- The stop rung takes no arguments and issues one immediate function ID.
- Both end the machine, and neither returns.

It is still not a console. It is a sixteen-byte epitaph — and it is one that anything in the image
can read aloud once, which is the clause the earlier paragraph was missing.

What this design does **not** guarantee, and what no revision of it can guarantee before capabilities
exist: that the processor is the only thing that branches here. The ladder bounds re-entry for the
caller the design contemplated and bounds nothing for a caller that skips it. If a later patch
removes the two symbols, this paragraph stays true as written — the claim it withdraws does not come
back with them, and anyone tempted to restore it should reach `vector_table` first and read what
comes out.

**O-11.** The emergency path is bounded at three exceptions, and the third end is a hang.

Measured, with the emergency path's own UART base pointed at unmapped space so that its first device
access aborts: `udf` with a wild SP gives exception 1 (undefined instruction), exception 4 (the Rust
prologue's abort), exception 4 again (the emergency path's UART read) — and the fourth entry finds
`STOPPING` and stops dead. Three exceptions, then `wfi`. Without the third state this is unbounded.

The residual: that end is a `wfi` loop, so QEMU exits 124 and CI reads a timeout. It is a real hang,
chosen — the path that would have powered the machine off is the one that just faulted, and reaching
PSCI from the dead stop would need a fourth state to bound *it*, in an entry with four bytes left of
its 128. What distinguishes it from an ordinary hang is the console, which ends at `SKYNET_BOOT_OK`
with no marker, and an exception count of three rather than millions. That is thin, and it is what
is available before the MMU.

**O-10.** `check_minting_sites` greps for constructor names and is therefore blind to this path, and
to any raw MMIO write from any file — review demonstrated the same blindness from a portable one.
Counting constructors was never the invariant; reaching a device is. The check needs to look for the
address, not the name.

**O-12.** *(the same blindness, in a second check — which makes it a class rather than a gap.)*

`ci/constitution-check.sh --check hal-boundary` greps `kernel/src` outside `arch/` for a fixed list
of architecture-specific constructs: `core::arch::`, `asm!`, `naked_asm!`, `global_asm!`,
`#[unsafe(naked)]`, `#[naked]`, `target_arch`. None of them appears in an `extern "C"` block carrying
`#[link_name]`. So a portable file that writes the PL011 and powers the machine off passes the
check — measured on three images, green every time, alongside a clean build and clippy under
`-D warnings`.

That is O-10 one check over. O-10: `--check minting-sites` counts constructor *names* and is blind to
a raw MMIO write. This: `--check hal-boundary` matches construct *names* and is blind to reaching
architecture-specific code by name. Both stand in for a fact about addresses by matching text, and
both are blind in the same direction — they answer "does this file contain the spelling" when the
invariant asks "does this file reach the device". Two instances of one shape is worth recording as a
class, because the remedy for a class is not a longer list of spellings.

What would actually measure it is the linked image rather than the sources: the set of symbols a
portable translation unit references, intersected with the set of symbols defined in `arch/`, must be
empty. That is `nm`-level work on an artefact the build already produces, it is not
architecture-specific, and it would have caught all four reach-arounds above and the `fault_stop` one
in §4 — none of which any text-matching check can see. Whether it belongs to this RFC is a real
question and is left open: it is not code in `arch/`, it is a check, and this RFC cannot edit `ci/`.
Recorded so it is a decision rather than a discovery.

The guard covers both entries into the failure path — `fail_stop` and `fault_stop` — against
*re-entry*, which is the only thing a guard can cover. A fault inside `fault_stop` reaches the guard
and halts, which is precisely the storm review measured and the gap it flagged in the C-0003 guard.
That is a bound on what happens after control arrives. It is not, and cannot be turned into, a bound
on how control arrives.

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

All of that is a statement about what this design *writes*, and it is the only statement of that kind
this section is entitled to make. It is not a claim that a portable file cannot *reach* what is on
the other side of the boundary. One can, by name; the check that guards this invariant does not see
it; and the answer is capabilities at M4, not a stronger sentence here. See O-12.

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
device-access path that holds nothing — the stackless emergency path, accounted for above and
recorded as owed at M4. How many *symbols* that path occupies depends on how it is factored and is
not a constitutional fact; that it is reachable by name is one, and no factoring removes it. The
handler routes through `fail.rs`. The `IN_FAILURE` guard's scope widens from "the panic path" to "the
failure path", which is what it should have been — and "scope" there means which faults it bounds,
not who may execute the code behind it.

**Invariant 5, zero telemetry (pending, M6).** The report goes to the local console, the same one the
boot marker uses. No outward path exists to carry it anywhere.

**Invariant 6, HAL boundary.** Entirely inside `arch/aarch64/`. No portable file changes — which is
a statement about this design's own diff and not about what a portable file *could* do. Measured:
`--check hal-boundary` passes on an image whose portable half reaches the PL011 and PSCI by name. See
O-12.

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
7. `ci/constitution-check.sh --check hal-boundary` and `--check no-kernel-deps` pass. Necessary and
   **not sufficient**, and this criterion is not evidence that the boundary holds: measured, an image
   whose portable half reaches the PL011 and issues PSCI by `#[link_name]` passes `--check
   hal-boundary` with a clean build and clippy silent. Green here means no forbidden *spelling*
   crossed the boundary. It does not mean no *reach* did. See O-12
8. `REVIEW:` no new device *constructor* call exists. `--check minting-sites` counts four: two in
   `boot.rs`, which predate this RFC, and two in `fail.rs`. An earlier version of this criterion said
   a grep "still finds two call sites, both in `fail.rs`", which is the count for the failure module
   and not the count for the kernel — a criterion whose stated evidence does not match what the
   command prints is a criterion nobody can fail
9. `REVIEW:` the hex formatter cannot itself fault — no indexing that can go out of bounds, no
   arithmetic that can overflow under `overflow-checks`
10. `REVIEW:` no comment, doc-comment, commit message or design note added by an implementation may
    state or imply that any code in `arch/` is unreachable from portable code — on the strength of a
    visibility modifier, a section attribute, a missing `#[no_mangle]`, a guard value, a private
    argument type, or the absence of a stack. This document and `fail.rs` have each made that claim
    in several narrowing forms and every one of them was compiled false. The question is settled and
    the answer is "reachable, by name"; a sentence that reopens it is a defect on sight, and the
    remedy is to delete it rather than to qualify it
11. `REVIEW:` the implementation records, with names, every symbol in the linked image through which
    portable code can reach a device — `nm` over `.vectors` and `.failpath` is the whole measurement.
    Not bounded, because bounding it is not available before M4, but **counted**: the M4 argument is
    owed per site, and a site nobody counted is a site nobody will argue for. A change in that count,
    in either direction, belongs in the submission rather than in the next review's probe

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
