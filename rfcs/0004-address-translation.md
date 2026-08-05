# RFC-0004: Address translation, and the page that is not there

- Objective: 0002 (memory, and the ground isolation stands on)  Status: draft
- Author: architect                        Model: claude-opus-5[1m]
- Milestone: M1, fourth part
- Serves: objective 0002's **fourth** success criterion

> The MMU is on, with the kernel mapped and everything else unmapped by default — reaching an address
> nobody granted is a fault, not a read

Open questions are numbered in **one** series, O-1 to O-9. RFC-0002 has two series in one document —
`O-1, O-2, O-3, O-9, O-10, O-11` — and a citation into it is unambiguous only by luck. That is
recorded in `tasks/open/T-0008.toml`; this document does not repeat the mistake.

---

## 0. What was run for this design, and what was not

**No part of this design has been booted.** `qemu-system-aarch64` is not installed on the machine this
was written on, and neither is the bare-metal Rust target, so the kernel cannot even be compiled here:

```console
$ ls /usr/bin/qemu-system-aarch64
ls: cannot access '/usr/bin/qemu-system-aarch64': No such file or directory
$ rpm -qa | grep -i qemu
qemu-guest-agent-10.2.2-1.fc44.aarch64
$ ./ci/build.sh
PENDING  bare-metal Rust target 'aarch64-unknown-none-softfloat' is not reachable
```

RFC-0003's first revision was in the same position, said so, and that marking is the only reason its
false premise was caught before a parser was written — the decomposer turned the unverified sentence
into an acceptance criterion and the criterion stopped the work. The ledger's own conclusion is that
*the failure mode this project should still fear is the unverified sentence that is not marked*. So
every claim below is in one of three states, and the state is stated where the claim is:

| State | Meaning |
| --- | --- |
| **RAN** | executed on this machine, with the command shown |
| **SPEC** | taken from the Arm architecture, to be checked against the ARM ARM by the implementer and by review — never from a boot |
| **UNVERIFIED** | neither, and named as such |

The host here is `aarch64-unknown-linux-gnu` with rustc 1.97.1, GNU `ld` 2.46.1 (`ld.bfd`) and GNU
binutils `objdump`/`objcopy`/`nm`. That is not the kernel's toolchain — the kernel links with LLD —
so where a linker behaviour matters it is marked. What was run:

1. **RAN — the enable sequence assembles.** The instructions of §4 were put through
   `global_asm!` and compiled with this project's own rustc (`rustc --edition 2021 -O --emit=obj`),
   which uses the same LLVM assembler the kernel build uses. Every system-register name was accepted
   and every instruction encoded: `msr mair_el1`, `msr tcr_el1`, `msr ttbr0_el1`, `msr ttbr1_el1`,
   `dc ivac`, `tlbi vmalle1`, `dsb ish`, `dsb nsh`, `ic iallu`, `isb`, `mrs id_aa64mmfr0_el1`,
   `msr sctlr_el1`. This says the sequence is *writable*, and nothing about whether it is *correct*.

2. **RAN — the layout of §2 links, and its detents are detents.** The candidate `link.ld` was
   linked with `ld -T … --nmagic` against a synthetic object carrying the kernel's own input-section
   names (`.text.boot`, `.vectors`, `.guard`, `.failpath`, `.rodata`, `.text`, `.data`, `.bss`). All
   thirty-three `ASSERT`s hold; `nm` places `_start` at `KERNEL_BASE`; the group boundaries land
   where §2 says. Six deliberate breakages were then linked: *the header not first*, *the stack
   placed below the guard*, *`GUARD_SIZE` set to zero*, *a non-empty `.got`*, *a table pool of the
   wrong size* — each refused with its own message. The sixth attempt, deleting one
   `ALIGN(GRANULE)`, **linked cleanly**, because `.vectors`'s internal `. = ALIGN(2048)` happened to
   leave that boundary granule-aligned anyway; deleting a different `ALIGN` produced `RW-1 does not
   end on a granule boundary`. That is recorded because it is information about the assertion, not
   about the layout: an alignment detent can be satisfied by accident, so there is one per boundary
   rather than one for the set.

3. **RAN — the translation regime was built and walked on the host.** A model of §3's descriptors and
   §5's pool, given the `__*` symbols from the linked ELF **on argv** so that no address in it is a
   constant, maps the layout, then walks its own tables. Every mapped page translates to itself; the
   stack guard, the table pool, the byte below the stack floor, RAM base below `KERNEL_BASE`, the
   second PL011 at `0x0900_1000` and a device tree blob at `0x4400_0000` all fail to translate. The
   pool requirement was swept against bitmap size up to 128 GiB of RAM (§5).

4. **RAN — the stack-frame inequality of §6 is measurable, and the compiler is on its side.** On this
   toolchain a 70,000-byte stack frame does **not** descend in one step. LLVM emits an inline probe
   loop that steps one 4 KiB page at a time and writes a zero at each step:

   ```
   sub  x9, sp, #0x11, lsl #12      // target: 69,632 below
   1:  sub  sp, sp, #0x1, lsl #12   // one page
       cmp  sp, x9
       str  xzr, [sp]               // and touch it
       b.ne 1b
   sub  sp, sp, #0x170              // the remainder
   ```

   The largest *single* decrement of `sp` in that object is therefore 4,096 bytes, not 70,000. §6
   turns that into a build-time inequality rather than relying on it — because whether the bare-metal
   target enables the same probing **could not be checked here** (its `core` is not installed), and
   the inequality is correct either way.

5. **RAN — the image cost is measurable.** `objcopy -O binary` of the candidate ELF is 20,488 bytes
   for a synthetic kernel of about 2 KiB of content: the alignment padding of §2 is real bytes in the
   flat image. The Constitutional impact section gives the derivation and the command; no figure for
   the actual kernel appears anywhere in this document, because it could not be built here.

**What is not verified, and matters most:** the descriptor bit layout, the TCR/MAIR/SCTLR field
positions, the barrier and cache-maintenance sequence, and the exclusive-monitor argument of §7. All
four are SPEC. Two of them **cannot be settled by a boot at all** — see §8 — and a green
`ci/boot-test.sh` must not be offered as evidence for either.

---

## Motivation

Everything the kernel currently protects, it protects by arithmetic on section addresses. The header
of `kernel/src/arch/aarch64/link.ld` says why, in one sentence:

> The stack is the highest section and grows down. With no MMU there is no page beneath it that
> faults, so the only question is what it destroys first.

Fifteen link-time assertions exist to answer *what it destroys first*. They bought a real
improvement — measured, in `tasks/open/T-0008.toml` — and they cannot buy the thing the objective
asks for, because ordering is a statement about what a write passes through, and nothing prevents a
write that passes through nothing.

Three residuals are carried in `tasks/open/T-0008.toml` with their measurements. They have one
answer:

- an overrun in a band below `__stack_top` takes exactly four exceptions and then stops dead with an
  **empty console and exit 124** — bounded, and silent, because what the overrun destroyed was the
  failure path's own code;
- past that band it destroys **vector entry 4** and storms;
- and a **single stack frame larger than the distance** reaches the vector table in one instruction,
  touching nothing on the way, so nothing detects it.

The depths are not quoted here. They are depths below a linker symbol in a build that contained a
probe, the sections move when the image changes, and the image changes when the instrument is added —
which is the correction the ledger records against every figure this path has published. Whoever
re-measures derives the floor from `__stack_top` at run time. That rule is inherited by every
criterion in the Conformance criteria.

Two other things are waiting on the same mechanism.

**`kernel/src/arch/aarch64/fail.rs` argues at length that the re-entrancy guard uses a load and a
store rather than `swap`,** because `swap` compiles to an exclusive-monitor pair and the architecture
does not guarantee exclusive monitors on the memory type the machine has with the MMU off. It states
that `swap` becomes correct once the MMU is on. §7 confirms the direction and corrects the
condition: *MMU on* is not the property that matters, and the comment names one of three things it
needs.

**RFC-0002's O-10 records that `ci/constitution-check.sh --check minting-sites` greps two constructor
names and is structurally blind to a raw MMIO write** — review reached the PL011 from a portable file
with a raw pointer and passed every check. Page permissions do not close that. They shrink the set of
device addresses that exist from a 64-bit space to one 4 KiB page, which is a large reduction and is
not a closure, and the Constitutional impact section says exactly which part is which. A design
document that claimed page permissions made that reach-around a fault would be wrong, and wrong in
the reassuring direction, which is the direction every claim on this path has been wrong in.

RFC-0003's §7 hands this design five constraints deliberately, including that `FRAME_SIZE` must equal
the translation granule and that the compile-time assertion binding them belongs here because this is
the RFC that introduces the granule. §9 discharges each one by name.

---

## Design

### 1. The shape of the decision

Four choices decide everything else.

**One address space, identity-mapped, through `TTBR0_EL1`.** Virtual equals physical everywhere the
kernel is mapped. `TTBR1_EL1` is not used and its walks are disabled, so every address in the upper
half faults.

The reason is the enable instant. The instruction after translation comes on is fetched through the
new map; the stack pointer, `VBAR_EL1` and the console base are all live at that moment. With an
identity map every one of them means the same thing before and after, so there is no window in which
the machine is executing at an address the map does not describe. A high kernel virtual base — which
is where this eventually goes — requires the kernel to be linked at a virtual address and to move the
program counter from a physical to a virtual one, which is a second design on top of this one, in a
milestone with no EL0 to be separated from. It is named as M3's work in O-6 rather than left to be
discovered.

**A 4 KiB granule, three levels, a 39-bit input address.** `TCR_EL1.TG0 = 0b00`, `T0SZ = 25`, so the
walk starts at level 1 and each level indexes nine bits: L1 covers 1 GiB per entry, L2 2 MiB, L3
4 KiB. Every leaf in this design is an L3 page descriptor; no block descriptors are emitted.

Why 4 KiB and not 16 or 64: RFC-0003 settled `FRAME_SIZE` at 4 KiB, and RFC-0003 §7 requires
the granule to equal it. Everything else follows from that rather than arguing with it — reservations
round outward to whole frames, so a 64 KiB granule rounds the kernel image's tail and the device tree
blob outward by sixteen times as much, and it coarsens the stack guard by the same factor. What this
design does *not* do is take the granule's availability on trust: §4 reads
`ID_AA64MMFR0_EL1.TGran4` and refuses to enable if the granule is not implemented, because a
recollection about `-cpu cortex-a72` is not a fact about the machine.

Why 39 bits and not 48: three levels instead of four is one fewer table and one fewer level of
arithmetic, and 512 GiB covers every machine this project can currently boot. It is a constant with a
checked precondition rather than a hidden assumption — §4 refuses to map an address at or above
`1 << 39` — and O-4 records what a machine with memory above that needs.

**The map is built once, before translation is enabled, and never modified.** There is no `map()`, no
`unmap()`, no mapping window, no TLB maintenance interface. Two consequences follow and both are
worth more than the simplicity:

- The translation tables **are not in the map they define**. The hardware walker reads them by
  physical address, so it is unaffected; the kernel, after the enable, cannot write its own page
  tables, because the pages holding them do not translate. A writable alias of the structure that
  defines what is reachable is precisely what invariant 1 must not inherit.
- Nothing in this RFC can grow into M4 by accretion. A design with a runtime `map()` is one call site
  away from ambient authority over the address space; a design with none has to be extended
  deliberately, in a document, by someone who has to say why.

**The map is verified by walking it in software before the enable.** After `SCTLR_EL1.M` is set, a
wrong map cannot report anything: the faulting instruction vectors to `VBAR_EL1`, which is itself an
address in the map that just failed. So `mmu::verify` walks the tables the kernel just built and
checks that the code containing the enable sequence, the current stack pointer, the value in
`VBAR_EL1` and the console's base each translate to themselves with the permission they need. On
failure it reports with translation still **off**, where the console works. This is the one place in
the design where a check is worth its lines outright, because it is the only place where the
alternative to a check is silence.

### 2. The layout, and the page that is not there

`kernel/src/arch/aarch64/link.ld`. The section order is T-0005's, unchanged, with one section added
in front and three regions added at the top. Every permission boundary becomes a granule boundary.

```
KERNEL_BASE ─┬─ .head        RX   _start: the 64-byte image header, then the boot path
             │  .vectors     RX   2 KiB aligned, sixteen entries, fill 0
             ├─ .guard       RW   IN_FAILURE, alone in its granule
             ├─ .failpath    RX   the emergency rungs and the marker they print
             ├─ .rodata      RO
             ├─ .text        RX
             ├─ .got .data .bss
             │               RW
             ├─ .pagetables       ← UNMAPPED. TABLE_POOL_PAGES granules
             ├─ .stackguard       ← UNMAPPED. GUARD_SIZE
             └─ .stack       RW   grows down; __stack_top is __kernel_end
```

**`.head` is new and it is not cosmetic.** RFC-0003 boots the kernel as a Linux-format `Image`, which
means the loader reads a 64-byte header at **offset 0 of the flat image** — that is `KERNEL_BASE` —
and RFC-0003's conformance criterion 10 requires `nm` to place `_start` there. T-0005's script places
`.vectors` first, at `. = KERNEL_BASE`. Those two cannot both be true: with `.vectors` first, byte 56
of the flat image is inside vector entry 0 rather than the `ARM\x64` magic the loader checks.
RFC-0003 anticipated a collision in this file and asked the decomposer to sequence rather than let two
contributions edit it in parallel; this is the collision, and the resolution is a separate output
section for `.text.boot` placed ahead of everything, `KEEP`-ed so `--gc-sections` cannot take it, with
a link-time assertion that its address **is** `KERNEL_BASE`. None of T-0005's fifteen assertions
mention `.head`, so none of them changes meaning.

**The unmapped run below the stack is two regions, and it is derived, not declared.** `.pagetables`
and `.stackguard` are `NOLOAD`, contiguous, and mapped by nothing. The distance a descending stack has
before it reaches anything mapped is `__stack_bottom - __unmapped_start`, which is a subtraction on
the symbol table — `nm` gives it — and it is not written down here for the same reason
`link.ld`'s header does not write down its three distances: a number in a document goes stale and a
derivation does not. Putting the table pool inside that run is free: it has to be unmapped anyway, and
it has to be somewhere.

**Which section ends up in which permission group is not summarised anywhere in this document.** The
group boundaries are the `__rx1_start`/`__rx1_end`/`__rw1_end`/… symbols the script emits; the
descriptor each group receives is §3's table; and criterion 6 asks for `readelf -S` plus a run-time
dump of the descriptors rather than a sentence. Seven attempts to summarise what `link.ld` enforces
have been written into that file and six were false. A sentence that enumerates can drift from what it
enumerates.

**The assertions.** Thirty-three link. Fifteen are T-0005's, and eighteen are new; six of the new
ones were broken deliberately and five refused (§0, item 2), and criterion 11 asks for the rest. They
fall into four groups, and the list — not this paragraph — is the specification:

- T-0005's fifteen, carried forward verbatim, plus `ASSERT(SIZEOF(.got) == 0, …)`, because `.got` is
  placed in a writable group on the premise that a static bare-metal link has no GOT. If that stops
  being true the build fails and someone decides, rather than a jump table silently becoming
  writable.
- `ASSERT(ADDR(.head) == KERNEL_BASE, …)` — the boot header.
- one alignment assertion **per group boundary**, not one for the set. §0 records why: deleting one
  `ALIGN` still linked, because a neighbouring 2 KiB alignment happened to cover it.
- the guard's own: `GUARD_SIZE` a whole number of granules and at least one;
  `__stack_bottom == __unmapped_end`, so nothing mapped can sit between the stack floor and the
  guard; `SIZEOF(.pagetables) == TABLE_POOL_PAGES * GRANULE`.

`__image_size` — RFC-0003's one required addition to this file — is `__kernel_end - KERNEL_BASE` and
now includes the pool, the guard and the stack. It grows, and growing it may move the 4 MiB minimum
machine size RFC-0003 measured as its O-11, because QEMU refuses a machine with no room for the blob
after the kernel. Criterion 3 boots the smallest size the profile claims.

### 3. The descriptors

`kernel/src/arch/aarch64/mmu.rs`. **SPEC**: every field position and encoding below is from the Arm
architecture and is a REVIEW criterion (criterion 19), not something this document measured.

`MAIR_EL1` holds two attributes and no more: index 0 Normal Inner/Outer Write-Back non-transient,
read- and write-allocate; index 1 Device-nGnRnE. Two is the whole vocabulary — one for memory, one for
the console.

Four leaf kinds, and every leaf is an L3 page descriptor:

| Kind | `AttrIndx` | `AP[2:1]` | `SH` | `PXN` | `UXN` | used for |
| --- | --- | --- | --- | --- | --- | --- |
| code | 0, Normal | `0b10` RO at EL1 | Inner | 0 | 1 | `.head` `.vectors` `.failpath` `.text` |
| read-only data | 0, Normal | `0b10` RO at EL1 | Inner | 1 | 1 | `.rodata` |
| read-write data | 0, Normal | `0b00` RW at EL1 | Inner | 1 | 1 | `.guard` `.data` `.bss` `.stack`, bitmap |
| device | 1, Device | `0b00` RW at EL1 | none | 1 | 1 | the console's one page |

`AF` is 1 in every leaf, or the first access is an Access Flag fault. `nG` is 0. No hierarchical
attributes are set in table descriptors: `APTable`, `XNTable` and `PXNTable` stay zero, so a leaf's
effective permission is a function of the leaf alone. Making it a function of two levels is a second
place for it to be wrong and a second place a reviewer has to look.

**Code is read-only and rodata is not executable, and the second one costs alignment padding.** That
padding is what the Constitutional impact section measures. It is the price of per-page permissions on
a layout whose sections interleave, and the alternative — one RWX map of the image — is rejected in
the Alternatives with the reason.

**`SCTLR_EL1.WXN = 1` as well.** Write permission then implies execute-never regardless of what the
descriptor's `PXN` bit says, so "no writable page is executable" holds even where a descriptor is
wrong. It is one bit and it makes a property independent of getting a table right. Nothing in this
design needs a page both writable and executable, which is the only thing it forbids.

**`SCTLR_EL1.A = 1`.** With translation off, every data access is Device-nGnRnE, where an unaligned
access faults; with Normal memory it does not. Enabling the MMU therefore *relaxes* alignment, and a
latent unaligned access that CI catches today would become silent tomorrow — the wrong direction for
a change to move a failure mode. The target is `+strict-align`, so the compiler emits none. If the
boot proof of criterion 3 produces an alignment fault, that is a finding about an unaligned access, to
be reported; it is not cleared by dropping the bit.

### 4. Turning it on

`SCTLR_EL1.C = 1` and `SCTLR_EL1.I = 1` go on with `M`. This is not an optimisation and it is not
optional: with `C = 0` every access to Normal memory behaves as Non-cacheable whatever `MAIR_EL1`
says, so the map would describe Normal Write-Back memory and the machine would not have any — and
§7's argument about exclusive monitors would be void. A design that turned translation on and left the
caches off would have written down a memory type it did not have.

`TCR_EL1` is assembled from named constants, never written as one magic number. The fields, with the
two that are read from the machine rather than chosen:

`T0SZ = 25` · `TG0 = 0b00` (4 KiB) · `SH0 = 0b11` Inner Shareable · `IRGN0 = ORGN0 = 0b01` Normal
Write-Back read/write-allocate, so the walker's own reads are cacheable · `EPD0 = 0` · `EPD1 = 1`,
disabling `TTBR1` walks · `A1 = 0` · `TBI0 = TBI1 = 0` · `HA = HD = 0` · **`IPS` = whatever
`ID_AA64MMFR0_EL1.PARange` reports**, because an `IPS` narrower than an output address in use is an
address-size fault and RFC-0003 §7 states in terms that pinning the output size to 32 bits is right
for QEMU virt and wrong for a machine whose memory starts above 4 GiB.

**`TG1` encodes the granule differently from `TG0`.** For `TG0`, 4 KiB is `0b00`; for `TG1`, 4 KiB is
`0b10`. Copying one into the other selects a different granule, silently, on the half of the address
space this design disables — which is the kind of defect that surfaces at M3 rather than now. `TG1` is
set to the 4 KiB encoding for `TG1`, `T1SZ` to a legal value, and criterion 19 asks a reviewer to
check both against the field description rather than against this sentence.

The sequence — **SPEC throughout, assembled but never executed (§0, item 1):**

1. write the tables (translation off, so every store lands at the endpoint);
2. **invalidate** the table pool to the point of coherency, by virtual address, at the line size
   `CTR_EL0.DminLine` gives. Cache contents at reset are architecturally UNKNOWN, and a stale line
   over a descriptor is a walk into rubbish. It must be `dc ivac`, *invalidate*, and **not**
   `dc civac`: a clean-and-invalidate writes the stale line back over the descriptors that were just
   written. The two differ by three characters and by everything;
3. `dsb ish`, so the writes and the maintenance are complete before the walker can see them;
4. `msr mair_el1`, `msr tcr_el1`, `msr ttbr0_el1`, `msr ttbr1_el1, xzr`, then `isb`;
5. `tlbi vmalle1`, `dsb nsh`, `isb` — TLB contents at reset are UNKNOWN too;
6. `ic iallu`, `isb` before the instruction cache is enabled;
7. read `SCTLR_EL1`, set `M | C | I | A | WXN`, write it back, `isb`. The `isb` is the instant: the
   next instruction is fetched through the new map, and with an identity map it is the same
   instruction it would have been.

Before any of that: read `ID_AA64MMFR0_EL1`, and refuse — legibly, with translation off — if
`TGran4` says the 4 KiB granule is not implemented. **The refusal is the point.** The alternative is a
design whose correctness rests on what this document remembers about `-cpu cortex-a72`, and this
project has paid for that class of sentence more than once.

Where it runs: `boot_rust` gains one step between RFC-0003's step 5 (construct the `FrameAllocator`,
which is what fixes the bitmap's extent) and step 6 (hand `BootResources` to `kernel_main`). Every
failure — granule unsupported, an address at or above `1 << 39`, the pool exhausted, a section
boundary not granule-aligned, the bitmap outside what can be mapped, verification failing — writes
`SKYNET_MEM_FAIL` and one of a fixed set of `&'static [u8]` reasons to the console and powers the
machine off, which is RFC-0003 §5's mechanism unchanged. No new marker, no new vocabulary, no new
authority, and it happens before the boot marker so `ci/boot-test.sh` fails on the marker's absence
while the console says why.

### 5. Where the tables live, and how many there are

`.pagetables` is `TABLE_POOL_PAGES` granules, `NOLOAD`, reserved by the linker, inside
`[KERNEL_BASE, __kernel_end)` — so RFC-0003's reservation of the kernel image already covers it and
the allocator can never hand a table page to anyone. Entry 0 of the pool is the L1 table; the rest are
handed out in order as the map is built, and running out is a typed error, not a truncated map.

**Why the linker and not the frame allocator.** Taking table pages from `FrameAllocator::alloc` is
genuinely attractive: no fixed count, no guess, no reserved pages wasted on a machine that needs
fewer. It is rejected on three counts. The tables' addresses would vary per boot, so "the tables are
not in the map" stops being a link-time fact and becomes a runtime argument. A link-time assertion
could no longer bound the pool. And the kernel would be writing into frames the allocator manages,
which is the property RFC-0003 §7 went out of its way to preserve — *the allocator never touches the
frames it manages; only its bitmap needs to be mapped*.

**How many pages.** The mapped set is three runs: the image up to the pool, then the stack together
with the bitmap immediately above `__kernel_end`, then the console's single page. So the requirement
is one L1, one L2 per distinct 1 GiB of that set, and one L3 per distinct 2 MiB — the console's
gigabyte and the kernel's are different, and everything else depends on how far above `__kernel_end`
the bitmap reaches, which is a runtime quantity. The count is therefore computed, not assumed, and
**RAN** on the host against the linked layout:

| RAM | bitmap | pool pages |
| --- | --- | --- |
| 8 MiB | one granule | 5 |
| 128 MiB | one granule | 5 |
| 16 GiB | 512 KiB | 5 |
| ~57 GiB | ~1.8 MiB | 6 |
| 128 GiB | 4 MiB | 7 |

`TABLE_POOL_PAGES = 8`. Five are needed on every machine the project can boot today, and the three
spare are three more L3 tables, i.e. 6 MiB of additional mapped range — three quarters of nano's
entire RAM, and about forty-five times the mapped set measured in §0's item 3. It is a guess with one
derivation behind it, exactly like RFC-0003's `MAX_REGIONS = 8`, and it is O-3.

The arithmetic that produces that table — level indices, how many tables a set of ranges needs — is
portable integer work and goes in **`kernel/src/paging.rs`**, in the library target, with
`#[cfg(test)]` tests. §9 explains why that is a partial answer to RFC-0003's O-7 and not a whole one.

### 6. The guard, and the frame that used to skip it

The guard is `GUARD_SIZE` of unmapped address space immediately below `__stack_bottom`. What it
buys, precisely:

**An incremental overrun faults on its first write past the floor.** The stack descends into a region
that does not translate, and a translation fault at EL1 is what RFC-0002's vector table already
reports. That is `tasks/open/T-0008.toml`'s first residual — the band that was bounded at four
exceptions and silent, exiting 124 — and its acceptance criterion asks for *a report or a fault that
cannot be reached by further overrun*. What it gets is the second, and then the first: the fault
handler runs on the faulting stack (RFC-0002 O-1, unfixed here, see O-5), so its own prologue writes
into the guard and faults again; the vector entry touches no stack, advances the ladder, and the
emergency path prints `SKYNET_REFAULT` and issues PSCI `SYSTEM_OFF`. Bounded, and it speaks. The
console and PSCI both survive because the console's page is mapped and the emergency path builds its
address with a `movz` and holds nothing.

**Destroying the vector table becomes impossible rather than distant.** That is the second residual's
criterion in its own words. `.vectors` is a read-only mapping; a write to it is a permission fault.
So is a write to `.failpath`, to `.rodata`, and to `.text` — which is what made the first residual's
band silent, since what the overrun destroyed was the code that reports.

**The single large frame is the one that needed thought, and the answer is an inequality.** The third
residual is a stack frame larger than the distance to be crossed, reaching the far side in one
instruction and touching nothing on the way. A guard of one granule does not help if a frame steps
over it. So:

> The largest single decrement of `sp` anywhere in the image must not exceed `GUARD_SIZE`.

If that holds, the first write of every frame lands no more than `GUARD_SIZE` below where the previous
frame ended, so the first write past the floor is inside the guard. It is checkable from the image
with `objdump`, and criterion 5 makes it a check rather than a hope. `GUARD_SIZE` is **two
granules**, so the inequality has margin rather than being satisfied exactly.

Two things about it must be said rather than assumed. First, it bounds the *step*, and a frame is safe
only if it writes somewhere within itself; every non-leaf frame stores the link register, and a leaf
frame that allocates without writing is dead — but that is an observation about generated code, not a
guarantee from the language, and it is O-7. Second, **the toolchain is already doing most of the
work**: §0's item 4 measured LLVM emitting an inline probe loop that steps one page at a time and
touches each step, so a 70,000-byte frame produces a largest step of 4,096. `tasks/open/T-0008.toml`
says of the third residual that *that is ordinary Rust*, and for the compiler this project uses,
compiled here, it is not. Whether the bare-metal target enables the same probing is **UNVERIFIED** —
its `core` is not installed here, so the comparison could not be made — which is exactly why the
Conformance criteria check the inequality on the built image instead of believing either answer.

The discipline T-0006 and T-0007 already carry — report the largest stack object introduced, with
1 KiB as the line — stops being a discipline and becomes an inequality the build can fail.

### 7. `swap`, and the word the comment was missing

`fail.rs` documents at length why the re-entrancy guard is a relaxed load followed by a store rather
than a `swap`:

> `swap` compiles to `ldxr`/`stxr`, an exclusive-monitor pair. The MMU is off, so this is
> Device-nGnRnE memory, and the architecture does not guarantee exclusive monitors work there. A
> `stxr` that never succeeds is an infinite retry loop in the first instructions of the handler whose
> entire purpose is to stop an infinite loop.

**The direction is right and the condition is wrong.** Confirmed and corrected, all **SPEC**:

- The architecture's guarantee for Load-Exclusive/Store-Exclusive is about the **memory type**, not
  about whether translation is enabled. Exclusive accesses are for **Normal** memory; on Device
  memory it is IMPLEMENTATION DEFINED whether they work at all, and where an implementation does not
  document them as permitted the effect is UNPREDICTABLE. `fail.rs`'s reasoning is sound and its
  conclusion — "becomes correct once the MMU is on" — names the wrong variable. Turning the MMU on
  with the guard word mapped Device would change nothing.
- **Normal is necessary and not obviously sufficient.** Normal Non-cacheable is treated as Outer
  Shareable, so an exclusive access to it depends on a **global** monitor in the interconnect rather
  than a local one in the core — a property of the system, not of the architecture. The condition that
  holds on any implementation is Normal, Inner Shareable, **Write-Back cacheable**, which is the
  attribute §3 gives `.guard` and every other Normal page.
- **And the mapping alone is not enough:** with `SCTLR_EL1.C = 0`, accesses to Normal memory behave as
  Non-cacheable whatever `MAIR_EL1` says. §4 sets `C = 1` for this reason among others.

So the corrected sentence has three conditions where the comment has one: translation on, the word
mapped Normal Inner-Shareable Write-Back, and the data cache enabled. All three hold after this
design.

**This RFC still does not change `fail.rs`.** The hazard `swap` removes is a race between observers,
and `fail.rs`'s own comment establishes there is one observer: a single core, interrupts masked, the
only other reader being this core taking a synchronous exception, which cannot interleave with a load.
Nothing measured argues for the change, and the failure path is the last place to make an unforced
one. What is owed is the comment: it states a condition that is not the operative one, and the
operative one is now met, so a future reader could reasonably conclude the code should change for a
reason that was never the reason. **Obligation, on the implementer of this RFC, in
`kernel/src/arch/aarch64/fail.rs`:** the paragraph names the memory type rather than the MMU, and says
that the reason to adopt `swap` arrives with the second core (RFC-0003's O-5), not with translation.

### 8. Why neither of these can be tested here, and what that costs

Two properties this design depends on are invisible to the only machine the project can run.

**QEMU models no data caches.** There is no cache hierarchy in its TCG back end, so a wrong cache
maintenance operation in §4 — including the `dc civac` mistake that would write a stale line back
over the descriptors — produces an identical, green boot. A reviewer should confirm that in QEMU's own
source rather than take it from here; the consequence either way is that criterion 19's review of the
barrier and maintenance sequence is the *only* thing standing behind it.

**QEMU's exclusive monitor is not attribute-sensitive.** `ldxr`/`stxr` succeed there on any memory
type, so a measurement showing `swap` working with translation off is not evidence that it is correct
— it is evidence that the instrument cannot see the defect. This is the same class of error the
ledger records against this repository's stack measurements: *trusting an instrument nobody audited*.
The rule that follows is criterion 20's: this claim moves on a specification citation, never on a
boot.

Both are stated here rather than in the open questions because they are not unresolved — they are
resolved, from the specification, and the thing that is unavailable is the confirmation. Naming which
of a design's properties its test rig is blind to is cheaper than discovering it on the first real
board.

### 9. Against RFC-0003 §7, and the other documents' open questions

RFC-0003 §7 hands this design five constraints. Each, by name:

1. *The allocator never touches the frames it manages; only its bitmap and metadata need mapping.*
   Honoured, and relied on: the mapped set is the image, the stack, the bitmap and one device page.
   §5 refuses to take table pages from the allocator partly to keep this true in the other direction.
2. *The bitmap sits immediately above `__kernel_end`, frame-aligned, its length known only at run
   time; whatever maps the kernel must map `[KERNEL_BASE, bitmap_end)`, not `[KERNEL_BASE,
   __kernel_end)`.* Honoured, and it is why the map is built after RFC-0003's step 5 and why the pool
   requirement is computed rather than fixed (§5).
3. *Physical addresses are `u64` and come from the device tree; a regime that pins its output size to
   32 bits is wrong for a machine whose memory starts above 4 GiB.* Honoured: `TCR_EL1.IPS` is read
   from `ID_AA64MMFR0_EL1.PARange`, addresses are `u64` in `paging.rs`, and the 39-bit input limit is
   a checked refusal rather than a truncation (O-4).
4. *`FRAME_SIZE` must equal the translation granule, and the compile-time assertion binding them
   belongs in the RFC that introduces the granule.* Discharged. `mmu.rs` carries
   `const _: () = assert!(FRAME_SIZE == GRANULE_BYTES);` — a `const` assertion, so a mismatch is a
   compile error and not a boot-time report — and `link.ld` carries the alignment assertions that bind
   the same quantity at link time. Two constants in two RFCs that must agree now fail loudly when they
   do not.
5. *The blob's frames stay reserved, and it costs 1 MiB — 100% of nano's boot-memory budget.* Not
   decided here, and one fact added: after the enable the blob is **unmapped**, so no code can read
   it whether or not its frames are free. RFC-0003's O-10 asked for a safety case for releasing them
   and answered most of it — the parser retains no reference and `MemoryMap` is copied out by value.
   The remaining half was whether some later holder might read the blob; after this design, none can.
   What is still missing is a decision about whether boot-time memory is released at all, which is
   allocator behaviour RFC-0003 does not specify. O-8, and the Constitutional impact section says why
   it can no longer be deferred: a budget already consumed in full cannot absorb a positive addition.

RFC-0003's **O-7** — whether logic under `arch/` should become host-testable, with "the descriptor
arithmetic the next RFC needs" named as the first example — is **answered in part**. The part that is
genuinely portable, the index and table-count arithmetic, moves to `kernel/src/paging.rs` in the
library target and is host-tested (criterion 18). The part most likely to be wrong, the descriptor
bit layout, stays in `arch/` and stays untestable except by booting, because a host test asserting
`leaf(pa, kind) == 0x…` checks this document's understanding of the format against itself. That is
RFC-0003's own criterion-13 problem — agreeing with one producer is not agreeing with the standard —
and the honest instrument for it is criterion 19, a review against the ARM ARM. So O-7 narrows and
does not close, and the residue is named.

Also inherited unchanged: RFC-0003's **O-4** (frames not zeroed — unmapped frames make it no better
and no worse; the right place is still the grant), **O-5** (the second core; this design adds that the
map is immutable and shared, so a second core needs its own `TTBR0_EL1` write, `MAIR`/`TCR` and TLB
invalidate and no new tables — a small addition, named so it is a decision), **O-6** (nothing measures
`[budget.boot_memory]`; §10 hands `ci/` a formula), **O-8** (the boot glue is tested by nothing; the
enable sequence is now the largest piece of it), **O-11** (the 4 MiB floor, which `__image_size`'s
growth may move — criterion 3).

From RFC-0002 — and every number in that document's series is written with its document, because it
runs two series in one file: **RFC-0002 O-9 is structurally closed.** Its request was an unmapped
page below the stack so that a corrupted re-entrancy guard stops being reachable from an overflow,
and `.guard` is now behind the guard region with the vector table read-only besides. **RFC-0002 O-1
is not closed** and is re-recorded here as this document's O-5, with the obstacle measured rather
than asserted. **RFC-0002 O-10 is narrowed, not closed** — see the Constitutional impact section,
which says exactly how far. **RFC-0002 O-11's numbers must be re-measured rather than inherited**:
it records the emergency path bounded at three exceptions with a residual hang at exit 124, and this
design changes the storm end of that ladder by making the vector table unwritable. Criterion 16 is
where the new numbers come from.

RFC-0002 also needs an amendment pass for reasons that are not this RFC's and are listed in
`tasks/open/T-0008.toml`'s `unowned.rfcs`. This document does not perform it. Naming that it is still
owed is the most an RFC on a different subject can do, and the structural complaint in that file —
that nothing in the constitution or in `governance/` turns "owed" into "assigned" — is not answered by
adding a fourth document that also names it.

### 10. What this obliges other roles, with the role named

**The orchestrator** owns `ci/` and `governance/`; `governance/roles.toml` denies both to the
architect by name. Four items, of which the first is the only one this design creates:

| # | Change | File | Why it cannot be worked around |
| --- | --- | --- | --- |
| 1 | A check for §6's inequality: the largest single decrement of `sp` in the image against `GUARD_SIZE`, with the command in criterion 5. Fail on exceeding it | `ci/constitution-check.sh` | It is the mechanism that closes `tasks/open/T-0008.toml`'s third residual. Left to review, it is a discipline again, and the file it would appear in is one no kernel patch may edit |
| 2 | A RAM-size option for the boot test, so criterion 3's three sizes are runnable | `ci/boot-test.sh` | Already on that file's unowned list for RFC-0003's criterion 4. A criterion satisfiable only by hand is satisfied once |
| 3 | `[budget.boot_memory]`, which every profile declares with `enforced_from = "M1"` and nothing measures. The quantity is now derivable: `__kernel_end - KERNEL_BASE` from `nm`, plus the bitmap's length, plus the device tree blob's `totalsize` for as long as its frames stay reserved | `ci/build.sh` | RFC-0003's O-6, and this is the contribution at which the number plausibly exceeds the declared budget rather than merely being unmeasured |
| 4 | The address-based minting check RFC-0002 O-10 prescribes. This design gives it a better hook than a grep for constructor names: the set of device addresses that translate is a short, explicit list in one file, so "which devices can this image reach" becomes a question with a written answer to compare against | `ci/constitution-check.sh` | Unchanged in ownership, and narrowed in scope by this design rather than closed by it |

**The decomposer** owns sequencing, and one file is contended by three contributions.
`kernel/src/arch/aarch64/link.ld` is being rewritten by T-0005, needs RFC-0003's `__image_size` and
`KERNEL_BASE`-comment corrections, and needs §2's layout. The order that never leaves the gate red is
T-0005, then RFC-0003's kernel half, then this — and §2's `.head` section is required by RFC-0003's
criterion 10 and made necessary by T-0005's ordering, so it cannot land before either. A task that
carries this RFC must not also carry the kernel heap: that is objective 0002's fifth criterion and a
separate design.

**The BDFL, or a vote.** `profiles/nano.toml`'s `[budget.boot_memory]` is 1 MiB, RFC-0003's blob is
1 MiB, and this design adds to it. Objective 0002's sixth criterion says the profile is amended *by
vote rather than by convenience*. The choice — release the blob's frames, or amend the number — is
recorded as O-8 and belongs to whoever holds that mandate, not to whoever writes the patch that first
exceeds it.

**A future architect.** O-6 (the move to `TTBR1_EL1` at M3) and O-5 (the fault stack) are designs, not
patches, and each is named with the constraint that blocks it here.

---

## Non-goals

Objective 0002's six `non_goals` apply unchanged. In addition, so that a patch containing any of these
is scope creep and not a matter of opinion:

- **Any change to the map after boot.** No `map`, no `unmap`, no `protect`, no page-table walk in
  privileged code after the enable, no TLB maintenance interface. The map is built once with
  translation off.
- **A high kernel virtual base, and `TTBR1_EL1` in any form.** O-6, at M3.
- **EL0, user address spaces, ASIDs, per-process tables, `nG` mappings, PAN.** M3 and M4.
- **Demand paging, lazy mapping, copy-on-write, resumable translation faults, a fixup table.** A
  translation fault is reported and the machine stops. The objective excludes the policy half of this
  by name.
- **Block descriptors and large pages.** Every leaf is an L3 page. A 2 MiB block would map memory
  nobody asked for, which is the criterion this RFC serves, and it is an optimisation nobody has
  measured.
- **More than two memory attributes.** One Normal, one Device.
- **A dedicated fault stack.** RFC-0002 O-1 assigns it to the MMU part of M1 and this declines it,
  with the obstacle measured: the vector entries are full. O-5.
- **A kernel heap.** Objective 0002's fifth criterion, and the next RFC.
- **Cache maintenance as an interface, DMA coherence, or anything about the second core.** One
  `dc ivac` over the table pool, once, inside the enable.
- **Reclaiming the device tree blob's frames.** RFC-0003's O-10. §9 adds a fact to it and does not
  decide it.
- **Zeroing frames.** RFC-0003's O-4, unchanged.
- **A portable trait for translation.** `hal.rs` gains nothing. RFC-0002 §7's argument applies
  unaltered: an abstraction over one implementation, shaped by that implementation, is not a
  contract. `paging.rs` is arithmetic, not an interface — §9.
- **Writing the `ci/` changes.** §10 lists them and names the role that owns them. No patch under
  `kernel/` may work around them.
- **Changing `fail.rs`'s load-and-store to `swap`.** §7 says why the reason to do it has not arrived.

---

## Constitutional impact

**Invariant 4, frugality *(enforced from M0)*.** This design spends real budget in two places and both
are derivations, not figures.

*Image.* Six granule-aligned permission groups mean up to five alignment gaps in the flat image, so
the padding is bounded above by `5 × (GRANULE - 1)` ≈ 20 KiB, plus `mmu.rs` and `paging.rs`. It is
measured with `objcopy -O binary "$elf" out.bin && stat -c%s out.bin`, before and against
`SKYNET_PROFILE=nano`, and criterion 2 requires the contribution to report both rather than assert the
result is small. §0's item 5 measured 20,488 bytes for a synthetic kernel of about 2 KiB of content:
on a kernel this small the padding dominates the image, and that should be stated plainly rather than
buried. It is affordable against nano's 192 KiB and it is not free.

*Boot memory.* `__image_size` grows by the table pool, the guard, and the alignment gaps —
`nm` gives `__kernel_end - KERNEL_BASE` and the contribution reports it. And here the arithmetic
reaches a conclusion this RFC cannot resolve on its own: `profiles/nano.toml` budgets **1 MiB** of
boot memory, RFC-0003's device tree blob is **1 MiB measured**, reserved and never released — its
O-10, recorded as *exactly 100% of the boot-memory budget* — and this design adds the pool, the guard
and the padding on top. Any positive addition to a budget already consumed in full exceeds it. So
either the blob's frames are released, or `profiles/nano.toml` is amended by vote, or the invariant is
violated on the smallest machine the project claims to serve. §9 supplies the new fact the chooser
needs and O-8 records that the choice is not this RFC's to make, because releasing frames is allocator
behaviour after construction and RFC-0003 specifies none.

The objective's sixth criterion says *every one of the above holds on the nano profile's budget, or
the profile is amended by vote rather than by convenience*. This is the contribution at which that
sentence stops being hypothetical.

**Invariant 1, no ambient authority *(pending, M4)*.** This is the invariant the design is really
about, and the accounting matters more than the enthusiasm.

*What it establishes.* Reaching an address nobody mapped is a translation fault taken by the hardware,
not a check in code that shares an address space with what it is checking — which is objective 0002's
`common_good` in one line. The set of device addresses that *exist* falls from the whole physical
space to one 4 KiB page. The kernel cannot write its own translation tables, because they are not in
the map; a capability table's unforgeability at M4 needs exactly that property one level up. And there
is no runtime mapping authority to inherit, because there is no runtime mapping.

*What it does not establish, said plainly.* There is one address space and one privilege level in use,
so a bug anywhere in the kernel can still write any writable page — this is not intra-kernel
isolation and must not be described as any. RFC-0002's O-10 reach-around still works against the
console's page, because that page is legitimately mapped: a portable file with a raw pointer to
`0x0900_0000` writes the operator's console after this change exactly as before. What changes is that
the same pointer aimed at any *other* device faults. The closure of O-10 remains where RFC-0002 put
it — an address-based check in `ci/`, and capabilities at M4, where the console becomes a driver's
page and not the kernel's.

**Invariant 2, user sovereignty *(pending, M5)*.** *See:* the ledger invariant 2 needs will require
memory the audited software cannot reach, and this is the first mechanism in the project that makes
"cannot reach" a property of hardware rather than of code. It is a foundation and not a delivery: at
M1 there is one address space, so nothing is yet unreachable *from* the kernel. *Revoke:* nothing
cached, nothing granted, no map to withdraw. *Refuse:* nothing attested.

**Invariant 5, zero telemetry *(pending, M6)*.** No new outward path, and the first structural bound
on the old one: after this change the only device address that translates is the console's, so an
outward channel through any other device is a fault rather than a review finding. Every byte the
failure path can emit remains a compile-time constant.

**Invariant 6, HAL boundary *(enforced from M0)*.** Descriptors, `MAIR_EL1`, `TCR_EL1`, `SCTLR_EL1`,
the barriers, the granule and the identity-map decision are all in `kernel/src/arch/aarch64/mmu.rs`
and `link.ld`. `platform.rs` gains **one** constant — the console's mapped length, one granule —
which is a board fact and belongs there; RFC-0003 was able to say it added none, and this cannot.
`hal.rs` is unchanged. `kernel/src/paging.rs` is portable arithmetic: it names no architecture, no
register and no `cfg`, and holds no physical address in a `usize`.

**Invariant 7, no kernel dependencies *(enforced from M0)*.** No crate does this for us and none is
used. `Cargo.lock` still resolves one package.

**Invariant 3, total provenance *(enforced now)*.** §0 is this section's substance: what was run, what
is from the specification, and what is neither. Two claims in this design **cannot be verified by a
boot at all** and §8 names them, so a green gate must not be offered as evidence for either. Every
figure in this document is either accompanied by the command that produced it and the inputs it was
given, or is absent because the machine could not produce it.

**Invariant 10, English repository.** All identifiers, comments and prose in English.

---

## Conformance criteria

Every proof below inherits two rules the tree paid for, from
`.provenance/ledger.jsonl`'s corrections and `tasks/open/T-0008.toml`'s fourth and fifth criteria: an
address relative to the stack is **derived from `__stack_top` at run time**, never from a constant
read out of a previous build; and an instrument that adds bytes to the image moves every symbol above
it, so a measurement is honest only when the instrument cannot move the geometry it measures. A
figure quoted from an earlier build is not evidence about this one.

A precondition, not a criterion: `ci/build.sh --size` and `ci/boot-test.sh` do not rebuild
(`tasks/open/T-0008.toml`, unowned `ci/` items). Every measurement below must be taken from an
artefact built from the tree under review, and the contribution must say how that was established.

**Mechanical.**

1. `ci/build.sh`, `--lint`, `--test` and `ci/boot-test.sh` pass. Boot output is unchanged:
   `SKYNET_BOOT_OK`, no `SKYNET_PANIC`, no `SKYNET_FAULT`, exit 0.
2. `ci/build.sh --size` and `SKYNET_PROFILE=nano ci/build.sh --size` pass, and the contribution
   reports the flat image size and `__kernel_end - KERNEL_BASE` **before and after**, with the
   commands. Not "within budget" — the two numbers.
3. **PROOF:** boot **one** flat image, stated by hash, at `-m 128M`, `-m 64M` and `-m 8M`, with the
   MMU enabled, and show `SKYNET_BOOT_OK` and exit 0 at each. `-m 8M` is nano's ceiling and the
   smallest RFC-0003 exercised; if `__image_size`'s growth has moved RFC-0003's 4 MiB floor, this is
   where it shows. `ci/boot-test.sh` has no RAM option — that is on `ci/`'s list in
   `tasks/open/T-0008.toml`, and until it lands this criterion is satisfiable only by hand, which the
   contribution must say.
4. **PROOF:** `ID_AA64MMFR0_EL1` is read on the gate's machine and reported, with `TGran4` and
   `PARange` decoded, and the value of `TCR_EL1.IPS` derived from it. Then boot a build whose granule
   check is inverted and show `SKYNET_MEM_FAIL` with the granule reason, no boot marker, clean exit.
   The point is that the refusal path exists and works, not that this CPU passes.
5. **The guard inequality, mechanically.** The largest single decrement of `sp` in the image must not
   exceed `GUARD_SIZE`:

   ```sh
   objdump -d "$elf" \
     | grep -oE 'sub[[:space:]]+sp, sp, #(0x)?[0-9a-fA-F]+(, lsl #12)?' \
     | awk '{ imm=$4; sub(/,$/,"",imm); sub(/^#/,"",imm); v=strtonum(imm);
              if ($0 ~ /lsl #12/) v *= 4096; if (v > m) m = v } END { print m }'
   ```

   Two companions, because one form is not all of them: the pre-index form
   `grep -oE '\[sp, #-[0-9]+\]!'` (which decrements and writes at once, and whose immediate is
   architecturally small), and `grep -E 'mov[[:space:]]+sp,|sub[[:space:]]+sp, sp, x'`, which must
   find only `_start`'s single load of the initial stack pointer. A computed decrement of `sp` is a
   finding, because the inequality cannot bound it.

   The first version of this command was **wrong** and is recorded so the implementer does not repeat
   it: `sed -E 's/.*#([0-9a-f]+).*/\1/'` matches greedily to the *last* `#`, which is the `#12` in
   `lsl #12`, and reported 12 bytes for a 4,096-byte step. An instrument for this project gets
   checked against a case whose answer is known before it is trusted — §0's item 4 is that case.
6. **PROOF:** the four descriptor kinds, dumped at run time from the tables the kernel built, beside
   the group boundaries from `readelf -S` and `nm`. Not a claim about which section got which
   permission — the dump. This is the criterion that replaces the summarising sentence §2 declines to
   write.
7. `ci/constitution-check.sh --check hal-boundary`, `--check no-kernel-deps`, `--check
   vector-alignment` and `--check minting-sites` pass, the last still reporting **4** call sites —
   two in `boot.rs`, two in `fail.rs`. This design mints nothing.
8. `grep -rnE 'asm!|naked_asm!|global_asm!|core::arch::|#\[unsafe\(naked\)\]|target_arch' kernel/src
   | grep -v '^kernel/src/arch/'` is empty; in particular `paging.rs` contains none of them.
9. `grep -rn 'static' kernel/src` still finds exactly one `static` item, `IN_FAILURE`, and no
   `static mut`. The table pool is linker-reserved memory reached through one `&'static mut`
   constructed at one call site, like RFC-0003's bitmap; it is not a `static`.
10. `nm` places `_start` at `KERNEL_BASE` and `readelf -h`'s entry point agrees, and a hex dump of the
    first 64 bytes of the flat image shows `code0` a branch, `text_offset = 0x80000`, `image_size`
    equal to `__kernel_end - KERNEL_BASE`, and `0x644d5241` at offset 56. This is RFC-0003's criterion
    5b re-run, because `.head` is what makes it true and T-0005's layout made it false.
11. Every new link-time assertion is shown to refuse. Break each one, one at a time, and record the
    message. §0's item 2 is the shape, including the case where a break linked cleanly and why.

**PROOF — run these, do not assert them.**

12. **Reaching an address nobody granted.** With addresses **derived at run time** from linker
    symbols, not written as constants: read `__stack_guard_start`, read `__pagetables_start`, read
    `0x0900_1000` (the second PL011), read `KERNEL_BASE - GRANULE`. Each must produce `SKYNET_FAULT`
    naming a data abort at the same EL, with `FAR_EL1` equal to the address read and the syndrome's
    fault status naming a **translation** fault at the level the walk stopped — level 3 for all four,
    because each lies inside a 2 MiB block whose L2 entry and L3 table do exist. Report the syndrome,
    not a paraphrase.
13. **Read-only code.** Write one byte at the address `nm` gives for a symbol in `.text`, obtained at
    run time. Expect `SKYNET_FAULT` with a **permission** fault, not a translation fault, and the
    distinction visible in the syndrome.
14. **Destroying the vector table.** Write one word at `ADDR(.vectors)`, obtained at run time. Expect
    a permission fault. This is `tasks/open/T-0008.toml`'s second residual: its criterion asks that
    destroying the table be *impossible rather than merely distant*, and a permission fault is what
    impossible looks like.
15. **Execute-never.** Branch to an address in `.data` and to an address in `.stack`. Expect
    `SKYNET_FAULT` naming an **instruction** abort with a permission fault. Then show the two
    mechanisms are independent: once with `SCTLR_EL1.WXN` cleared and `PXN` left set, once with `PXN`
    zeroed on the writable group and `WXN` left set. Both must still fault. A design that relies on
    one of them without knowing which is relying on neither.
16. **The stack overflow, re-measured.** Reproduce the band `tasks/open/T-0008.toml` records as
    bounded and silent, with the floor derived from `__stack_top` at run time and the writer outside
    the descent path, and show what happens now. Report the exception count and the console. Do not
    quote that file's depths: they are properties of a build that contained a different instrument.
17. **The single large frame.** A function with a stack object larger than `GUARD_SIZE`, called with
    the stack nearly full, and the resulting fault — plus the `objdump` output showing how the
    compiler decomposed its prologue. If it emitted a probe loop, say so; if it emitted one large
    decrement, criterion 5 should already have failed the build, and that is the result to report.
18. `paging.rs`'s tests run under `cargo test` and pass: level indices at each boundary, the table
    count for a set of ranges including one with a hole, and the pool-exhaustion case returning its
    typed error.

**REVIEW.**

19. Every descriptor field, every `TCR_EL1` and `SCTLR_EL1` bit position, and every barrier in §4 is
    checked against the Arm Architecture Reference Manual, and the check is stated in the
    contribution. In particular: `TG0` and `TG1`'s differing granule encodings; that the maintenance
    op is `dc ivac` and not `dc civac`; and that `AF` is set in every leaf. A wrong constant here is a
    defect in this RFC, not in the patch.
20. §7's exclusive-monitor argument is checked against the specification, and **not** against a QEMU
    run. A boot in which `swap` appears to work proves nothing about it — §8 says why.
21. No `unsafe` block lacks a `// SAFETY:` naming the invariant that makes it sound; in particular the
    one `&'static mut` over the table pool (linker-reserved, one construction site, unmapped after the
    enable) and the enable itself.
22. `mmu::verify` is called before the enable, on every path, and checks the enable code's own
    address, the current `sp`, `VBAR_EL1` and the console base — each derived, none constant. A patch
    that skips it on the fast path removes the only thing standing between a wrong map and silence.
23. No function in `mmu.rs` or `paging.rs` writes a table page after `SCTLR_EL1.M` is set, and no
    public function offers to.

---

## Alternatives considered

**Map all of RAM read-write with 2 MiB blocks, and be done.** The most tempting option by a wide
margin, and the one that would take about ten lines: one L1 and one L2 table, block descriptors, no
permission groups, no alignment padding, no guard-page arithmetic, no pool sizing — and the MMU is
genuinely on. Rejected because the criterion this RFC serves is *everything else unmapped by default*,
and a read-write map of all of RAM is its exact negation; because it creates a writable alias of the
page tables and of every frame the allocator manages, which is the retrofit invariant 1 cannot
survive; and because RFC-0003's Motivation already rejected it in advance, in terms, as the reason
discovery and frames were done first. Recorded at the top of this list because it is what a reader in
a hurry would propose.

**A high kernel virtual base in `TTBR1_EL1`.** The layout every mature kernel ends with, and doing it
now would avoid a migration at M3. Rejected because it requires the kernel to be linked at a virtual
address and to move the program counter from a physical to a virtual one — either position-independent
code or a two-stage map and a jump — and because `KERNEL_BASE`'s single meaning splits into a load
address and a link address, which is exactly what RFC-0003's image header (`text_offset`,
`image_size`) is defined in terms of. That is a boot-protocol change stacked on a translation change,
in a milestone with no EL0 to be separated from. O-6 names it as M3's, with the relink.

**A 64 KiB granule.** Fewer levels for the same reach and one L3 table covering 512 MiB, so the pool
question nearly disappears. Rejected because `FRAME_SIZE` is settled at 4 KiB and RFC-0003 §7 requires
the granule to equal it; because every reservation rounds outward to a whole frame, so the kernel
image's tail and the 1 MiB device tree blob each round outward by sixteen times as much on a profile
whose whole budget is 1 MiB; and because the stack guard's granularity coarsens by the same factor. A
16 KiB granule is rejected for a different reason: whether the gate's CPU implements it is not
something this document knows, which is why §4 reads `ID_AA64MMFR0_EL1` instead of choosing on
recollection.

**Table pages from the frame allocator.** Rejected in §5, with the three reasons. The cost of
refusing is a fixed pool that is a guess — O-3 — and that cost is the same shape as RFC-0003's
`MAX_REGIONS`.

**A guard page and nothing else: map the whole image read-write-execute at 4 KiB.** Discharges all
three of `tasks/open/T-0008.toml`'s residuals with one hole in the map, and costs no alignment
padding at all, because permission boundaries are what force granule alignment. Genuinely tempting
against the padding measured in §0's item 5, where the padding exceeds the kernel. Rejected because
*execute-never on data, read-only on code* is the other half of what page tables are for, and because
the first residual's silent band was caused by an overrun destroying the failure path's **code** —
which a read-write mapping leaves destructible by anything that gets a pointer wrong, guard page or
not.

**Keep the padding down by moving `.guard` up into the writable group.** It is four bytes sitting
between two executable sections, and moving it would remove two granule boundaries, saving two pages
of image and two of mapped memory. Refused because T-0005 asserts `ADDR(.vectors) < ADDR(.guard)` and
`ADDR(.guard) < ADDR(.failpath)`, that branch is pinned under review, and this RFC has no business
asking for an assertion to be deleted to save eight kilobytes of a budget with 90% of it unspent. It
is recorded because it is the first thing anyone measuring the image will suggest.

**Enable translation with the caches off.** Fewer variables at once, no cache-maintenance question in
the enable sequence, and the exclusive-monitor argument would stay exactly where it is instead of
moving. Rejected because with `SCTLR_EL1.C = 0` every Normal access behaves Non-cacheable regardless
of `MAIR_EL1`, so the tables would describe a memory type the machine does not have — a gap between
the document and the machine, which is the specific failure this project keeps paying for.

**A dedicated fault stack, switched to by the vector entry.** RFC-0002 O-1 asks for it and assigns it
here, and it would turn a stack overflow's outcome from `SKYNET_REFAULT` into a full fault report.
Rejected on a measurement rather than a preference: the entries are full. The ledger records vector
entry 0 spanning **124 of its 128 bytes**, with a single `NOP` of padding — and the fourth rung
T-0005 added had to fit in two instructions for that reason. Setting `sp` from a linker symbol is
three more, which does not fit, so a fault stack means restructuring all sixteen entries through a
trampoline — work in the one path whose failure mode is silence, for a report the guard page already
replaces with a marker and a clean shutdown. O-5.

**A portable trait for translation, and a `Mmu` in `hal.rs`.** Rejected by RFC-0002 §7's argument,
which needs no restatement: a contract defined by its only implementation is not a contract. What is
portable here is arithmetic — how many nine-bit indices a virtual address has and how many tables a
set of ranges needs — and that is `paging.rs`, which offers no interface for anyone to implement.

---

## Open questions

**O-1. The barrier and cache-maintenance sequence has been assembled and never executed, anywhere.**
§4 states it, §0 records that every instruction in it encodes, and that is the entire extent of the
evidence. Its correctness rests on criterion 19's review against the ARM ARM, and §8 explains why a
green boot adds nothing: QEMU models no caches, so the difference between `dc ivac` and `dc civac`,
and between having the maintenance and omitting it, is invisible on the only machine available. This
is the single largest unverified claim in the document and it is first for that reason.

**O-2. `SCTLR_EL1.A = 1` is a judgement this document could not test.** The argument is that turning
the MMU on relaxes alignment and that a failure mode should not become quieter across a change; the
risk is that some code — a compiler-emitted `memset`, an intrinsic — performs an access the
`+strict-align` target was believed to preclude. §3 says the fault is a finding rather than a reason
to clear the bit, which is the right response and not a guarantee that the bit is right.

**O-3. `TABLE_POOL_PAGES = 8` is a guess with one derivation behind it.** Five pages suffice on every
machine the project can boot, seven at 128 GiB of RAM (§5, measured on the host). The failure is
legible rather than silent, which is the most a fixed pool can offer, and the number should be
revisited by whoever first meets a machine whose mapped set is not two runs. Same shape as RFC-0003's
`MAX_REGIONS`, and same honest answer.

**O-4. A 39-bit input address space is a constant, and above 512 GiB it is the wrong one.** §4 refuses
to map an address at or above `1 << 39` rather than truncating it, so the failure is a report. The fix
is `T0SZ = 16` and a fourth level, which is one constant and one more level of the same arithmetic —
named now so it is a decision by whoever meets such a machine and not a discovery.

**O-5. The fault stack is not built, and RFC-0002 O-1 remains open with a measured obstacle.** A
stack overflow now faults at the guard, and the handler still runs on the faulting stack, so what it
produces is `SKYNET_REFAULT` and a clean PSCI shutdown rather than a full report. The obstacle is
measured: vector entry 0 spans 124 of its 128 bytes, so switching stacks means restructuring all
sixteen through a trampoline, in the path whose failure mode is silence. It should be designed with
whatever else touches those entries, not bolted on by whoever first wants a better report.

**O-6. The kernel stays in `TTBR0_EL1`, and M3 has to move it.** EL0 will want `TTBR0`, so the
kernel's own map belongs in `TTBR1` with the kernel linked at a high virtual address. That is a
relink, a position-independent or two-stage boot path, and a redefinition of what `KERNEL_BASE` means
relative to RFC-0003's `text_offset` and `image_size`. Doing it now would have doubled this design for
a benefit no criterion at M1 asks for; leaving it unrecorded would have made it a surprise at M3.

**O-7. §6's inequality has a precondition that is a property of generated code, not of the language.**
"The largest single decrement of `sp` does not exceed `GUARD_SIZE`" bounds the step; it makes the
first write past the stack floor land in the guard only if each frame writes somewhere within itself.
Every non-leaf frame stores the link register and a leaf that allocates without writing is dead code,
so it holds — for code this compiler generates, today. A future code generator, or an `alloca`-shaped
construct, could break it without breaking the check. The check would still catch the case it can see;
what it cannot see is a decrement it cannot read as an immediate, which criterion 5's third grep
exists to surface.

**O-8. Whether boot-time memory is ever released, and so whether nano's budget holds.** RFC-0003
opened this as its O-10 with the blob's 1 MiB against nano's 1 MiB; this design adds the table pool,
the guard and the alignment padding to the same side of the inequality, and adds the fact that after
the enable the blob is unreachable regardless. The safety case for freeing its frames is now complete.
The decision is not — it is allocator behaviour after construction, which nothing specifies — and it
must be made before `ci/` gains the boot-memory check, rather than by that check failing.

**O-9. `paging.rs` is a portable module with exactly one user, and that is a smell this document has
not resolved.** RFC-0001 and RFC-0002 both rejected portable abstractions over single
implementations, and the defence offered in §5 — that arithmetic over nine-bit indices is not an
interface and would be the same for RISC-V's Sv39 — is a defence and not a proof. If the second
architecture arrives and `paging.rs` needs changing to accommodate it, the module was an abstraction
after all, and the right conclusion will be that it should have stayed in `arch/` with its tests
unwritten. Recorded so that whoever ports this can say which it was.
