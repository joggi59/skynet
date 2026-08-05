# RFC-0003: What memory exists, and who has it

- Objective: 0002 (memory, and the ground isolation stands on)  Status: draft, amended
- Author: architect                        Model: claude-opus-5[1m]
- Milestone: M1, second and third parts
- Amended: 2026-08-05, by the architect, after the premise in §1 was measured and failed

## Amendment: the kernel cannot reach a device tree, and this design assumed it could

**Read this before anything below it.** The first half of this RFC parses a device tree that, for the
artefact this project currently builds, is not in memory at all. That is not a defect in the parser
design; it is a false premise underneath it, recorded as open question O-1 with the note that the
architect had no QEMU and could not check. The check has been made. The answer is the bad one, and
three things this document asserted are false:

| This RFC said | Measured |
| --- | --- |
| QEMU places a device tree at `0x4000_0000` for an ELF linked above `loader_start` | **Nothing is placed.** All zeros at `0x4000_0000` at `-m 128M`, `64M` and `8M`, on a halted machine; no `0xd00d_feed` anywhere in RAM; every GPR zero at entry |
| `-dtb <file>` would supply one — "cheap", per O-1 | **It does not.** With `-kernel <elf> -dtb <blob>`, a scan of all 128 MiB of guest RAM finds no aligned `0xd00d_feed`. QEMU materialises the blob only inside its `is_linux` path, and an ELF is not `is_linux` |
| `DTB_MAX_LEN = 0x0008_0000` bounds the blob — the gap between `0x4000_0000` and `KERNEL_BASE` | **The blob is `0x10_0000` bytes**, twice that gap, at every RAM size from 4 MiB to 16 GiB. Even had it been placed at `0x4000_0000`, this design would have rejected it as too large — and QEMU refuses the placement outright, because a 1 MiB blob at `0x4000_0000` overlaps a kernel at `0x4008_0000` |

The route chosen is **boot as a Linux-format `Image`**, and it was run rather than reasoned about:
§1 is rewritten around it and §1a records the nine measurements, with the machine, the QEMU build and
the artefact's hash. The kernel is then *told* where the blob is, in `x0`, which is what the aarch64
boot protocol has always promised and what `ci/boot-test.sh --contract` claimed before RFC-0001
corrected it. RFC-0001's correction was right — for an ELF, `x0` is zero — and it settled the wrong
variable: it fixed the contract to match the artefact, where the artefact was the thing that could
change. This amendment changes the artefact and restores the sentence.

**Every route touches the boot contract, and the boot contract is in `ci/`, which this role may not
write.** §8 states that obligation as a list, with the role that owns it. It is the one part of this
amendment that cannot be discharged by the person implementing it.

What survives unchanged: §2's parser (its format constants are now checked against a real blob and
were correct), §4's allocator, §6's crate split, and the whole of the Non-goals list.

## Motivation

The kernel does not know how much memory the machine has. It knows one address — `0x4008_0000`,
where the linker put it — and it knows where its own image ends, because a linker symbol says so.
Everything else is unknown, and nothing in the kernel can hand out a byte of it.

Objective 0002's success criteria are ordered, and the two this RFC serves come second and third:

> 2. The kernel knows which physical memory exists and which of it is already spoken for, **from the
>    device tree rather than from constants**
> 3. Frames can be allocated and freed without the allocator losing track, **proven by a test that
>    exhausts and recovers the pool**

They are one design. The allocator's input is the parser's output, and neither is judgeable without
the other: a parser with nothing consuming it proves nothing about whether it read the right thing,
and an allocator over a hardcoded range is the constant the objective's criterion 2 exists to
forbid.

**Why not the MMU first.** The case for reordering is real and should be recorded rather than
waved at: every unfixable finding on the fault path — RFC-0002's O-1 and O-9, and the stack overflow
measured at 1,495,553 exceptions with an empty console and recorded in the open task on that path —
is waiting on page tables, and page tables for a fixed boot map can be reserved by the linker script,
so they do not in fact need an allocator. The dependency in the objective's `statement` is weaker
than it reads.

It was rejected anyway, on the consequence rather than the dependency. A map built before the
allocator exists has two options and both are bad. Map only the kernel image, and the allocator
arrives unable to touch a single frame it hands out, which forces the MMU RFC to be amended by the
one after it — the partial-amendment failure RFC-0001 documents at length. Map all of RAM read-write
instead, and "everything else unmapped by default" is false at the milestone whose criterion it is.
Doing discovery and frames first costs one contribution's delay on the fault path and lets the MMU be
designed once, with the allocator's requirements visible. §7 records what this design deliberately
hands it.

**What this cannot assume.** RFC-0001 established, against QEMU's `hw/arm/boot.c`, that an ELF image
is not treated as a Linux kernel: the bootloader stub that loads the device tree address into `x0` is
never written, and every general-purpose register is zero at entry. That finding has since been
carried into `ci/boot-test.sh --contract`, which now states it explicitly and cites RFC-0001 O-2 —
checked, because an earlier draft of this RFC asserted the contract was still wrong and it is not.

What the contract does **not** say is that a device tree exists at all, or where. Its list of "QEMU
virt specifics the kernel may rely on" is RAM base, PL011 base, entry state and PSCI conduit; a
device tree is not on it. So the first question this design has to answer is not how to parse a
device tree. It is how to find one, given that the only thing the kernel may rely on says nothing
about it.

The first revision of this RFC answered that with an address read out of QEMU's source and never
run. It was wrong twice over — the address is not where the blob goes, and for an ELF there is no
blob to go anywhere. The answer now is that **the kernel does not find the device tree; it is handed
one**, in `x0`, because the artefact changes to the format that makes QEMU hand it over. That moves
the fragile part out of the kernel and into the boot contract, where it is a promise somebody can
check rather than a constant somebody guessed. §1 is that design; §1a is the measurement; §8 is what
`ci/` must do to make the promise true.

## Design

### 0. What is established, and what is not

Every row marked **measured (amendment)** was run on QEMU 10.2.2 (`qemu-10.2.2-1.fc44`), rustc
1.97.1, `-M virt -cpu cortex-a72`, on 2026-08-05. §1a gives the commands.

| Fact | Status |
| --- | --- |
| `x0` is zero at entry for an **ELF** image; it is not a DTB pointer | Verified in RFC-0001 against `hw/arm/boot.c`; **re-measured (amendment)** on this tree's own binary: `X0=0x0000000000000000` |
| ~~QEMU loads a device tree at `0x4000_0000` for an ELF~~ | **FALSE — measured (amendment).** Nothing is placed anywhere in RAM for an ELF, with or without `-dtb`. The row this replaces was read from QEMU's source and never run |
| For a **Linux-format `Image`**, QEMU writes a bootloader stub at `0x4000_0000`, loads the image at `mem_base + text_offset`, places the blob, and enters the kernel with `x0` = blob address, `x1`–`x3` = 0 | **Measured (amendment)**, at `-m 4M/8M/16M/32M/64M/128M`. Load address is `0x4008_0000` at every size, i.e. `KERNEL_BASE` is unchanged |
| The blob's address is **not fixed**: `ram_base + min(ram_size/2, 128 MiB)`, rounded up to 2 MiB | **Measured (amendment)** — see §1a's table. This is why no address constant can be right |
| The blob is `totalsize = 0x10_0000` (1 MiB), `version = 17`, `last_comp_version = 16`, of which `size_dt_struct = 0x1b88` (≈ 7 KiB) is content | **Measured (amendment)**, identical at every RAM size from 4 MiB to 16 GiB |
| QEMU virt reports **one** `/memory` node, root `#address-cells` = 2, `#size-cells` = 2, and an **empty** memory-reservation block | **Measured (amendment)** at 8 MiB, 128 MiB, 4 GiB, 8 GiB and 16 GiB. `size` tracks `-m` exactly |
| The gate boots with `-M virt -cpu cortex-a72 -m 128M` | `ci/boot-test.sh`, `ci/lib.sh` |
| `cargo::rustc-link-arg=` applies to test targets as well as binaries | **Measured** for this RFC — see §6 |
| `[lib]` plus `[[bin]] test = false` lets `cargo test` run on the host with a `no_std`, `no_main` binary in the same package | **Measured** for this RFC — see §6 |
| The FDT header, token and reservation-block layout in §2 | Stated from the Devicetree Specification, and **now checked against the real blob (amendment)**: an independent reader built from §2's description parsed QEMU's blob to `FDT_END` with no unknown token, found `off_dt_struct` 4-byte aligned and `off_mem_rsvmap` 8-byte aligned, and read back the memory size `-m` was given. §2's constants are correct |

### 1. Being handed the device tree

**The artefact becomes a Linux-format `Image`, and the blob arrives in `x0`.** There is no
`DTB_BASE`. There cannot be one: the address moves with the machine's RAM size, and a kernel that
hardcoded any of the six values §1a measured would be right on one machine and building a memory map
out of whatever it found on the other five.

`_start` gains the aarch64 boot protocol's 64-byte image header **as its own first 64 bytes**, the
way Linux's `head.S` does — `code0` is a branch over the header, so `_start` remains both the entry
symbol and the header, and `nm` still places it at `KERNEL_BASE`:

```text
  b    9f                 // code0: branch past the header
  .word 0                 // code1
  .quad 0x80000           // text_offset — matches KERNEL_BASE - RAM base
  .quad __image_size      // image_size: non-zero, or the loader ignores text_offset
  .quad 0                 // flags: little-endian, 4 KiB pages
  .quad 0, 0, 0           // res2, res3, res4
  .ascii "ARM\x64"        // magic
  .word 0                 // res5 (PE/COFF offset)
9:
```

`link.ld` gains one line, `__image_size = __kernel_end - KERNEL_BASE`, which is the memory footprint
including `.bss` and the stack — the quantity the protocol asks for, not the file length. It also has
one comment to correct: `KERNEL_BASE`'s says the 512 KiB offset "leaves the low region for the device
tree QEMU builds", which was never true and is now measurably not true. Both are small, and both land
in a file **T-0005 is currently rewriting** — whoever decomposes this must sequence against that
branch rather than let two contributions edit the linker script in parallel.

`_start` already touches only `x9`–`x12` and ends in a tail branch, so `x0` reaches Rust untouched.
`boot_rust` changes signature to `boot_rust(dtb: u64)`. That is the whole architectural change.

**The only new constant is a sanity bound, and it is portable.** It goes in `fdt.rs`, not
`platform.rs`, because it is a statement about how much input this parser is willing to read, not a
fact about a board:

```rust
/// The largest blob this kernel will read. QEMU virt's is exactly 1 MiB at every
/// RAM size measured; this is twice that. A `totalsize` above it is rejected
/// rather than parsed — not because a larger tree is illegitimate, but because
/// the kernel has no way to bound the blob against RAM it has not discovered yet.
pub const MAX_BLOB_LEN: u64 = 0x0020_0000;
```

The old `DTB_MAX_LEN = 0x0008_0000` is deleted. Its derivation — "the space between `DTB_BASE` and
the kernel's link address" — described a placement that does not happen, and its value was half the
size of the blob it was meant to admit.

**Nothing is searched for.** The earlier draft argued against scanning for `0xd00d_feed`, and the
argument stands and is now stronger: §1a measured a scan of all 128 MiB finding nothing at all for
an ELF, which is the *lucky* outcome. The unlucky one is finding the magic in four bytes of
uninitialised RAM and building the milestone's foundation on it.

**Nothing falls back to a constant.** `x0 == 0` means the kernel was booted the old way — as an ELF,
which still works and which §1a confirms still produces `x0 = 0` from the very same binary. That is
a legible failure, not a licence to guess: the kernel reports and stops. The objective's criterion 2
says "from the device tree rather than from constants", and a fallback is the code path that lets a
build pass CI while ignoring the device tree entirely.

Validation, all of it, before a single byte of the structure block is read:

- `dtb != 0` — reported as its own reason, because it means "booted as an ELF", which is a
  configuration mistake in `ci/` and not a corrupt blob, and the two should not look alike
- `dtb` is 8-byte aligned — the protocol requires it, and an unaligned blob would fault on the first
  `u64` of the reservation block under `+strict-align` with the MMU off
- `magic == 0xd00d_feed`
- `totalsize >= 40` and `totalsize <= MAX_BLOB_LEN`
- `version >= 17` and `last_comp_version <= 17` — the parser reads `size_dt_struct`, which is a v17
  field, and a blob it cannot read is rejected rather than guessed at. Measured: QEMU emits
  `version = 17`, `last_comp_version = 16`, so both hold with no margin on the first and one on the
  second
- `off_dt_struct + size_dt_struct <= totalsize`, `off_dt_strings + size_dt_strings <= totalsize`,
  `off_mem_rsvmap <= totalsize`
- `off_dt_struct` is 4-byte aligned; `off_mem_rsvmap` is 8-byte aligned
- `dtb + totalsize` does not wrap

Every one of those additions uses checked arithmetic. This is not style: `overflow-checks = true` is
on in release, so an overflow on a malformed header is a panic, and a panic prints `SKYNET_PANIC`
and says nothing about what was wrong with the blob. Malformed input must produce a typed error, not
the marker that means "the kernel has a bug".

**What the kernel cannot check, and what happens instead.** It cannot verify that
`[dtb, dtb + totalsize)` lies inside RAM, because knowing where RAM is, is what the blob is for. With
the MMU off that is not a silent hazard: §1a measured a read one word past the RAM top raising a
synchronous external abort — `ESR_EL1 = 0x9600_0010`, `FAR_EL1` naming the address — which the
existing vector table reports as `SKYNET_FAULT` and shuts down cleanly, exit 0. A garbage `x0`
therefore produces a legible fault rather than a hang or a fabricated map. It is worth saying plainly
that this is the fault path RFC-0002 built doing exactly the job it was built for.

The boot path then constructs a `&'static [u8]` of exactly `totalsize` bytes. Every later access is a
safe slice index.

### 1a. The measurement

Run on 2026-08-05, QEMU 10.2.2 (`qemu-10.2.2-1.fc44`), rustc 1.97.1, host aarch64, `-M virt -cpu
cortex-a72 -display none -no-reboot -nic none`. The kernel used was this repository's tree at
`6bdc1fac`, copied outside `kernel/` and patched there — no file under `kernel/` was modified.

**1. The premise, refuted.** ELF via `-kernel`, halted, before any instruction executes: `x/10xw
0x40000000` reads all zeros; a dump of all 128 MiB contains no 4-byte-aligned `0xd00d_feed`;
`PC = 0x40080000` and every GPR is zero. Repeated at `-m 64M` and `-m 8M`.

**2. `-dtb` refuted.** `-kernel <elf> -dtb virt-128M.dtb`, same dump, same scan: **zero** aligned
magic hits in 128 MiB. QEMU builds the tree — `-M virt,dumpdtb=file` writes 1,048,576 bytes with
magic `0xd00dfeed` and version 17 — and does not put it in guest memory, because the code that does
so sits inside the `is_linux` branch that an ELF never enters.

**3. `-device loader` refuted, and not for the reason expected.** Placing the blob at `0x4000_0000`
for the ELF is not merely inelegant, it is impossible: QEMU refuses the machine with *"The following
two regions overlap … virt-128M.dtb (0x40000000 – 0x40100000) … ELF program header segment 0
(0x40080000 – 0x400817fc)"*. A 1 MiB blob does not fit in a 512 KiB gap.

**4. The Image route, end to end.** The header above was added to `_start` in the copied tree,
`objcopy -O binary` produced a 6,897-byte flat image, and **that one file** (sha256 prefix
`53d20893d7bf619dc508b0ae70213601`) was booted at seven RAM sizes with a temporary probe printing
`x0` and the first two big-endian words at it:

| `-m` | `x0` | word at `x0` | `totalsize` | console | exit |
| --- | --- | --- | --- | --- | --- |
| 128M | `0x4400_0000` | `0xd00dfeed` | `0x0010_0000` | `SKYNET_BOOT_OK` | 0 |
| 64M | `0x4200_0000` | `0xd00dfeed` | `0x0010_0000` | `SKYNET_BOOT_OK` | 0 |
| 32M | `0x4100_0000` | `0xd00dfeed` | `0x0010_0000` | `SKYNET_BOOT_OK` | 0 |
| 16M | `0x4080_0000` | `0xd00dfeed` | `0x0010_0000` | `SKYNET_BOOT_OK` | 0 |
| 8M | `0x4040_0000` | `0xd00dfeed` | `0x0010_0000` | `SKYNET_BOOT_OK` | 0 |
| 4M | `0x4020_0000` | `0xd00dfeed` | `0x0010_0000` | `SKYNET_BOOT_OK` | 0 |
| 2M | — | — | — | `Not enough space for DTB after kernel/initrd` | **1** |

Six different addresses from one binary, and the sixth — `-m 32M`, `0x4100_0000` — is in no criterion
anywhere: a build that had learned the sizes it would be asked about would have to have learned five.

`x1`, `x2` and `x3` were **zero at all six sizes**, established separately from the console probe by
halting the machine at `break *0x40080000` under gdb and reading the registers at the kernel's first
instruction, before any kernel code had run. `sp` was zero there too, which is why `_start` sets it
before doing anything else and why nothing may be pushed above that line.

The **control** is the same source built as an ELF and booted the way `ci/boot-test.sh` does today:
`x0 = 0`, word at `x0` = 0, `SKYNET_BOOT_OK`, exit 0 — so the difference is the artefact format and
nothing else.

**5. The blob is present before the first instruction.** With a Linux-format image the blob is a ROM
region installed at machine reset, so `-S` plus `pmemsave` finds it with the CPU halted. This matters
for the acceptance criterion T-0006 wrote first: the read can be taken before any kernel code runs,
so no probe can be accused of reporting its own writes.

**6. The blob says what it should.** Copied out of guest RAM on a halted machine and parsed by an
independent reader written from §2's description: one `/memory` node at `0x4000_0000` whose size is
exactly `-m` (`0x800000` at 8M, `0x8000000` at 128M), root `#address-cells` = 2 and `#size-cells` = 2,
an empty reservation block, maximum node depth 6. It differs from `-M virt,dumpdtb` in exactly 41
bytes, all inside `/chosen`'s `rng-seed` and `kaslr-seed`, which QEMU randomises per boot.

**7. `--gdb` survives.** With the machine loaded from the flat image and `gdb` given the ELF for
symbols, `break *0x40080000` hits and reports `_start in section .text`, `$x0 = 0x44000000`, and
`x/1xg $x0` shows the magic. `ci/boot-test.sh --gdb` therefore keeps working by passing the flat
image to `-kernel` and the ELF to `gdb`, which is what its own help text already tells the user to do.

**8. The header costs nothing measurable, today.** `objcopy -O binary` of the clean tree is **4,836
bytes**; with the header and nothing else it is **4,836 bytes**. `.text` grows by exactly 64 bytes,
from `0x638` to `0x678`, and `.vectors` stays at `0x4008_0800` because the linker script aligns it to
2 KiB and there were 392 bytes of slack. That is a fact about today's slack, not a free lunch: once
`.text` crosses 2 KiB the header costs 64 bytes like anything else.

**9. The change is additive.** The header-only build boots **both** ways — as a flat image (`x0` =
blob) and as an ELF (`x0` = 0) — printing `SKYNET_BOOT_OK` and exiting 0 in both. Nothing breaks
while `ci/` has not moved yet, which is what makes the ordering in §8 possible.

### 2. Parsing exactly two things

`kernel/src/fdt.rs`, portable. It reads a blob and produces plain data. It does not allocate, does
not retain a reference to the blob beyond the call, and has no interior state but a cursor.

**The format**, as the parser must treat it. Everything is big-endian regardless of the CPU, which
is why the parser converts explicitly with `from_be_bytes` on copied byte arrays and never casts the
blob to a typed pointer — the target is `+strict-align`, and with the MMU off every access is
Device-nGnRnE, where an unaligned load faults.

- **Header**: ten big-endian `u32`s, in this order — `magic`, `totalsize`, `off_dt_struct`,
  `off_dt_strings`, `off_mem_rsvmap`, `version`, `last_comp_version`, `boot_cpuid_phys`,
  `size_dt_strings`, `size_dt_struct`.
- **Memory reservation block**, at `off_mem_rsvmap`: pairs of big-endian `u64` — address, size —
  terminated by a pair of zeroes.
- **Structure block**, at `off_dt_struct`: 4-byte-aligned tokens. `FDT_BEGIN_NODE` (1) followed by a
  NUL-terminated name padded to 4 bytes; `FDT_PROP` (3) followed by `len`, `nameoff`, and `len` bytes
  padded to 4; `FDT_END_NODE` (2); `FDT_NOP` (4); `FDT_END` (9).
- **Strings block**, at `off_dt_strings`: NUL-terminated property names, indexed by `nameoff`.

Every one of those was exercised against QEMU's real blob by an independent reader written from this
list alone (§1a, measurement 6). It parsed to `FDT_END` with no unrecognised token, found the
reservation block's `(0, 0)` terminator where this section says it is, and recovered the memory size
the machine was given. The header field order, the token values, the 4-byte token alignment, the
NUL-then-pad name encoding and the `len`/`nameoff` order in `FDT_PROP` are therefore **checked**, not
merely quoted. Conformance criterion 13 still asks the implementer to check them against the
specification, because agreeing with one producer is not the same as agreeing with the standard.

**What it extracts, and nothing else:**

1. Every entry of the memory reservation block.
2. Every node whose `device_type` property is `"memory"`, and that node's `reg` property, decoded
   into (address, size) pairs.

`reg`'s cell widths come from the **root node's** `#address-cells` and `#size-cells`, read from the
blob, not assumed. Where they are absent the Devicetree Specification's defaults apply — 2 and 1 —
and a value greater than 2 for either is rejected, because a cell count above two describes an
address this kernel cannot represent and silently truncating it is how a parser hands out memory
that does not exist.

**Properties the parser must have, each of them checkable by a host test:**

- **It never panics on any input.** Every read is bounds-checked against the slice, every arithmetic
  operation is checked, and every failure is a typed error. The test set includes a truncated blob, a
  bad magic, a `totalsize` larger than the window, offsets that overlap, a property whose `len` runs
  past the end, an unterminated node, and a reservation block with no terminator.
- **It is iterative, with a bounded nesting depth.** A recursive descent over attacker-shaped input,
  in a kernel whose stack has no guard page yet, is the storm RFC-0002 measured. Depth beyond 32 is
  a typed error.
- **It terminates.** The cursor advances by at least one token per iteration and the loop is bounded
  by the structure block's length, so a malformed blob cannot produce a hang — which is the failure
  mode CI cannot distinguish from a hardware fault.
- **It is portable.** No architecture construct, no `usize` assumption about physical addresses:
  addresses and sizes are `u64`, because a 32-bit port with a wider physical address space is a real
  machine and `usize` there is a silent truncation.

Output, in `hal.rs` so both sides can name it:

```rust
/// A region of physical memory. u64, not usize: physical addresses are wider
/// than pointers on some architectures this system intends to run on.
#[derive(Clone, Copy)]
pub struct Region { pub base: u64, pub len: u64 }

/// What the device tree said, copied out of the blob so the blob can be released.
pub struct MemoryMap {
    regions: [Region; MAX_REGIONS],       // MAX_REGIONS = 8
    region_count: usize,
    reserved: [Region; MAX_RESERVED],     // MAX_RESERVED = 16
    reserved_count: usize,
}
```

Fixed arrays, and a legible failure if a machine reports more. The allocator is the thing that makes
allocation possible, so nothing before it can allocate; that is the bootstrap, stated rather than
worked around. Eight and sixteen are guesses — O-3.

### 3. What is already spoken for

Four sources, and the union of them is what the allocator must never hand out:

| Source | Where it comes from |
| --- | --- |
| The memory reservation block | the blob. **Measured empty on QEMU virt** — so this path is exercised only by a hand-built blob in §6's tests, and nothing on the gate's machine would notice if it were wrong |
| The kernel image, including its stack | `KERNEL_BASE` and `__kernel_end`, linker symbols |
| The device tree blob itself | **`x0` and the validated `totalsize`** — not a constant. 1 MiB, somewhere in the middle of RAM, at an address that differs on every machine |
| The allocator's own bitmap | computed in §4 |

The blob is no longer below the kernel; it is at `ram_base + min(ram_size/2, 128 MiB)`, which at
`-m 128M` is `0x4400_0000` — 64 MiB into a 128 MiB machine, in the middle of the pool. Two
consequences follow and neither existed in the first revision. The reservation now *splits* the free
memory rather than trimming its bottom, so §4's index space must tolerate a reserved run in the
middle of a region, which it does — reservations are marked in the bitmap, not removed from the
region list. And the 512 KiB below `KERNEL_BASE` is now ordinary free memory: it holds QEMU's
40-byte bootloader stub (`ldr x0, =dtb; mov x1..x3, xzr; ldr x4, =entry; br x4`, measured at
`0x4000_0000`), which is dead the instant it branches. Nothing reserves it, and nothing should —
but a reader who remembers the first revision will expect that region to be spoken for, and it is
not.

**Reservations round outward**: the first frame is `floor(base / FRAME_SIZE)` and the last is
`ceil((base + len) / FRAME_SIZE) - 1`. A frame that is partly reserved is entirely reserved. The
opposite rounding hands out a frame that overlaps the kernel image, and the symptom is memory
corruption with no fault and no report. A zero-length entry reserves nothing and is skipped — that
expression underflows on one, and `(0, 0)` is also the reservation block's terminator.

The kernel does not reserve anything else and does not parse `/reserved-memory`. On QEMU virt
nothing populates it; on real hardware it is how firmware protects memory it is still using, and
handing out such a frame is silent corruption. O-2, with M9.

### 4. The frame allocator

`kernel/src/frames.rs`, portable. A bitmap, one bit per frame, `1` meaning allocated.

**Why a bitmap and not a free list threaded through the free frames.** The free list is the classic
bootstrap answer: zero metadata, O(1) in both directions, and it costs nothing because it stores the
next pointer inside the frame it is describing. It was rejected for two reasons, and the second is
the one that decided it:

- It cannot answer "is this frame free" or "how many are free" without walking the list, and criterion
  3 is a test that exhausts and recovers a pool — an accounting property, checked by counting.
- **It writes to every frame it manages.** Once the MMU is on and everything the kernel was not given
  is unmapped, an allocator that writes into free frames needs those frames mapped, which means either
  a permanent read-write map of all of RAM — a writable alias of everything, including the page tables
  — or a per-frame mapping window, which means mapping has to be mutable at runtime. **A bitmap
  allocator touches only its own bitmap.** It is the choice that leaves the next RFC free.

**Layout.** Regions are sorted ascending and indexed consecutively: frame index `i` belongs to the
first region whose running frame count exceeds `i`. Holes between regions cost no bits. The lookup on
`free` is a linear scan over at most eight regions.

**Storage.** The bitmap is `ceil(total_frames / 8)` bytes, rounded up to a whole frame, placed at the
first frame boundary at or above `__kernel_end`. It must lie inside a discovered region and must not
overlap a reservation; both are checked, and a failure is legible rather than a truncated bitmap.
Then the bitmap's own frames are marked used, before any frame is handed out.

It is not a Rust `static`. It is RAM the kernel claims, reached through one `&'static mut [u8]`
constructed in the boot path where the linker symbols live, at one call site, before anything else
can hold a reference to it. **The kernel still has exactly one `static`** — `IN_FAILURE` — and
conformance criterion 9 says so mechanically.

On nano's 8 MiB ceiling that is 2048 frames and 256 bytes, rounded to one frame. Under the gate's
`-m 128M`, 32768 frames and 4 KiB.

**Interface.**

```rust
/// One frame of physical memory. Not `Copy` and not `Clone`: `free` consumes it,
/// so double-freeing one requires fabricating one, and the field is private.
pub struct Frame { index: usize }

pub struct FrameAllocator { /* private */ }

impl FrameAllocator {
    /// # Safety
    /// `bitmap` must be memory nothing else refers to, lying inside one of
    /// `map`'s regions, overlapping none of its reservations, and long enough
    /// for `map`'s frame count. The constructor then reserves it.
    pub unsafe fn new(map: &MemoryMap, bitmap: &'static mut [u8], frame_size: usize)
        -> Result<Self, Error>;

    /// The lowest free frame, deterministically. `None` when the pool is empty.
    pub fn alloc(&mut self) -> Option<Frame>;

    /// Return a frame to the pool. Consumes it.
    pub fn free(&mut self, frame: Frame);

    pub fn total(&self) -> usize;
    pub fn available(&self) -> usize;
}
```

`&mut self` on both, and no interior mutability: the allocator is an owned value with exactly one
owner, moved into `kernel_main` like the console and the power token. It is not a `static`, there is
no accessor that returns it, and no lock — which is the shape M4 will wrap rather than have to
unwind. M2's second core needs an answer that is not "make it a global with a spinlock"; O-5.

**Determinism.** `alloc` always returns the lowest free frame, scanned from index zero. No cursor, no
hint. A cursor would make the allocation sequence depend on the free history, and a boot that
allocates the same frames in the same order every time is worth more at this milestone than a scan
nobody has measured. Performance is a non-goal.

**Double free.** `free` checks the bit before clearing it. Because `Frame` is not `Copy` and its
field is private, safe code cannot present the same frame twice, so finding the bit already clear
means the allocator or its caller is broken. The response is a panic, which today prints
`SKYNET_PANIC` and nothing else — RFC-0001 O-4 is the reason it cannot say more, and this RFC does
not fix it.

**Frames are not zeroed.** Nothing at M1 hands a frame across a trust boundary, so zeroing would be
work with no reader. It stops being true the moment one does, and the right place for it is the
grant, not the allocation. O-4, recorded now because it is invisible until it is a leak.

### 5. Where it runs, and what happens when it fails

`boot_rust` gains a sequence and **no new device-minting site** — it already mints both, and
`ci/constitution-check.sh --check minting-sites` must report its current count unchanged:

`boot_rust` takes one new parameter — `boot_rust(dtb: u64)` — which is `x0` as the boot protocol left
it. It is a `u64` and not a pointer: nothing may dereference it before §1's validation has run, and a
raw integer is the type that says so.

1. mint the console and the power token, as today;
2. validate `dtb` and the 40-byte header at it, per §1, and form the blob slice;
3. `fdt::parse` → `MemoryMap`;
4. add the kernel image, the blob and (after sizing) the bitmap to the reservations;
5. place the bitmap, construct the `FrameAllocator`;
6. hand `BootResources { console, power, frames }` to `kernel_main`.

Any failure in 2–5 writes a compile-time constant to the console — `SKYNET_MEM_FAIL` and one of a
fixed set of reasons — and powers the machine off. This happens **before** the boot marker, so
`ci/boot-test.sh` fails on the absent marker while the console says why. No new authority is
involved: the console and the power token are the two the boot path already holds, and the reasons
are `&'static [u8]`, so nothing runtime reaches the wire.

**`x0 == 0` gets its own reason.** It is not a corrupt blob; it is the kernel having been booted as an
ELF, which §1a measured still works on the identical binary. That is a `ci/` configuration fault, and
a build that reports it as "bad magic" sends whoever reads the console looking in the wrong file.

**`BootResources` gains a third field, and RFC-0001 warned about exactly this.** Its words were that
`BootResources` must stay a boot-time artefact decomposed at the top of `kernel_main`, and must never
become "a registry, a lookup table, or a long-lived value later code reaches into" — that a method
returning a device by name or index "is the moment this went wrong". A third owned value, moved once,
with no accessor and no name-based lookup, is a parameter list and not a registry. It is worth saying
plainly that it is the third field of the twenty that argument names as the point of failure, and
that from here the count is worth watching rather than assuming.

`kernel_main` is unchanged in behaviour: it writes the boot marker and powers off. It prints nothing
about the memory it found, because printing a number needs a formatter in portable code and that is
RFC-0001 O-4's design rather than a `write!` added here.

### 6. Testing, which is the part that is actually hard

The objective's criterion 3 says *proven by a test*. There is nowhere to run one.
`ci/build.sh --test` runs `cargo test --manifest-path kernel/Cargo.toml` for the **host**, guarded
by a grep for `#[cfg(test)]` or `[[test]]` across `kernel/src` and `kernel/tests`. RFC-0001 O-5
records that the guard is the only reason it reports SKIP, and that "the moment anyone adds the
first `#[cfg(test)]` the check stops
being SKIP and becomes FAIL". This RFC is that moment, and O-5 says the shape must be settled before
the first test is written rather than after.

Two things were measured on this machine, with the toolchain the repository uses (rustc 1.97.1,
edition 2024), rather than reasoned about:

**A `[lib]` target alongside a `no_main` binary lets `cargo test` work.** With

```toml
[lib]
name = "skynet_kernel"
path = "src/lib.rs"

[[bin]]
name = "skynet-kernel"      # unchanged: ci/lib.sh:kernel_binary() depends on it
path = "src/main.rs"
test  = false               # a no_std/no_main binary cannot host the test harness
bench = false
```

`cargo test` compiles and runs the library's unit tests on the host, and `target/debug/` contains no
binary afterwards. The run also passes with `panic = "abort"` present in `[profile.dev]`, which the
kernel's manifest sets. Both were run rather than reasoned about; neither says anything about why
cargo behaves this way, only that it does, on this toolchain.

**`build.rs` must switch to `rustc-link-arg-bins`, and this is not cosmetic.** With the current
`cargo::rustc-link-arg=-T…/link.ld`, the flag is passed to the host test link as well, and
`cargo test` fails with:

```
/usr/bin/ld.bfd: cannot open linker script file does-not-exist.ld
error: could not compile `probe-kernel` (lib test)
```

`probe-kernel` is the throwaway package this was reproduced in, and the script was deliberately named
as missing so that the failure names itself; with the real script it fails in a way that reads like a
kernel problem. `cargo::rustc-link-arg-bins=` applies to binary targets only, and with it the same
test run passes. All three link args — the script, `--nmagic`, `--gc-sections` — move.

**The split.** Only portable, testable logic moves; everything that must be linked into the image
unconditionally stays in the binary, because a `rlib` member that nothing references is not pulled
into the link and `KEEP` cannot save a section from an object file that was never there.

| Target | Contents |
| --- | --- |
| `src/lib.rs` (`skynet_kernel`) | `#![cfg_attr(not(test), no_std)]`; `pub mod hal; pub mod fdt; pub mod frames;` |
| `src/main.rs` (`skynet-kernel`) | `#![no_std] #![no_main]`; `mod arch; mod panic;`; `kernel_main`, `BOOT_MARKER`, and the HAL conformance block |

The conformance `const` block moves from `hal.rs` to `main.rs`, because that is the only place after
the split where the traits and their implementations are both visible. It stays on the portable side,
which is what RFC-0001 asked of it. `BOOT_MARKER` stays in `main.rs`, so RFC-0001's C11 — the marker
lives in portable code, and `grep` finds it there — is unaffected. Neither file gains an architecture
construct, and `Cargo.lock` still resolves one package, which is what invariant 7 is checked against.

**The tests.** In `#[cfg(test)]` modules, which ship nothing: they are not in the release binary and
cost zero image bytes.

- The malformed-blob set from §2, each producing its typed error and no panic.
- A hand-built minimal blob with one `/memory` node, producing the expected region — and the same
  region encoded with `#address-cells`/`#size-cells` of 1/1 and again of 2/2, both producing it. That
  is what proves the cell widths are read from the root node rather than assumed.
- **Exhaust and recover**, which is the objective's criterion 3 verbatim: allocate until `None`;
  assert the count
  equals `total`; assert `available` is zero; free everything; assert `available` equals `total`
  again; allocate the whole pool a second time and assert the sequence is identical.
- Reservation rounding: a reservation of one byte inside a frame makes that whole frame unavailable,
  and the frame after it available.
- A region set with a hole, proving the index space skips it.

What no host test covers is the boot glue: the image header, the one unsafe slice construction, the
linker symbols, and the real blob at whatever address `x0` gave. Nothing at M1 can test that except a
boot, which is what conformance criteria 4, 5, 5a and 5b are for. O-8.

### 7. What this hands the MMU

Recorded here because the next RFC will be written against it, and because two of these were
discovered by designing the MMU first and finding the constraint pointing backwards:

- **The allocator never touches the frames it manages.** Only its bitmap and its own metadata need to
  be mapped. No mapping window, no read-write alias of all of RAM.
- **The bitmap sits immediately above `__kernel_end`**, is frame-aligned, and its length is known
  only at run time. Whatever maps the kernel must map `[KERNEL_BASE, bitmap_end)`, not
  `[KERNEL_BASE, __kernel_end)`.
- **Physical addresses are `u64` and come from the device tree.** A translation regime that pins its
  output address size to 32 bits is correct for QEMU virt at `-m 128M` and wrong for a machine whose
  memory node starts above 4 GiB. The map's own configuration has to be derived from what was
  discovered, not from a constant chosen before discovery existed.
- **The frame size is `FRAME_SIZE` from `arch`, and it must equal the translation granule.** Two
  constants that must agree, in two RFCs, is exactly how they come to disagree; a compile-time
  assertion that they are equal belongs in the RFC that introduces the second one.
- **The device tree's frames stay reserved, and that now has a price worth naming.** The blob is
  **1 MiB**, not the 512 KiB the first revision assumed, and `profiles/nano.toml` declares
  `ram_max_bytes = 8388608` with `[budget.boot_memory] max_bytes = 1048576`. So on nano the blob is
  12.5% of the machine's RAM and **exactly 100% of the boot-memory budget**, before the kernel image,
  before the bitmap, before anything else. Only about 7 KiB of that 1 MiB is content
  (`size_dt_struct = 0x1b88`); QEMU allocates a megabyte-sized buffer and does not pack it.

  The first revision deferred reclaiming on the grounds that it "has no way to prove nothing does"
  hold a reference. §2 does prove it, as far as this design goes: the parser retains no reference
  beyond the call and `MemoryMap` is copied out by value. The remaining holder is the boot path
  itself, which ends. Reclaiming is still not done *here* — this RFC covers no allocator behaviour
  after construction, and freeing 256 frames is the allocator's operation — but it moves from "a
  decision nobody needs to make" to O-10, with a budget number attached.

### 8. What this obliges `ci/` to change, and who owns it

**This is the part of the amendment that cannot be discharged by the person implementing it.** Every
route out of the measurement in §1a touches the boot contract. `governance/roles.toml` grants `ci/`
to exactly one role — the **orchestrator** (`may_write = ["ci/", "governance/", …]`). The architect,
the decomposer and the implementer are each denied it by name, and the implementer's task file
repeats the denial. So this list is written here because there is nowhere else it can be written, and
if it is not carried out the kernel half cannot land: a kernel that requires `x0` and a gate that
boots an ELF produce a machine that reports `SKYNET_MEM_FAIL` and no boot marker, correctly, forever.

| # | Change | File |
| --- | --- | --- |
| 1 | Produce the flat image **during the build**, and give it an accessor beside `kernel_binary()`. This is smaller than it sounds: `do_size` already runs `objcopy -O binary "$bin" "$REPO_ROOT/ci/.out/kernel-$PROFILE.bin"`, so the exact artefact exists at a known path — it is simply produced by the wrong step. `--size` does not rebuild and neither does `boot-test`, so a boot test that read that path today would boot whatever the last `--size` left there. Move the objcopy into `do_build`; leave `kernel_binary()` returning the ELF, which gdb and `nm` still need | `ci/build.sh`, `ci/lib.sh` |
| 2 | Pass the flat image to `-kernel` in `run_boot`; keep passing the **ELF** to `gdb` in `run_gdb`. Measured working: symbols resolve, `break *0x40080000` hits, `$x0` reads the blob address | `ci/boot-test.sh` |
| 3 | Correct `--contract`. It must state that the artefact is a Linux-format `Image`; that `x0` holds the physical address of a device tree blob at entry and `x1`–`x3` are zero; and that **the address is not fixed** — it is `ram_base + min(ram_size/2, 128 MiB)`, so no kernel may hardcode it. The four `detail` lines that currently say `ALL general-purpose registers ZERO` and `x0 is NOT a device tree pointer … RFC-0001 O-2` become false the moment change 2 lands, and a contract that is false is worse than one that is silent | `ci/boot-test.sh` |
| 4 | Close **RFC-0001 O-2**. It asked whether to change the artefact, read the blob from an observed placement, or correct the contract. This RFC answers: change the artefact. The record should say so where O-2 is cited | `ci/boot-test.sh` comments |

**Ordering, which is the whole reason this is a list and not a sentence.** §1a measurement 9 showed
the header-only build boots both ways. That buys a safe sequence, and it is the only one that never
leaves the gate red:

1. kernel: header, `__image_size`, `boot_rust(dtb: u64)`, and **no parser**. Boots as an ELF (`x0 = 0`,
   ignored) exactly as today. Gate green.
2. `ci/`: changes 1–4. Now `-kernel` gets the flat image, `x0` is a blob, the kernel still ignores it.
   Gate green.
3. kernel: the parser, the validation and the failure path. `x0` is now load-bearing. Gate green.

Reversing 1 and 2 breaks the build; merging 2 and 3 in either order without 1 breaks the boot test.
Doing all three at once is possible and puts a `ci/` change and a `kernel/` change in one
contribution, which the role separation is designed to prevent.

**What is not asked for.** No new CI flag, no RAM-size option, nothing about
`[budget.boot_memory]` — that is still O-6 and still unmeasured. `--lint`, `--test` and
`ci/constitution-check.sh` are untouched by any of this.

## Non-goals

Objective 0002's `non_goals` apply unchanged. In addition, so that a patch containing any of these is
scope creep and not a matter of opinion:

- **The MMU, page tables, mapping of any kind.** The next RFC. This design runs with translation off
  and hands out physical addresses.
- **A kernel heap.** The objective's criterion 5, after the MMU.
- **A general device tree interface.** No lookup by path, no phandles, no interrupt or clock
  properties, no `/chosen`, no `/reserved-memory`, no initrd, no driver binding, no FDT below
  version 17, and nothing that writes a blob. Two things are read: memory nodes and the reservation
  block.
- **Anything but single frames of `FRAME_SIZE`.** No contiguous multi-frame allocation, no alignment
  requests, no DMA or address-range zones, no large pages, no slab, no buddy.
- **Zeroing frames on allocation.** O-4.
- **Reclaiming the device tree's memory.** §7.
- **Locking, atomics, or any concurrency mechanism.** One core at M1. The allocator is an owned value
  and must not become a `static` with a lock — that would undo the property it exists to demonstrate.
- **Memory hot-plug, offlining, ballooning, or any policy about exhaustion.** `alloc` returns `None`;
  what a caller does about it is not decided here and is excluded by the objective.
- **Reporting the memory map on the console.** Needs a portable formatter; RFC-0001 O-4.
- **Writing the `ci/` changes.** §8 lists what must change and names the role that owns it. The
  architect cannot write them and neither can the implementer; naming them is the most either can do.
  This is a non-goal in the sense that no patch under `kernel/` may work around them.
- **A second boot format, or any runtime choice between them.** The kernel does not detect how it was
  loaded and adapt. `x0 == 0` is a reported failure, not a mode.
- **EFI, PE/COFF, `res5`, or any boot-time firmware protocol.** `res5` is zero. The image header is
  four fields the loader reads and six zeros.

## Constitutional impact

**Invariant 4, frugality *(enforced from M0)*.** Image: an FDT parser and a bitmap allocator, both
small and both measured rather than estimated here — conformance criterion 2 requires the
before-and-after size against nano's 192 KiB. The `#[cfg(test)]` code is not in the release binary
and costs nothing. The boot header costs **0 bytes measured** today and 64 bytes once `.text` crosses
2 KiB (§1a, measurement 8) — stated that way rather than as "free", because it is free only by
accident of the current slack.

Boot memory, and this is where the amendment costs something real. Three things now claim it:

| Claim | Size | On nano's 8 MiB |
| --- | --- | --- |
| Kernel image and stack | `__kernel_end - KERNEL_BASE`, currently 0x11b00 ≈ 71 KiB | 0.9% |
| The bitmap | `ceil(frames / 8)` rounded to a frame — 4 KiB at `-m 128M`, one frame on nano | 0.05% |
| **The device tree blob** | **1 MiB, measured, at every RAM size** | **12.5%** |

`profiles/nano.toml` sets `[budget.boot_memory] max_bytes = 1048576` and measures "physical memory
owned by the kernel once boot completes". A blob the kernel reserves and never releases is owned by
the kernel by that definition, and it is that budget exactly, to the byte, with nothing left for the
image or the bitmap. **The nano profile as written cannot hold this design unless the blob's frames
are released after the map is copied out.** That is O-10, and it is a finding against the design
rather than against the profile: the profile's number was set before anyone had measured a blob.

Every profile declares `[budget.boot_memory]` with `enforced_from = "M1"`, and **nothing in `ci/`
measures it**: `ci/build.sh --size` measures the image and gate condition 5 calls that. This design is
the first to make the number depend on the machine rather than on the link, and now the first to have
a number that plausibly exceeds a declared budget. O-6, which was a tidiness complaint in the first
revision and is not one any more.

There is a second, smaller cost. Booting as a Linux-format image imposes a **minimum RAM of 4 MiB**:
at `-m 2M` QEMU refuses the machine outright with "Not enough space for DTB after kernel/initrd" and
exits 1 (§1a, measurement 4). nano declares 8 MiB as a ceiling and not a floor, so nothing in
`profiles/` is violated — but the ELF path had no floor at all, and a floor introduced by a boot
format is the kind of thing discovered later by someone porting to a smaller board.

**Invariant 6, HAL boundary *(enforced from M0)*.** The parser and the allocator are portable, and
deliberately so: the flattened device tree is a data format, not an architecture. What stays in
`arch/` is what is genuinely architectural or board-specific — `FRAME_SIZE`, the image header, the
linker symbols, `boot_rust`'s `x0` parameter, and the one unsafe slice construction. `MAX_BLOB_LEN`
is portable, in `fdt.rs`, because it bounds the parser's appetite rather than describing a board.

The amendment **improves** this boundary rather than straining it: `platform.rs` gains no constant at
all now, where the first revision added two. The kernel's only new address is one it was handed.
No portable file names an architecture, uses a `cfg`, or assumes a word size: physical addresses are
`u64` precisely so that a 32-bit port with a wider physical address space is not a silent truncation
waiting to be found.

**Invariant 7, no kernel dependencies *(enforced from M0)*.** `fdt`, `device-tree`, `dtb-parser`,
`vfdt` and half a dozen others exist and do this job well. Writing it is the invariant, and the
parser is a few hundred lines. `Cargo.lock` still resolves exactly one package after the library
target is added, which is what the check reads.

**Invariant 1, no ambient authority *(pending, M4)*.** The frame allocator is the second real
authority in this kernel — the console can say things, and this can give memory away.

*What the design does.* It is an owned value with a private field, constructed once in the boot path,
moved into `kernel_main`. No `static`, no accessor, no lock, no global. A `Frame` is unforgeable in
safe code for the same reason a `BootConsole` is: the field is private. `Frame` is additionally not
`Copy` and is consumed by `free`, so the shape is `Power::off(self)` applied to memory. Nothing here
mints a device, and the minting-site count is unchanged.

*What it does not do.* This is not a capability. It has no attenuation, no revocation, no expiry, no
accounting to a holder, and the holder of the allocator can allocate everything. What M4 will need is
a right to a bounded quantity, held by someone, revocable — and the reason this shape helps is that
there is exactly one owner to interpose on, rather than a global that every line of the kernel can
already reach.

*What it costs.* `BootResources` grows from two fields to three. RFC-0001's argument survives only
while it stays a parameter list decomposed at the top of `kernel_main`, and this is the growth that
argument anticipated. It is worth watching, and §5 says so rather than leaving it to be noticed at
five.

**Invariant 2, user sovereignty *(pending, M5)*.** *See:* a machine whose device tree cannot be found
now says so on the console instead of booting as though it knew. *Revoke:* no cached authority is
created; one owner, moved once. *Refuse:* nothing attested.

**Invariant 5, zero telemetry *(pending, M6)*.** No new outward path. Every byte the failure path can
emit is a compile-time constant, so no discovered value — no memory size, no address — reaches the
console at all.

**Invariant 3, total provenance *(enforced now)*.** The first revision recorded honestly that its
central premise was unverified, and named the reason: no QEMU on the machine. That record is the only
reason the task's first acceptance criterion existed, and the criterion is what stopped the work
before a parser was written for a blob that was not there. The amendment's obligation is to leave the
next reader no worse equipped:

- every corrected claim is kept, struck through, with the measurement beside it (§0, and the table at
  the top of this document) rather than quietly replaced;
- §1a gives the machine, the QEMU build, the date, the artefact hash and the command shape for each
  of nine measurements, so a reviewer re-runs rather than re-derives;
- the one binary booted at seven RAM sizes is identified by hash, because two builds at two sizes are
  not a measurement of a machine — a lesson this repository paid for twice on the fault path;
- what is still *not* verified is said plainly: §2's constants agree with one producer's blob, not
  with the specification (criterion 13 remains); `MAX_REGIONS` and `MAX_RESERVED` are still guesses
  with one data point (O-3); and the reservation-block path is unexercised by any real blob, because
  QEMU virt's block is empty (§3).

**Invariant 10, English repository.** All identifiers, comments and prose in English.

## Conformance criteria

**Mechanical.**

1. `ci/build.sh`, `--lint` and `ci/boot-test.sh` pass. Boot output is unchanged: `SKYNET_BOOT_OK`,
   no `SKYNET_PANIC`, exit 0.
2. `ci/build.sh --size` and `SKYNET_PROFILE=nano ci/build.sh --size` pass, and the contribution
   reports the image size before and after rather than asserting it is small.
3. **`ci/build.sh --test` reports PASS, not SKIP and not FAIL.** This is the first contribution for
   which that check does anything, and RFC-0001 O-5 predicted it would fail. If it fails at link with
   the linker script named in the error, `build.rs` still uses `rustc-link-arg` where §6 requires
   `rustc-link-arg-bins`.
4. **PROOF:** boot **one** flat image — stated by hash — under `-m 128M`, `-m 64M` and `-m 8M`, with
   temporary instrumentation printing the frame count, and show three counts that differ and match
   the machine. A build that hardcodes a size passes every other criterion here; this is the one that
   fails it. `-m 64M` is named because it is in no other criterion: a build that learned the two sizes
   it would be asked about passes a two-size proof. Remove the instrumentation before submitting, as
   RFC-0002's proofs do.
5. **PROOF:** boot with the four magic bytes **at the address in `x0`** corrupted, and show
   `SKYNET_MEM_FAIL` with a reason, no boot marker, and a clean exit — not a timeout, not a panic
   marker. State how the write was established to land before the kernel's read; §1a measurement 5
   shows the blob is present on a halted machine, which is the window to use.
5a. **PROOF:** boot the same binary as an **ELF**, and show `SKYNET_MEM_FAIL` with the `x0 == 0`
   reason — distinct from the bad-magic reason — no boot marker, clean exit. This is the failure a
   misconfigured `ci/` produces, and it must name itself.
5b. **PROOF:** `readelf -h` and a hex dump of the first 64 bytes of `objcopy -O binary` output show
   `code0` a branch, `text_offset = 0x80000`, `image_size` equal to `__kernel_end - KERNEL_BASE`, and
   `0x644d5241` at offset 56. State the flat image's size and `nm`'s address for `_start`.
6. `grep -c '^\[\[package\]\]' kernel/Cargo.lock` is 1, and `kernel/Cargo.toml` still declares no
   dependency section of any kind.
7. `ci/constitution-check.sh --check hal-boundary`, `--check no-kernel-deps`, `--check
   vector-alignment` and `--check minting-sites` all pass, the last still reporting **4** call sites
   — two in `boot.rs`, two in `fail.rs`, which is the count on the current tree.
8. `grep -rnE 'asm!|naked_asm!|global_asm!|core::arch::|#\[unsafe\(naked\)\]|target_arch' kernel/src
   | grep -v '^kernel/src/arch/'` is empty — in particular `fdt.rs`, `frames.rs`, `hal.rs` and
   `lib.rs` contain none of them.
9. `grep -rn 'static' kernel/src` finds exactly one `static` item, `IN_FAILURE`, and no `static mut`.
   The bitmap is not a static.
10. `nm` on the built ELF still places `_start` at `0x4008_0000` — the image header is the first 64
    bytes *of* `_start`, not a prefix bolted onto the artefact, so RFC-0001's C16 is unaffected — and
    `ci/lib.sh:kernel_binary()` still finds the ELF.
10a. `readelf -S` shows `.vectors` present, non-zero, and 2 KiB aligned, checked with the tool rather
    than with `ci/constitution-check.sh --check vector-alignment`, which reports skip and exits 0 when
    the section is absent. The header sits in `.text.boot`, ahead of the table, and §1a measurement 8
    showed it moving `.text`'s end from `0x638` to `0x678` without moving `.vectors`; a contribution
    whose `.text` has grown past `0x800` will move it, legally, and must say so.
10b. The kernel names no address constant that was not in `platform.rs` before this change.
    `grep -rn 'DTB_BASE\|DTB_MAX_LEN' kernel/` is empty: both were deleted, and `MAX_BLOB_LEN` is in
    portable `fdt.rs`.

**PROOF — run these, do not assert them.**

11. The exhaust-and-recover test of §6 runs under `cargo test` and passes, including the
    identical-sequence assertion.
12. Every malformed blob in the §2 test set produces its typed error, and `cargo test` shows zero
    panics across the set.

**REVIEW.**

13. Every field of the FDT header, every token value, and the reservation block layout are checked
    against the Devicetree Specification, and the check is stated in the contribution. A wrong
    constant here is a defect in this RFC, not in the patch.
14. No arithmetic on a value read from the blob is unchecked. `overflow-checks = true` means an
    unchecked add on malformed input is a panic, and a panic is the marker that means "kernel bug".
15. The parser is iterative and depth-bounded; no function in `fdt.rs` calls itself.
16. Every `unsafe` block carries a `// SAFETY:` naming the invariant that makes it sound — in
    particular the blob slice (validated `totalsize`, bounded window, one construction site) and the
    bitmap slice (inside a discovered region, reserved before use, one owner).
17. `Frame` is neither `Copy` nor `Clone`, its field is private, and `free` takes it by value.
18. No portable file names an architecture, and no physical address is stored in a `usize`.

## Alternatives considered

### For how the kernel obtains a device tree (amendment)

Three routes were on the table when the premise failed. Each was run, not argued.

**`-dtb <file>` with the ELF unchanged.** The cheapest by a wide margin: one flag in `ci/`, no change
to the artefact, no image header, no `KERNEL_BASE` question, and RFC-0003 O-1 named it first.
**Rejected because it does not work.** `-kernel <elf> -dtb <blob>` places nothing: a scan of all
128 MiB of guest RAM finds no aligned `0xd00d_feed` (§1a, measurement 2). QEMU builds the tree and
discards it, because the code that writes it into memory is inside the `is_linux` branch and an ELF
never enters it. This is worth stating flatly, because "just pass `-dtb`" is what the ledger entry
that released T-0006 suggested and what any reader would try first. It is not a trade-off. It is a
no-op.

**`-device loader,file=<dtb>,addr=0x40000000` with the ELF unchanged.** The natural repair once
`-dtb` is found not to work: QEMU's generic loader writes an arbitrary file to an arbitrary guest
address, which would put a blob exactly where the first revision believed one already was.
**Rejected because QEMU refuses the machine**: the blob is 1 MiB and the gap below `KERNEL_BASE` is
512 KiB, so the regions overlap and QEMU exits with an error naming both (§1a, measurement 3). Even
had it fit, the objection stands that the address would be a constant agreed between a CI script and
a kernel with nothing checking they still agree — and objective 0002's criterion 2 asks for a memory
map "from the device tree rather than from constants", which a blob placed at an address the kernel
was told to expect satisfies only in letter.

**Discovering memory with no device tree at all, deferring the parser to M2.** The most interesting
of the three, because it is the only one that touches no other role's files. The mechanism would be a
probe: read or write-and-read-back at increasing addresses until the access stops working, and call
the last address that worked the top of RAM. §1a measurement of the fault behaviour says the
mechanism exists — a read one word past the RAM top raises a synchronous external abort with
`ESR_EL1 = 0x9600_0010` and `FAR_EL1` naming the address, reported cleanly by the vector table, at
both `-m 8M` and `-m 128M`. **Rejected on four counts, in increasing order of severity:**

1. It needs a fault the kernel can *return from*. Today's handler is fail-stop by design: it reports
   and powers off. A recoverable-fault path with a fixup table is a design of its own, in the same
   file RFC-0002 built and T-0005 is still repairing.
2. It needs the RAM base and a stride as constants. That is the objective's criterion 2 failing on a
   technicality — a constant by another name, exactly as the brief for this amendment put it.
3. It finds a top and nothing else. Not the reservation block, not a second region, not a hole. A
   probe that walks upward across a gap reports the far side as absent, or reports the near side as
   present past its end, depending on which way it errs.
4. The write-and-read-back variant is destructive. At M1 the only things it can destroy are the kernel
   and — under the Image route — the device tree. It is the one option here that can corrupt the
   evidence of its own failure.

**Chosen: boot as a Linux-format `Image`.** RFC-0001 considered it as "a raw binary as the boot
artefact instead of an ELF", rejected it because it requires changing `ci/`, and said in terms that it
"is the likely resolution of O-2 and should be considered on its merits at M1, not worked around
now". This is M1 and these are its merits: `x0` carries the blob at every RAM size from 4 MiB to
128 MiB; the kernel adds no address constant; `KERNEL_BASE` and `_start`'s address are unchanged;
`--gdb` still resolves symbols; the artefact costs 0 measured bytes today; and the same binary still
boots as an ELF, so nothing is broken while `ci/` catches up. Its costs are 1 MiB of guest RAM, a
4 MiB floor on machine size, and four changes in a file this role may not write — all in §8.

### For the allocator and the parser

**A free list threaded through the free frames.** The most tempting alternative, and the classic one:
no metadata at all, O(1) both ways, and it needs no bitmap and no placement problem. Rejected in §4
because it writes to every frame it manages, which forces the next RFC to choose between a
read-write map of all of RAM and a runtime-mutable mapping window — and because the objective's
criterion 3 is an accounting property, which a list cannot answer without walking itself.

**A statically sized bitmap in `.bss`.** No placement problem, no unsafe slice, no runtime length. It
would have to be sized for the largest RAM the kernel might meet, which is unbounded, or for the
smallest, which makes the kernel refuse memory it was given. The kernel does not know its profile at
build time and nothing gives it one.

**Requiring exactly one memory region, failing on two.** Smaller by the whole index-mapping section,
and correct for QEMU virt today. The first revision rejected it on the grounds that "QEMU itself
produces a second memory node once RAM crosses into high memory". **That reason is wrong and is
withdrawn:** `-M virt` reports a single `/memory` node at `0x4000_0000` at `-m 4G`, `8G` and `16G`,
with `size` equal to `-m` in each case (§1a). Larger sizes could not be checked — `dumpdtb` allocates
the guest's RAM, and this host refused at 255 GiB.

It is rejected anyway, on the reason that was always the better one: the multi-region case is not
QEMU's, it is real hardware's, and M9 is where this kernel meets a board whose RAM is not one
contiguous run. Writing an index space that tolerates a hole costs about thirty lines now and is a
rewrite of the allocator later. Recorded with the correction attached, because a rejection that
survives its own stated reason being false deserves to say so out loud rather than be quietly
re-justified.

**Searching RAM for the FDT magic.** Robust against the loader placing the blob anywhere, which is
the exact fragility O-1 was about — and §1a proved the placement really does move, six different
addresses from one binary. Rejected because a search that finds `0xd00d_feed` in uninitialised RAM
produces a memory map from noise, and every later guarantee in this milestone rests on that map being
true. The amendment strengthens the rejection rather than weakening it: `x0` gives one address,
supplied by the loader that placed the blob, checked hard, with no window to scan. A search is what
you do when nobody tells you; the point of the Image route is that somebody does.

**Falling back to a constant memory size when no device tree is found.** It would make the kernel
boot on any machine, and it is what the objective's criterion 2 forbids in so many words. Recorded
because it is the change someone will propose the first time the DTB probe fails on new hardware,
and the answer needs
to be already written down: the fallback is what makes the device tree optional, and an optional
device tree is a constant with extra steps.

**A boot-time self-test instead of host unit tests.** Exhaust and recover at boot, panic on failure,
and the gate catches it with no crate restructuring at all. Genuinely attractive — it tests the real
allocator on the real machine with real memory, which host tests cannot. Rejected because it ships
test code in the privileged image forever, costs nano budget on every device, and tests one memory
size per boot. The host tests plus conformance criteria 4 and 5 cover more for less, and the
restructuring is owed to RFC-0001 O-5 regardless.

**Parsing `/reserved-memory` as well.** Two dozen more lines and closer to correct on real hardware.
Rejected for now because nothing on the only platform this project can run exercises it, and
unexercised parsing of external input in the privileged image is what this design refuses everywhere
else. O-2.

## Open questions

**O-1 (answered, and it was the bad answer).** The first revision recorded that the blob's placement
at `0x4000_0000` was read from QEMU's source and never run, and that "the first person to run the
implementation is also the first to test the premise". That happened: T-0006 was claimed, its first
acceptance criterion was run before any code was written, and the premise was false in both halves —
no blob is placed for an ELF, and the placement named was impossible anyway for a blob twice the size
of the gap. The task was released rather than patched around, which is what its `OPEN` criterion
instructed and the reason that criterion was written first.

Of the three fixes O-1 listed, one works and two do not. `-dtb <file>` places nothing; adding the
placement to the contract would document an address that does not exist. Changing the artefact to a
Linux-format `Image` works, and §1 is now built on it. What remains open is not the kernel's half but
`ci/`'s: **§8 is the live part of this question**, and until it is carried out the design describes a
kernel that cannot boot. It is recorded there rather than here because an obligation on another role
belongs in the design, where a reviewer reads it, and not in a list of things the architect could not
settle.

The durable lesson is smaller than the finding and worth keeping: this document asserted a hardware
placement from source it had read and could not run, marked it clearly as unverified, and the marking
was enough — the decomposer turned it into a criterion and the criterion stopped the work. The
failure mode this project should still fear is the unverified sentence that is *not* marked.

**O-2.** `/reserved-memory` is not parsed. On QEMU virt nothing populates it. On real hardware it is
how firmware says "this memory is mine", and a kernel that hands such a frame out corrupts something
with no fault and no report. It belongs with real hardware at M9, or with the first board that
declares one, whichever comes first.

**O-3.** `MAX_REGIONS = 8` and `MAX_RESERVED = 16` are guesses, now with exactly one data point
against them: QEMU virt reports **one** memory region and **zero** reservations, at every size from
8 MiB to 16 GiB. That confirms the guesses are generous and confirms nothing about a real board, and
the allocator cannot allocate its own arrays because it is the allocator. The failure is legible
rather than silent, which is the most this can offer; the numbers should be revisited by whoever first
meets hardware. A consequence worth naming separately: because virt's reservation block is empty, the
whole reservation-block code path is exercised only by §6's hand-built blobs. Nothing the gate boots
would notice if it were wrong.

**O-4.** Frames are not zeroed. Nothing at M1 hands one across a trust boundary, so today this leaks
nothing. At M3 a frame reaching EL0 with a previous holder's contents is a disclosure, and at M4 it
is a capability system leaking through the memory it hands out. The right place is the grant rather
than the allocation — zeroing on `alloc` costs a write of every frame at boot and still does not cover
a frame reused inside the kernel. Named here so that it is a decision at M3 and not a finding at M5.

**O-5.** The allocator has one owner and no lock, which is correct for one core and is the property
invariant 1 wants. M2 brings a second core. The obvious answer — a `static` allocator behind a
spinlock — would undo exactly what §4 establishes, and the alternatives (per-core pools, an owner
that hands out sub-pools, message-passing to a single owner) are a design rather than a patch. It
should be settled with M2's concurrency model and not by whoever first needs a frame on the second
core.

**O-6.** Every profile declares `[budget.boot_memory]` with `enforced_from = "M1"`, and nothing
measures it. `ci/build.sh --size` measures the image; gate condition 5 calls exactly that. From this
contribution onward the kernel's boot memory depends on the machine it booted on, so the number
cannot be read off the link any more. The architect may not write `ci/`; an invariant enforced from a
milestone that has arrived should not have to be measured by hand.

**O-7.** The library split makes the portable half of the kernel host-testable and leaves a question
it does not answer: `cargo test` builds for the host, so anything in `arch/` remains untestable
except by booting. That is right for assembly and register writes and wrong for the growing amount of
ordinary logic that will live under `arch/` — the descriptor arithmetic the next RFC needs is the
first example. Whether that logic should move to a portable module with the architecture as a
parameter, or whether `arch/` should gain host-testable units of its own, is a decision for the first
RFC that has a real case. This one does not.

**O-8.** Nothing tests the boot glue: the header validation against a real blob, the slice
construction, the linker symbols, the bitmap placement. Host tests cover the parser and the allocator;
conformance criteria 4 and 5 cover the machine with temporary instrumentation that is then removed.
Between them sits code that is exercised on every boot and asserted by nothing, and the honest
description of the
gap is that a boot marker proves the path did not fault, not that it computed the right map.

**O-9 (opened by the amendment; the live half of O-1).** §8's four `ci/` changes are owned by the
orchestrator and cannot be made by any role that can write `kernel/` or `rfcs/`. Two of them are
mechanical and one is not: correcting `--contract` means deciding what the project *promises* about
the boot artefact, which is a contract question and not a script edit. Specifically — is
"the artefact is a Linux-format `Image` and `x0` holds a device tree pointer" a promise CI makes to
the kernel, revisable when the machine changes, or a property the kernel may assume forever? RFC-0001
answered the analogous question the wrong way round once already, by writing `x0 = device tree blob
pointer` into the contract when the artefact made it false. The correction should not create the
mirror-image error by writing the artefact format into the kernel and leaving the contract silent
about it.

**O-10 (opened by the amendment).** The device tree blob is 1 MiB and `profiles/nano.toml` budgets
1 MiB of boot memory. Reserved and never released, the blob is that budget entirely — so either the
blob's 256 frames are freed after §2 copies the map out, or the nano profile is amended by vote, or
the invariant is violated on the smallest machine the project claims to serve. This RFC does not
choose, because freeing frames is allocator behaviour after construction and nothing here specifies
that. What it can supply is the argument the chooser needs: §2's parser retains no reference to the
blob, `MemoryMap` is copied out by value, and the only remaining holder is a boot path that ends —
so the safety case for releasing them is already made, and what is missing is a design decision about
whether boot-time memory is released at all. It should be settled with the MMU RFC, which is the
first thing that will want the blob's address space for something else, and it should be settled
before `ci/` gains a boot-memory check (O-6) rather than by that check failing.

**O-11 (opened by the amendment).** The Image route imposes a 4 MiB floor on machine size: at
`-m 2M` QEMU refuses the machine before the kernel runs. Nothing in `profiles/` declares a minimum
RAM — `nano.toml` gives `ram_max_bytes` and no `ram_min_bytes` — so there is no field this fact
contradicts and no check it would fail. It is recorded because a floor introduced by a boot format is
invisible until someone ports to a board below it, and because the number is not the kernel's: it is
1 MiB of blob plus QEMU's placement rule, and a different loader would have a different floor.
