# RFC-0003: What memory exists, and who has it

- Objective: 0002 (memory, and the ground isolation stands on)  Status: draft
- Author: architect                        Model: claude-opus-5[1m]
- Milestone: M1, second and third parts

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
about it. §1 answers that fail-closed, and O-1 records what stays unsound and who can fix it.

## Design

### 0. What is established, and what is not

| Fact | Status |
| --- | --- |
| `x0` is zero at entry; it is not a DTB pointer for an ELF image | Verified in RFC-0001 against `hw/arm/boot.c` |
| QEMU builds a device tree and loads it at `info->dtb_start` — `0x4000_0000` for an image linked above `loader_start`, limit `0x4008_0000` | Read from QEMU's source in RFC-0001. **Not verified by this RFC**: the machine this was written on has no `qemu-system-aarch64` and no `dtc` installed, so nothing here was run against a real blob |
| The gate boots with `-M virt -cpu cortex-a72 -m 128M` | `ci/boot-test.sh`, `ci/lib.sh` |
| `cargo::rustc-link-arg=` applies to test targets as well as binaries | **Measured** for this RFC — see §6 |
| `[lib]` plus `[[bin]] test = false` lets `cargo test` run on the host with a `no_std`, `no_main` binary in the same package | **Measured** for this RFC — see §6 |
| The FDT header, token and reservation-block layout in §2 | Stated from the Devicetree Specification. Not verified against a blob here; the implementer must check each field, and a reviewer should treat a mismatch as a defect in this RFC |

### 1. Finding the device tree

`platform.rs` gains two board facts, and they are the only new constants:

```rust
/// Where QEMU virt places the device tree it builds for an ELF image: the base
/// of RAM, with the kernel linked 512 KiB above it.
pub const DTB_BASE: usize = 0x4000_0000;
/// The space between DTB_BASE and the kernel's link address. A blob claiming to
/// be larger than this is rejected rather than parsed.
pub const DTB_MAX_LEN: usize = 0x0008_0000;
```

The boot path reads the 40-byte header at `DTB_BASE`, validates it, and only then constructs a
`&'static [u8]` of exactly `totalsize` bytes. Every later access is a safe slice index.

**One candidate address, validated. No search.** Scanning a range for `0xd00d_feed` finds the magic
in a random four bytes of uninitialised RAM and turns garbage into a memory map, and the map is the
thing the whole milestone rests on. One address, checked hard, is the only shape that fails closed.

**No fallback to constants.** If the header does not validate, the kernel does not invent a memory
map; it says so and stops, before the boot marker, so the gate fails with a legible reason rather
than booting on a fiction. The objective's criterion 2 says "from the device tree rather than from
constants", and a fallback is exactly the code path that makes a build pass CI while ignoring the
device tree.

Validation, all of it, before a single byte of the structure block is read:

- `magic == 0xd00d_feed`
- `totalsize >= 40` and `totalsize <= DTB_MAX_LEN`
- `version >= 17` and `last_comp_version <= 17` — the parser reads `size_dt_struct`, which is a v17
  field, and a blob it cannot read is rejected rather than guessed at
- `off_dt_struct + size_dt_struct <= totalsize`, `off_dt_strings + size_dt_strings <= totalsize`,
  `off_mem_rsvmap <= totalsize`
- `off_dt_struct` is 4-byte aligned; `off_mem_rsvmap` is 8-byte aligned

Every one of those additions uses checked arithmetic. This is not style: `overflow-checks = true` is
on in release, so an overflow on a malformed header is a panic, and a panic prints `SKYNET_PANIC`
and says nothing about what was wrong with the blob. Malformed input must produce a typed error, not
the marker that means "the kernel has a bug".

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
| The memory reservation block | the blob |
| The kernel image, including its stack | `KERNEL_BASE` and `__kernel_end`, linker symbols |
| The device tree blob itself | `DTB_BASE` and the validated `totalsize` |
| The allocator's own bitmap | computed in §4 |

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

1. mint the console and the power token, as today;
2. validate the header at `DTB_BASE` and form the blob slice;
3. `fdt::parse` → `MemoryMap`;
4. add the kernel image, the blob and (after sizing) the bitmap to the reservations;
5. place the bitmap, construct the `FrameAllocator`;
6. hand `BootResources { console, power, frames }` to `kernel_main`.

Any failure in 2–5 writes a compile-time constant to the console — `SKYNET_MEM_FAIL` and one of a
fixed set of reasons — and powers the machine off. This happens **before** the boot marker, so
`ci/boot-test.sh` fails on the absent marker while the console says why. No new authority is
involved: the console and the power token are the two the boot path already holds, and the reasons
are `&'static [u8]`, so nothing runtime reaches the wire.

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

What no host test covers is the boot glue: the one unsafe slice construction, the linker symbols, and
the real blob at `DTB_BASE`. Nothing at M1 can test that except a boot, which is what conformance
criteria 4 and 5 are for. O-8.

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
- **The device tree's frames stay reserved.** The map is copied out of the blob during boot, so
  nothing needs it afterwards and its 512 KiB could be reclaimed. Not here: reclaiming memory that
  something might still hold a reference into is a decision, and this RFC has no way to prove nothing
  does.

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
- **Any change to `ci/`.** Two things this design would like are in `ci/` and are recorded as open
  questions instead.

## Constitutional impact

**Invariant 4, frugality *(enforced from M0)*.** Image: an FDT parser and a bitmap allocator, both
small and both measured rather than estimated here — conformance criterion 2 requires the
before-and-after size against nano's 192 KiB. The `#[cfg(test)]` code is not in the release binary
and costs nothing.

Boot memory: the bitmap, which is `ceil(frames / 8)` rounded to a frame — 4 KiB under the gate's
`-m 128M`, one frame on a nano device. Every profile declares `[budget.boot_memory]` with
`enforced_from = "M1"`, and **nothing in `ci/` measures it**: `ci/build.sh --size` measures the image
and gate condition 5 calls that. This design is the first to make the number depend on the machine
rather than on the link. O-6.

**Invariant 6, HAL boundary *(enforced from M0)*.** The parser and the allocator are portable, and
deliberately so: the flattened device tree is a data format, not an architecture. What stays in
`arch/` is what is genuinely architectural or board-specific — `DTB_BASE`, `DTB_MAX_LEN`,
`FRAME_SIZE`, the linker symbols, and the one unsafe slice construction. No portable file names an
architecture, uses a `cfg`, or assumes a word size: physical addresses are `u64` precisely so that a
32-bit port with a wider physical address space is not a silent truncation waiting to be found.

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

**Invariant 3, total provenance *(enforced now)*.** This RFC records three things a later reader
would otherwise rediscover: that the boot contract, having been corrected about `x0`, still does not
promise that a device tree exists or say where it is, so this design depends on something the
contract does not offer; that today's `build.rs` breaks `cargo test` and by exactly what mechanism;
and that the blob's placement at `0x4000_0000` is read from QEMU's source in RFC-0001 and was **not**
re-verified here, because this machine has no QEMU installed.

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
4. **PROOF:** boot under `-m 128M` and again under `-m 8M`, with temporary instrumentation printing
   the frame count, and show the two counts differ and match the machine. A build that hardcodes a
   size passes every other criterion here; this is the one that fails it. Remove the instrumentation
   before submitting, as RFC-0002's proofs do.
5. **PROOF:** boot with the first four bytes at `DTB_BASE` corrupted, and show `SKYNET_MEM_FAIL` with
   a reason, no boot marker, and a clean exit — not a timeout, not a panic marker.
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
10. `nm` on the built ELF still places `_start` at `0x4008_0000`, and `ci/lib.sh:kernel_binary()`
    still finds the binary — the package and binary names are unchanged by the library split.

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
and correct for QEMU virt today. Rejected because QEMU itself produces a second memory node once RAM
crosses into high memory, and the `standard` profile is "> 1 GiB" — the failure would arrive with the
first realistic machine, presented as a kernel that does not boot.

**Searching a range for the FDT magic.** Robust against QEMU changing where it places the blob, which
is the exact fragility O-1 is about. Rejected because a search that finds `0xd00d_feed` in
uninitialised RAM produces a memory map from noise, and every later guarantee in this milestone rests
on that map being true. A fixed address that fails loudly is worth more than a search that succeeds
plausibly.

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

**O-1.** How the kernel finds the device tree is the weakest part of this design, and it cannot be
fixed from inside `kernel/`. `x0` is zero because the artefact is an ELF; the blob's placement at
`0x4000_0000` is QEMU's behaviour read from its source in RFC-0001, not a contract, and not
re-verified here — this machine has no `qemu-system-aarch64` and no `dtc`, so the first person to run
the implementation is also the first to test the premise. The boot contract lists what the kernel may
rely on and a device tree is not among the entries; this design relies on one anyway, which is a gap
between what is promised and what is used, not a defect in either. The durable fixes are all in
`ci/`, which neither the architect nor the implementer may write: change the artefact to a raw
`Image`, so QEMU writes the pointer into `x0` and the kernel is told rather than guessing; pass
`-dtb <file>` and a known address; or add the placement to the contract, so that the thing the kernel
depends on is the thing CI promises. Recorded so that when the probe breaks, the answer is not a
search and not a fallback.

**O-2.** `/reserved-memory` is not parsed. On QEMU virt nothing populates it. On real hardware it is
how firmware says "this memory is mine", and a kernel that hands such a frame out corrupts something
with no fault and no report. It belongs with real hardware at M9, or with the first board that
declares one, whichever comes first.

**O-3.** `MAX_REGIONS = 8` and `MAX_RESERVED = 16` are guesses. Nothing in this repository establishes
what a real board reports, and the allocator cannot allocate its own arrays because it is the
allocator. The failure is legible rather than silent, which is the most this can offer; the numbers
should be revisited by whoever first meets hardware.

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
