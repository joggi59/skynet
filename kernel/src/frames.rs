// SPDX-License-Identifier: GPL-3.0-or-later

//! Physical frames: handing them out, taking them back, and not losing count.
//!
//! Portable. Nothing here names an architecture, a register, a board or an
//! address constant. The frame size arrives as a parameter, the memory arrives
//! as a [`MemoryMap`] the parser built, and the one piece of storage this
//! module needs — its bitmap — is handed to it as a slice the boot path
//! constructed out of real RAM. What is left is arithmetic, which is the whole
//! reason this file can be tested on a host that has no frames at all.
//!
//! # Why a bitmap and not a free list
//!
//! The classic bootstrap allocator threads a free list through the free frames
//! themselves: zero metadata, O(1) both ways, and the next pointer costs
//! nothing because it lives inside the frame it describes. RFC-0003 section 4
//! rejected it, and the deciding reason is about the design that comes after
//! this one rather than about this one. **A free list writes to every frame it
//! manages.** Once the MMU is on and everything the kernel was not given is
//! unmapped, an allocator that writes into free frames needs those frames
//! mapped — which means either a permanent read-write alias of all of RAM,
//! including the page tables, or a mapping window that has to be mutable at
//! run time. A bitmap allocator touches only its own bitmap.
//!
//! The second reason is this file's own tests: a free list cannot answer "how
//! many frames are free" without walking itself, and objective 0002's third
//! criterion is an accounting property checked by counting.
//!
//! # The index space
//!
//! Regions are sorted ascending and indexed consecutively. Frame index `i`
//! belongs to the first region whose running frame count exceeds `i`, so a hole
//! between two regions costs no bits and no indices. A region contributes only
//! the whole frames that lie *inside* it — the rounding here is inward, which
//! is the opposite of the rounding reservations get, and for the opposite
//! reason: a partial frame at the edge of a region is memory this allocator
//! cannot hand out in one piece, while a partial frame inside a reservation is
//! memory it must not hand out at all.
//!
//! Reservations round **outward**: the first frame is `floor(base / frame)` and
//! the last is the frame holding the last reserved byte. A frame that is partly
//! reserved is entirely reserved. The opposite rounding hands out a frame that
//! overlaps the kernel image, and the symptom of that is memory corruption with
//! no fault and no report.

use crate::hal::{MAX_REGIONS, MemoryMap, Region};

/// One frame of physical memory.
///
/// Neither `Copy` nor `Clone`, and its field is private. [`FrameAllocator::free`]
/// consumes it, so presenting the same frame twice requires fabricating one, and
/// there is no safe way to fabricate one: the only constructor is
/// [`FrameAllocator::alloc`], in this module. That is why `free`'s double-free
/// branch is a panic rather than an error return — reaching it means the
/// allocator or this module is broken, not that a caller made a recoverable
/// mistake.
///
/// It carries an index and not an address. The index is meaningful only to the
/// allocator that minted it; [`FrameAllocator::frame_base`] is the one thing
/// that turns it back into a physical address, and it is a `u64` there because
/// RFC-0003 section 7 requires physical addresses to survive a machine whose
/// memory starts above 4 GiB.
pub struct Frame {
    index: usize,
}

/// Why a [`FrameAllocator`] could not be built, or a bitmap could not be placed.
///
/// One variant per diagnosis, for the reason [`crate::fdt::Error`] has
/// twenty-nine of them: the boot path turns each into one fixed string, and "the
/// memory map is bad" sends whoever reads the console looking everywhere.
#[derive(Clone, Copy, PartialEq, Eq)]
#[cfg_attr(test, derive(Debug))]
pub enum Error {
    /// The frame size is zero, or is not a power of two.
    ///
    /// Every rounding in this file is a mask rather than a division, which is
    /// correct only for a power of two. Checked once, at the door.
    BadFrameSize,
    /// A region's `base + len` is not representable in 64 bits.
    ///
    /// The parser rejects such a blob already ([`crate::fdt::Error::RegionEndOverflows`]).
    /// It is checked again here because this function is `pub` and a
    /// [`MemoryMap`] built by any other route would otherwise wrap.
    RegionEndOverflows,
    /// Two discovered regions cover the same byte of physical memory.
    ///
    /// Not a formatting complaint. Overlapping regions give one frame two
    /// indices, and two indices are two bits, so the allocator would hand the
    /// same physical frame to two callers and never notice. RFC-0003 does not
    /// say what to do about it; refusing is the only answer that does not
    /// require inventing a policy — see the submission's note on this.
    RegionsOverlap,
    /// The frame count does not fit in a `usize`, or is so large that the
    /// bitmap's length would not.
    TooManyFrames,
    /// No whole frame lies inside any discovered region.
    ///
    /// A machine that reports memory but not one full frame of it cannot be
    /// served, and every expression below assumes at least one frame exists.
    NoUsableFrames,
    /// A reservation's `base + len` is not representable in 64 bits.
    ReservationEndOverflows,
    /// The bitmap's placement runs past the end of the address space.
    BitmapEndOverflows,
    /// The bitmap's placement is not wholly inside one discovered region.
    BitmapOutsideRegions,
    /// The bitmap's placement overlaps memory that is already spoken for.
    BitmapOverlapsReservation,
    /// The slice handed to [`FrameAllocator::new`] holds fewer bits than there
    /// are frames.
    ///
    /// Refused rather than truncated: an allocator that silently manages the
    /// first `8 * len` frames of a larger machine is an allocator whose `total`
    /// is a lie, and nothing downstream would ever discover it.
    BitmapTooSmall,
}

/// One region's worth of whole frames, and where they sit in the index space.
///
/// Built only by [`layout`], which is what makes the invariants below hold
/// everywhere else in this file:
///
///   - `base` is frame-aligned and `frames` is never zero;
///   - `base + frames * frame_size` does not overflow, because `frames` was
///     computed as `(region_end - base) / frame_size` and `region_end` is a
///     `u64` that already exists;
///   - runs are sorted ascending by `base` and do not overlap;
///   - `first` is the running total of every earlier run's `frames`.
#[derive(Clone, Copy)]
struct Run {
    /// Physical address of this run's first frame.
    base: u64,
    /// The index that first frame has in the allocator's index space.
    first: usize,
    /// How many whole frames the run holds. Never zero.
    frames: usize,
}

impl Run {
    /// One past the last byte this run covers. Frame-aligned, and cannot
    /// overflow — see the type's invariants.
    fn end(&self, frame_size: u64) -> u64 {
        self.base + self.frames as u64 * frame_size
    }
}

/// The index space, before anything is allocated out of it.
struct Layout {
    runs: [Run; MAX_REGIONS],
    count: usize,
    total: usize,
}

/// The largest frame count this file will index.
///
/// The bitmap is `total / 8` bytes and the scan in [`FrameAllocator::alloc`]
/// multiplies a byte index by eight, so a `total` within a few frames of
/// `usize::MAX` would overflow both. Bounding it once here means no expression
/// below needs a checked multiply, and `overflow-checks = true` is on in the
/// release profile — an unchecked one would be a panic on a machine nobody can
/// reproduce. The bound is 2^61 frames on a 64-bit target, which is eight
/// zettabytes of RAM at a 4 KiB frame.
const MAX_FRAMES: usize = usize::MAX / 8;

/// Round `value` up to the next multiple of `to`, which must be a power of two.
fn round_up(value: u64, to: u64) -> Option<u64> {
    value.checked_add(to - 1).map(|v| v & !(to - 1))
}

/// Round `value` down to a multiple of `to`, which must be a power of two.
fn round_down(value: u64, to: u64) -> u64 {
    value & !(to - 1)
}

/// Turn the discovered regions into a sorted, consecutive frame index space.
///
/// This is the only place regions are read, and every later expression in this
/// file relies on what it establishes — see [`Run`]'s invariants.
fn layout(map: &MemoryMap, frame_size: usize) -> Result<Layout, Error> {
    if frame_size == 0 || !frame_size.is_power_of_two() {
        return Err(Error::BadFrameSize);
    }
    let fs = frame_size as u64;

    const EMPTY: Run = Run {
        base: 0,
        first: 0,
        frames: 0,
    };
    let mut runs = [EMPTY; MAX_REGIONS];
    let mut count = 0usize;

    for region in map.regions() {
        let end = region
            .base
            .checked_add(region.len)
            .ok_or(Error::RegionEndOverflows)?;

        // Inward rounding: only frames wholly inside the region. A region whose
        // base is not frame-aligned loses the partial frame at its bottom, and
        // one whose end is not aligned loses the partial frame at its top.
        // Handing either out would hand out memory the region does not cover.
        let base = match round_up(region.base, fs) {
            Some(base) if base < end => base,
            // Either the region ends before its first frame boundary, or that
            // boundary is past the end of the address space. Both mean the
            // region holds no whole frame.
            _ => continue,
        };
        let frames = (end - base) / fs;
        if frames == 0 {
            continue;
        }
        let frames = usize::try_from(frames).map_err(|_| Error::TooManyFrames)?;

        // `map.regions()` is at most MAX_REGIONS long — the parser refuses a
        // longer blob with `TooManyRegions` — so this cannot run off the array.
        // The bound is restated rather than assumed, because a silent overwrite
        // here would lose a region.
        if count == MAX_REGIONS {
            return Err(Error::TooManyFrames);
        }
        runs[count] = Run {
            base,
            first: 0,
            frames,
        };
        count += 1;
    }

    // Insertion sort. At most eight elements, written out rather than reached
    // for, because invariant 7 means every bound in this kernel is one somebody
    // here wrote and can be read.
    for i in 1..count {
        let mut j = i;
        while j > 0 && runs[j - 1].base > runs[j].base {
            runs.swap(j - 1, j);
            j -= 1;
        }
    }

    // Overlapping regions would give one physical frame two indices, which is
    // exactly "a frame handed out twice" with nothing able to observe it.
    let mut total = 0usize;
    for i in 0..count {
        if i > 0 && runs[i - 1].end(fs) > runs[i].base {
            return Err(Error::RegionsOverlap);
        }
        runs[i].first = total;
        total = total
            .checked_add(runs[i].frames)
            .ok_or(Error::TooManyFrames)?;
    }

    if total == 0 {
        return Err(Error::NoUsableFrames);
    }
    if total > MAX_FRAMES {
        return Err(Error::TooManyFrames);
    }

    Ok(Layout { runs, count, total })
}

/// How many bytes of bitmap `total` frames need.
///
/// `total <= MAX_FRAMES` is established by [`layout`], so this cannot overflow.
fn bitmap_len(total: usize) -> usize {
    total.div_ceil(8)
}

/// Where the bitmap goes, given where the kernel image ends.
///
/// RFC-0003 section 4 fixes the placement rather than searching for one: the
/// first frame boundary at or above `floor`, for `ceil(total / 8)` bytes rounded
/// up to a whole frame. There is no fallback and no second candidate, because a
/// placement that moves with the machine is a placement nobody can predict when
/// they come to map it — RFC-0003 section 7 hands the MMU design
/// `[KERNEL_BASE, bitmap_end)` and that interval has to be derivable.
///
/// What is *checked* rather than fixed is that the placement is usable: it must
/// lie wholly inside one discovered region and must overlap nothing already
/// spoken for. Both failures are typed errors here, so the boot path can say
/// which one happened, rather than a bitmap truncated to whatever fitted.
///
/// The caller is expected to add the returned region to the map's reservations
/// before constructing the allocator; see [`FrameAllocator::new`].
pub fn bitmap_placement(
    map: &MemoryMap,
    frame_size: usize,
    floor: u64,
) -> Result<Region, Error> {
    let l = layout(map, frame_size)?;
    let fs = frame_size as u64;

    // `bitmap_len(total)` is at least 1, because `layout` refused a zero total,
    // so the placement is always at least one whole frame long.
    let len = round_up(bitmap_len(l.total) as u64, fs).ok_or(Error::BitmapEndOverflows)?;
    let base = round_up(floor, fs).ok_or(Error::BitmapEndOverflows)?;
    let end = base.checked_add(len).ok_or(Error::BitmapEndOverflows)?;

    // Wholly inside ONE run, not merely inside the union of several: the bitmap
    // is a single contiguous object and a hole in the middle of it is not
    // memory the kernel can write to.
    let inside = l.runs[..l.count]
        .iter()
        .any(|run| run.base <= base && end <= run.end(fs));
    if !inside {
        return Err(Error::BitmapOutsideRegions);
    }

    for entry in map.reserved() {
        if entry.len == 0 {
            continue;
        }
        let entry_end = entry
            .base
            .checked_add(entry.len)
            .ok_or(Error::ReservationEndOverflows)?;
        // Byte-level overlap, not frame-level. Frame-level would refuse a
        // placement that merely shares a frame with the top of the kernel
        // image, and the placement is frame-aligned above `__kernel_end`, so it
        // never can.
        if base < entry_end && entry.base < end {
            return Err(Error::BitmapOverlapsReservation);
        }
    }

    Ok(Region { base, len })
}

/// Physical frames, one bit each, `1` meaning allocated.
///
/// An owned value with private fields. No interior mutability, no lock, no
/// atomic, no accessor that returns it, and it is not a `static` — it is minted
/// once in the boot path and moved into `kernel_main` inside `BootResources`,
/// the same shape the console and the power token already have. That shape is
/// the whole of what makes the second real authority in this kernel defensible
/// at M1, and nothing mechanical enforces it: constitutional invariant 1 is
/// pending until M4 and this is held by review alone.
///
/// M2's second core needs an answer that is not "make it a global behind a
/// spinlock", and RFC-0003 O-5 defers that to M2's concurrency model precisely
/// so that the answer is designed rather than reached for. It is not a
/// capability either — no attenuation, no revocation, no expiry, no accounting
/// to a holder. M4 designs those, and a half-capability built here is the
/// retrofit objective 0002's non-goals exclude by name.
pub struct FrameAllocator {
    /// One bit per frame, exactly `ceil(total / 8)` bytes long.
    ///
    /// The slice is truncated to that length in [`FrameAllocator::new`], so
    /// every bit in it except the last byte's tail describes a real frame, and
    /// the tail is set at construction so the scan can never find it.
    bitmap: &'static mut [u8],
    runs: [Run; MAX_REGIONS],
    run_count: usize,
    frame_size: usize,
    total: usize,
    available: usize,
}

impl FrameAllocator {
    /// Build an allocator over `map`, using `bitmap` as its storage.
    ///
    /// # Safety
    ///
    /// `bitmap` must be:
    ///
    ///   - **memory nothing else refers to.** This takes a `&'static mut [u8]`
    ///     and keeps it forever, so any other live reference to those bytes is
    ///     immediate undefined behaviour. The caller must have constructed it
    ///     from an address no other object occupies.
    ///   - **inside one of `map`'s regions.** The constructor writes every byte
    ///     of it. If it is not memory the map reported, the write goes to
    ///     something else or to nothing at all.
    ///   - **overlapping none of `map`'s reservations**, with exactly one
    ///     exception: the entry describing the bitmap itself. RFC-0003 section 5
    ///     orders the boot path to size the bitmap, add it to the reservations,
    ///     and only then construct — so by the time this runs, the bitmap's own
    ///     frames are one of the reservations it is about to mark used, which is
    ///     what stops them from ever being handed out. Every *other* reservation
    ///     must be disjoint from it, and [`bitmap_placement`] is the function
    ///     that checks that, against the map as it stood before the bitmap's own
    ///     entry was added.
    ///   - **long enough for the map's frame count.** This one is checked here
    ///     rather than trusted, because it is the only one of the four that can
    ///     be: `bitmap.len() * 8` must be at least `total()`, and a slice that
    ///     is short is [`Error::BitmapTooSmall`] rather than an allocator whose
    ///     `total` quietly describes part of the machine.
    ///
    /// The one call site is `boot_rust` in `arch/aarch64/boot.rs`, and it is
    /// written to uphold each of these in that order.
    ///
    /// The bitmap is zeroed here and not assumed to arrive zeroed. Nothing zeroes
    /// RAM on this machine — `_start` zeroes `.bss` and nothing else — so an
    /// allocator that trusted its storage to be clear would start with a
    /// scattering of frames it believed were already handed out.
    pub unsafe fn new(
        map: &MemoryMap,
        bitmap: &'static mut [u8],
        frame_size: usize,
    ) -> Result<Self, Error> {
        let l = layout(map, frame_size)?;
        let needed = bitmap_len(l.total);
        if bitmap.len() < needed {
            return Err(Error::BitmapTooSmall);
        }

        // Truncate to exactly the bytes that describe frames. The rest of the
        // placement — the bitmap is rounded up to a whole frame, so there is
        // almost always some — is reserved memory nobody reads, and dropping the
        // reference to it here means every length in this type is exact and the
        // scan below has no tail to skip.
        let (bitmap, _spare) = bitmap.split_at_mut(needed);

        let mut allocator = Self {
            bitmap,
            runs: l.runs,
            run_count: l.count,
            frame_size,
            total: l.total,
            available: l.total,
        };

        allocator.bitmap.fill(0);

        // The last byte's bits above `total` describe no frame. Setting them
        // means `alloc`'s search for a zero bit needs no bound of its own: a
        // zero bit is a free frame, always, with no index check on the hot path
        // and no way for an off-by-one there to hand out memory that does not
        // exist.
        for index in allocator.total..allocator.bitmap.len() * 8 {
            allocator.set(index);
        }

        // BEFORE any frame is handed out — this is the whole ordering
        // constraint. An allocator that marks its reservations after its first
        // `alloc` can hand out its own bitmap, and the symptom is a corrupt
        // allocator with no fault and no report.
        for entry in map.reserved() {
            allocator.reserve(entry)?;
        }

        Ok(allocator)
    }

    /// The lowest free frame, or `None` when there are none.
    ///
    /// Deterministic: the scan starts at index zero every time. No cursor and no
    /// hint, so the sequence of frames a boot hands out does not depend on what
    /// it freed earlier. RFC-0003 section 4 chose that over a cursor because a
    /// boot that allocates the same frames in the same order every time is worth
    /// more at this milestone than a scan nobody has measured. Performance is a
    /// non-goal here and this is O(bitmap) per call.
    ///
    /// Exhaustion is not a policy question this file answers: it returns `None`
    /// and what a caller does about it is decided where the caller is.
    pub fn alloc(&mut self) -> Option<Frame> {
        let byte = self.bitmap.iter().position(|b| *b != 0xff)?;
        // The lowest zero bit of a byte that is not all ones. `trailing_ones`
        // is at most 7 here, so the shift below is in range.
        let bit = self.bitmap[byte].trailing_ones() as usize;
        self.bitmap[byte] |= 1u8 << bit;
        self.available -= 1;
        // Bit 0 of byte 0 is frame 0. Tail bits above `total` were set at
        // construction, so `byte * 8 + bit` is always a real frame.
        Some(Frame {
            index: byte * 8 + bit,
        })
    }

    /// Return a frame to the pool. Consumes it.
    ///
    /// # Panics
    ///
    /// If the frame's bit is already clear, or if it names an index this
    /// allocator does not manage. Both mean this module or its caller is broken
    /// rather than that anything recoverable happened: [`Frame`] is neither
    /// `Copy` nor `Clone`, its field is private, and `alloc` is its only
    /// constructor, so safe code outside this module cannot present the same
    /// frame twice or invent one.
    ///
    /// A panic prints `SKYNET_PANIC` and nothing else. RFC-0001 O-4 is why it
    /// cannot say more, and this task does not fix it — if it should say more,
    /// that is an RFC and not a patch.
    pub fn free(&mut self, frame: Frame) {
        let index = frame.index;
        assert!(index < self.total, "frame index outside this allocator");
        let byte = index / 8;
        let bit = 1u8 << (index % 8);
        assert!(self.bitmap[byte] & bit != 0, "double free");
        self.bitmap[byte] &= !bit;
        self.available += 1;
    }

    /// How many frames exist. Fixed at construction and never changes.
    pub fn total(&self) -> usize {
        self.total
    }

    /// How many frames are free right now.
    pub fn available(&self) -> usize {
        self.available
    }

    /// The physical address of a frame's first byte.
    ///
    /// A `Frame` carries an index, which means nothing outside the allocator
    /// that minted it; this is the one operation that turns it back into an
    /// address, and it is what makes a frame usable by anything at all. It is
    /// also what lets the claim "this allocator never hands out memory that is
    /// spoken for" be re-checked by anyone, on a machine, with nothing added but
    /// a print — which is how acceptance criteria 8 and 9 of this task were
    /// measured.
    ///
    /// `u64` rather than `usize`: RFC-0003 section 7 requires a physical address
    /// to survive a machine whose memory starts above 4 GiB on a target where
    /// `usize` is narrower.
    ///
    /// # Panics
    ///
    /// If the frame names an index this allocator does not manage, which cannot
    /// happen for a frame it minted: the runs partition `0..total` exactly.
    pub fn frame_base(&self, frame: &Frame) -> u64 {
        let fs = self.frame_size as u64;
        for run in &self.runs[..self.run_count] {
            if frame.index >= run.first && frame.index - run.first < run.frames {
                return run.base + (frame.index - run.first) as u64 * fs;
            }
        }
        panic!("frame index outside this allocator");
    }

    /// Mark every frame an entry touches as used, rounding outward.
    ///
    /// Idempotent across overlapping entries: `set` reports whether the bit
    /// actually changed, and `available` moves only when it did. Two
    /// reservations covering the same frame therefore cost one frame and not
    /// two, which is the difference between the bitmap and the count agreeing
    /// afterwards and not.
    fn reserve(&mut self, entry: &Region) -> Result<(), Error> {
        // A zero-length entry reserves nothing. It is not a hypothetical: `(0, 0)`
        // is the memory reservation block's terminator, and the last-frame
        // expression below underflows on a length of zero — `base + len - 1` with
        // `len == 0` is a wrap, and `overflow-checks = true` makes it a panic that
        // says only `SKYNET_PANIC`.
        if entry.len == 0 {
            return Ok(());
        }
        let fs = self.frame_size as u64;
        let last = entry
            .base
            .checked_add(entry.len - 1)
            .ok_or(Error::ReservationEndOverflows)?;

        // Outward: the frame holding the first reserved byte, through the frame
        // holding the last one. RFC-0003 section 3 states this as
        // `ceil((base + len) / FRAME_SIZE) - 1` for the last frame; for a length
        // of at least one byte that is the same number as the frame holding
        // `base + len - 1`, and this form has no expression that can underflow.
        let first_frame = round_down(entry.base, fs);
        let last_frame = round_down(last, fs);

        for i in 0..self.run_count {
            let run = self.runs[i];
            let run_end = run.end(fs);

            let lo = if first_frame > run.base {
                first_frame
            } else {
                run.base
            };
            // One past the last reserved frame. `last_frame + fs` cannot be
            // reached past the address space in a way that matters: if it
            // overflows, the saturated value is above every `run_end`, and
            // `run_end` is frame-aligned relative to `run.base`, so `hi` stays
            // aligned and the divisions below stay exact.
            let hi = last_frame.saturating_add(fs);
            let hi = if hi < run_end { hi } else { run_end };
            if lo >= hi {
                continue;
            }

            let first_index = run.first + ((lo - run.base) / fs) as usize;
            let count = ((hi - lo) / fs) as usize;
            for index in first_index..first_index + count {
                if self.set(index) {
                    self.available -= 1;
                }
            }
        }
        Ok(())
    }

    /// Set a bit. Returns whether it was clear before.
    fn set(&mut self, index: usize) -> bool {
        let byte = index / 8;
        let bit = 1u8 << (index % 8);
        let was_clear = self.bitmap[byte] & bit == 0;
        self.bitmap[byte] |= bit;
        was_clear
    }

    /// Whether a frame's bit is set. For this module's own tests.
    #[cfg(test)]
    fn is_set(&self, index: usize) -> bool {
        self.bitmap[index / 8] & (1u8 << (index % 8)) != 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The frame size every test below uses, and the one the aarch64 port
    /// defines. Named separately so that nothing in this module depends on
    /// `arch`, which portable code may not reach.
    const FS: usize = 4096;

    /// A plausible RAM base, so that a test failure reads like a machine.
    const RAM: u64 = 0x4000_0000;

    // -----------------------------------------------------------------------
    // Fixtures
    // -----------------------------------------------------------------------

    fn map_of(regions: &[(u64, u64)], reserved: &[(u64, u64)]) -> MemoryMap {
        let mut map = MemoryMap::empty();
        for &(base, len) in regions {
            map.push_region(Region { base, len }).unwrap();
        }
        for &(base, len) in reserved {
            map.push_reserved(Region { base, len }).unwrap();
        }
        map
    }

    /// A bitmap of `bytes` bytes, filled with a pattern that is not zero.
    ///
    /// Deliberately `0xa5` rather than `0`: nothing zeroes RAM on the machine
    /// this runs on, so an allocator that assumed clear storage would start
    /// believing half its frames were already handed out. Every test here would
    /// pass over a zeroed buffer and none of them would notice.
    fn bitmap(bytes: usize) -> &'static mut [u8] {
        Box::leak(vec![0xa5u8; bytes].into_boxed_slice())
    }

    /// Build an allocator, sized exactly, over a map that must be well formed.
    ///
    /// The storage is the host's heap rather than a placement inside the map:
    /// three of `new`'s four safety clauses are about a caller writing into real
    /// RAM, and on the host there is none to write into. The fourth — long
    /// enough for the frame count — is the one these tests care about, and it is
    /// satisfied exactly, with no slack, so an off-by-one in the length would
    /// show up here rather than being absorbed by a rounded-up frame.
    fn allocator(map: &MemoryMap) -> FrameAllocator {
        let total = layout(map, FS).unwrap().total;
        // SAFETY: the bitmap is a fresh heap allocation this test owns and
        // leaks, so nothing else refers to it and it lives for the rest of the
        // process. Its length is exactly `ceil(total / 8)`.
        unsafe { FrameAllocator::new(map, bitmap(bitmap_len(total)), FS) }.unwrap()
    }

    /// Every index the allocator hands out, in order, until it stops.
    fn drain(a: &mut FrameAllocator) -> Vec<Frame> {
        let mut out = Vec::new();
        while let Some(f) = a.alloc() {
            out.push(f);
        }
        out
    }

    fn indices(frames: &[Frame]) -> Vec<usize> {
        frames.iter().map(|f| f.index).collect()
    }

    // -----------------------------------------------------------------------
    // The objective's criterion
    // -----------------------------------------------------------------------

    /// RFC-0003 section 6, and objective 0002's third success criterion.
    ///
    /// The last clause is the one that makes this a test of not losing track
    /// rather than a test of counting: an allocator that miscounted but kept a
    /// consistent bitmap would pass the first four assertions.
    #[test]
    fn exhaust_and_recover() {
        // No reservations, so `total` and the number handed out are the same
        // number and the assertions below are the RFC's words rather than a
        // paraphrase of them.
        let map = map_of(&[(RAM, 0x0080_0000)], &[]);
        let mut a = allocator(&map);
        assert_eq!(a.total(), 2048);
        assert_eq!(a.available(), 2048);

        let first = drain(&mut a);
        assert_eq!(first.len(), a.total());
        assert_eq!(a.available(), 0);

        // The frames are consumed by `free`, so the sequence has to be recorded
        // before they are given back. Nothing here fabricates a `Frame`.
        let taken = indices(&first);
        for frame in first {
            a.free(frame);
        }
        assert_eq!(a.available(), a.total());

        let second = drain(&mut a);
        assert_eq!(indices(&second), taken);
    }

    /// The same, over a pool with a hole and three reservations in it.
    ///
    /// `exhaust_and_recover` is the RFC's words and runs over the easiest map
    /// there is. This runs the same shape over the map shape the machine
    /// actually has: two regions, a reservation straddling a frame boundary,
    /// and one in the middle of the upper region.
    #[test]
    fn exhaust_and_recover_over_a_reserved_and_holed_pool() {
        let map = map_of(
            &[(RAM, 0x10_0000), (RAM + 0x20_0000, 0x10_0000)],
            &[
                (RAM, 0x1000),             // the bottom frame of region 0
                (RAM + 0x0F_FFFF, 2),      // runs off the top of region 0
                (RAM + 0x20_8000, 0x1000), // one frame inside region 1
            ],
        );
        let mut a = allocator(&map);
        assert_eq!(a.total(), 512);
        // Three frames: index 0; index 255, region 0's last — the entry's second
        // byte lands in the hole above it, which is not a frame at all; and
        // index 264 in region 1.
        assert_eq!(a.available(), 509);

        let first = drain(&mut a);
        assert_eq!(first.len(), 509);
        assert_eq!(a.available(), 0);
        assert_eq!(a.total(), 512);

        let taken = indices(&first);
        assert!(!taken.contains(&0));
        assert!(!taken.contains(&255));
        assert!(!taken.contains(&264));
        for frame in first {
            a.free(frame);
        }
        assert_eq!(a.available(), 509);

        let second = drain(&mut a);
        assert_eq!(indices(&second), taken);
    }

    /// Freeing in an order unrelated to the allocation order changes nothing.
    ///
    /// This is what "no cursor and no hint" buys: the sequence is a function of
    /// the reservations alone, not of the free history.
    #[test]
    fn the_sequence_does_not_depend_on_the_free_order() {
        let map = map_of(&[(RAM, 0x20_0000)], &[]);
        let mut a = allocator(&map);

        let held = drain(&mut a);
        let first = indices(&held);

        // Free from the top down, which is the reverse of how they were handed
        // out, and interleave a re-allocation so the bitmap passes through a
        // state the first pass never visited.
        for frame in held.into_iter().rev() {
            a.free(frame);
        }
        let one = a.alloc().unwrap();
        assert_eq!(one.index, 0);
        a.free(one);

        assert_eq!(indices(&drain(&mut a)), first);
    }

    // -----------------------------------------------------------------------
    // Reservation rounding
    // -----------------------------------------------------------------------

    /// One byte inside a frame takes the whole frame — and only that frame.
    ///
    /// Both halves. A test that checks only the reserved frame passes under the
    /// rounding that hands out a frame overlapping the kernel image, which is
    /// the rounding this is here to refuse.
    #[test]
    fn one_reserved_byte_takes_its_whole_frame_and_leaves_the_next() {
        let map = map_of(&[(RAM, 0x10000)], &[(RAM + 0x2001, 1)]);
        let mut a = allocator(&map);
        assert_eq!(a.total(), 16);
        assert_eq!(a.available(), 15);

        let taken = indices(&drain(&mut a));
        assert!(!taken.contains(&2), "the reserved frame was handed out");
        assert!(taken.contains(&3), "the frame after it was not handed out");
        assert!(taken.contains(&1), "the frame before it was not handed out");
    }

    /// The last byte of a frame belongs to that frame and not to the next one.
    #[test]
    fn a_byte_at_the_top_of_a_frame_does_not_reach_the_next_frame() {
        let map = map_of(&[(RAM, 0x10000)], &[(RAM + 0x2fff, 1)]);
        let mut a = allocator(&map);
        let taken = indices(&drain(&mut a));
        assert!(!taken.contains(&2));
        assert!(taken.contains(&3));
    }

    /// The first byte of a frame belongs to it and not to the one below.
    #[test]
    fn a_byte_at_the_bottom_of_a_frame_does_not_reach_the_previous_frame() {
        let map = map_of(&[(RAM, 0x10000)], &[(RAM + 0x3000, 1)]);
        let mut a = allocator(&map);
        let taken = indices(&drain(&mut a));
        assert!(taken.contains(&2));
        assert!(!taken.contains(&3));
    }

    /// Two bytes across a boundary take two frames.
    #[test]
    fn a_reservation_straddling_a_boundary_takes_both_frames() {
        let map = map_of(&[(RAM, 0x10000)], &[(RAM + 0x2fff, 2)]);
        let mut a = allocator(&map);
        assert_eq!(a.available(), 14);
        let taken = indices(&drain(&mut a));
        assert!(!taken.contains(&2));
        assert!(!taken.contains(&3));
        assert!(taken.contains(&4));
    }

    /// A reservation across a region boundary takes frames in both regions.
    ///
    /// The blob on this machine sits in the middle of the pool rather than at
    /// its bottom, so a reservation that splits the free memory is the normal
    /// case and not the exotic one. This is its harder shape: one entry, two
    /// regions.
    #[test]
    fn a_reservation_across_two_regions_marks_frames_in_each() {
        // Region 0 ends at RAM + 0x4000; region 1 starts at RAM + 0x8000. The
        // reservation runs from inside region 0's last frame to inside region
        // 1's first.
        let map = map_of(
            &[(RAM, 0x4000), (RAM + 0x8000, 0x4000)],
            &[(RAM + 0x3fff, 0x4002)],
        );
        let mut a = allocator(&map);
        assert_eq!(a.total(), 8);
        // Frame 3 (region 0's top) and frame 4 (region 1's bottom). Everything
        // between them is the hole and costs no bits.
        assert_eq!(a.available(), 6);
        let taken = indices(&drain(&mut a));
        assert!(!taken.contains(&3));
        assert!(!taken.contains(&4));
        assert!(taken.contains(&2));
        assert!(taken.contains(&5));
    }

    /// Two entries covering the same frame cost one frame, not two.
    ///
    /// The specific failure this refuses: `available` decremented once per
    /// entry instead of once per bit that changed, which leaves the count and
    /// the bitmap disagreeing — and nothing observes the disagreement until an
    /// exhaustion test counts what it got.
    #[test]
    fn overlapping_reservations_are_counted_once() {
        let map = map_of(
            &[(RAM, 0x10000)],
            &[(RAM + 0x2000, 0x2000), (RAM + 0x2800, 0x1000)],
        );
        let mut a = allocator(&map);
        assert_eq!(a.total(), 16);
        assert_eq!(a.available(), 14);
        assert_eq!(drain(&mut a).len(), 14);
        assert_eq!(a.available(), 0);
    }

    /// A reservation that names memory no region reported reserves nothing.
    ///
    /// It is not an error. Firmware may reserve memory outside the pool, and
    /// refusing to boot over an entry the allocator could never have handed out
    /// would be a kernel that stops for something that cannot hurt it.
    #[test]
    fn a_reservation_outside_every_region_reserves_nothing() {
        let map = map_of(&[(RAM, 0x10000)], &[(0x1000_0000, 0x1000)]);
        let mut a = allocator(&map);
        assert_eq!(a.available(), a.total());
        assert_eq!(drain(&mut a).len(), 16);
    }

    /// A zero-length entry reserves nothing and does not underflow.
    ///
    /// Two readings of `(0, 0)` exist and both are handled. As the memory
    /// reservation block's **terminator** it never becomes an entry at all —
    /// `crate::fdt`'s `the_zero_pair_terminates_the_block` is the test for that
    /// half, and `the_terminator_never_reaches_the_allocator` below checks it
    /// end to end through a real blob. As an **entry** — which a hand-built map
    /// or a future non-blob source can still produce — it is skipped here.
    ///
    /// Skipped rather than computed: the last-frame expression is
    /// `base + len - 1`, which wraps on a length of zero, and with
    /// `overflow-checks = true` a wrap is a panic that says only
    /// `SKYNET_PANIC`. `(0, 0)` would additionally have reserved frame 0 of
    /// whatever region starts at address zero.
    #[test]
    fn a_zero_length_reservation_reserves_nothing() {
        let map = map_of(&[(0, 0x10000)], &[(0, 0), (0x2000, 0)]);
        let mut a = allocator(&map);
        assert_eq!(a.total(), 16);
        assert_eq!(a.available(), 16);
        let taken = indices(&drain(&mut a));
        assert!(taken.contains(&0), "a zero-length entry reserved frame 0");
        assert!(taken.contains(&2));
    }

    // -----------------------------------------------------------------------
    // The index space
    // -----------------------------------------------------------------------

    /// A hole between two regions costs no frames and no indices.
    ///
    /// And a frame freed from the upper region comes back from the upper
    /// region: the index space is not a re-labelling that loses which side of
    /// the hole a frame was on.
    #[test]
    fn a_hole_between_regions_costs_nothing_and_is_never_crossed() {
        let lower = (RAM, 0x10000); // 16 frames, indices 0..16
        let upper = (RAM + 0x100_0000, 0x8000); // 8 frames, indices 16..24
        let map = map_of(&[lower, upper], &[]);
        let mut a = allocator(&map);
        assert_eq!(a.total(), 24, "the hole was counted");

        let all = drain(&mut a);
        // No frame anywhere in the hole.
        for f in &all {
            let base = a.frame_base(f);
            let in_lower = base >= lower.0 && base < lower.0 + lower.1;
            let in_upper = base >= upper.0 && base < upper.0 + upper.1;
            assert!(in_lower || in_upper, "frame at {base:#x} is in the hole");
        }

        // Index 20 is the fifth frame of the upper region.
        assert_eq!(
            a.frame_base(&all[20]),
            upper.0 + 4 * FS as u64,
            "index 20 is not where the upper region says it is"
        );

        let mut all = all;
        let returned = all.remove(20);
        let base_before = a.frame_base(&returned);
        a.free(returned);
        let again = a.alloc().unwrap();
        assert_eq!(again.index, 20);
        assert_eq!(a.frame_base(&again), base_before);
    }

    /// Regions arrive in whatever order the blob listed them.
    #[test]
    fn regions_are_sorted_before_they_are_indexed() {
        let map = map_of(&[(RAM + 0x10_0000, 0x2000), (RAM, 0x2000)], &[]);
        let mut a = allocator(&map);
        assert_eq!(a.total(), 4);
        let frames = drain(&mut a);
        assert_eq!(a.frame_base(&frames[0]), RAM);
        assert_eq!(a.frame_base(&frames[1]), RAM + 0x1000);
        assert_eq!(a.frame_base(&frames[2]), RAM + 0x10_0000);
        assert_eq!(a.frame_base(&frames[3]), RAM + 0x10_1000);
    }

    /// Overlapping regions are refused rather than indexed twice.
    #[test]
    fn overlapping_regions_are_an_error() {
        let map = map_of(&[(RAM, 0x4000), (RAM + 0x2000, 0x4000)], &[]);
        assert_eq!(
            bitmap_placement(&map, FS, 0).unwrap_err(),
            Error::RegionsOverlap
        );
    }

    /// Regions that merely touch do not overlap.
    #[test]
    fn regions_that_abut_are_not_overlapping() {
        let map = map_of(&[(RAM, 0x4000), (RAM + 0x4000, 0x4000)], &[]);
        let a = allocator(&map);
        assert_eq!(a.total(), 8);
    }

    /// A region that is not frame-aligned contributes only its whole frames.
    ///
    /// Inward rounding at both ends. The frame at the bottom is lost because
    /// part of it is below the region, and the one at the top because part of
    /// it is above — handing out either would hand out memory the machine did
    /// not report.
    #[test]
    fn an_unaligned_region_contributes_only_whole_frames() {
        // From half a frame in to half a frame short of the end: 0x1_0000 bytes
        // of span, of which fourteen whole frames lie inside.
        let map = map_of(&[(RAM + 0x800, 0x10000 - 0x1000)], &[]);
        let mut a = allocator(&map);
        assert_eq!(a.total(), 14);
        let frames = drain(&mut a);
        assert_eq!(a.frame_base(&frames[0]), RAM + 0x1000);
        assert_eq!(a.frame_base(&frames[13]), RAM + 0xe000);
    }

    /// A region shorter than one frame contributes nothing at all.
    #[test]
    fn a_region_with_no_whole_frame_contributes_nothing() {
        let map = map_of(&[(RAM + 0x800, 0x400), (RAM + 0x4000, 0x2000)], &[]);
        let a = allocator(&map);
        assert_eq!(a.total(), 2);
    }

    /// A map with no whole frame anywhere is an error, not a zero-sized pool.
    #[test]
    fn a_map_with_no_usable_frame_is_an_error() {
        let map = map_of(&[(RAM + 0x800, 0x400)], &[]);
        assert_eq!(
            bitmap_placement(&map, FS, 0).unwrap_err(),
            Error::NoUsableFrames
        );
    }

    /// A region running off the end of the address space is refused.
    #[test]
    fn a_region_end_that_overflows_is_an_error() {
        let map = map_of(&[(u64::MAX - 0x1000, 0x8000)], &[]);
        assert_eq!(
            bitmap_placement(&map, FS, 0).unwrap_err(),
            Error::RegionEndOverflows
        );
    }

    /// A reservation running off the end of the address space is refused.
    #[test]
    fn a_reservation_end_that_overflows_is_an_error() {
        let map = map_of(&[(RAM, 0x4000)], &[(u64::MAX - 0x10, 0x1000)]);
        assert_eq!(
            bitmap_placement(&map, FS, RAM).unwrap_err(),
            Error::ReservationEndOverflows
        );
        // And on the other path into the same entry: building the allocator.
        let total = layout(&map, FS).unwrap().total;
        // SAFETY: fresh leaked storage this test owns; see `allocator`.
        let err = unsafe { FrameAllocator::new(&map, bitmap(bitmap_len(total)), FS) }
            .err()
            .unwrap();
        assert_eq!(err, Error::ReservationEndOverflows);
    }

    // -----------------------------------------------------------------------
    // Exhaustion, double allocation, double free
    // -----------------------------------------------------------------------

    /// An exhausted pool says so, repeatedly, and keeps its total.
    #[test]
    fn an_exhausted_pool_returns_none_and_keeps_its_total() {
        let map = map_of(&[(RAM, 0x4000)], &[]);
        let mut a = allocator(&map);
        let held = drain(&mut a);
        assert_eq!(held.len(), 4);
        assert!(a.alloc().is_none());
        assert!(a.alloc().is_none());
        assert_eq!(a.available(), 0);
        assert_eq!(a.total(), 4);
    }

    /// No frame is ever handed out twice, by index or by address.
    ///
    /// No single allocation observes this, which is the reason it has its own
    /// test: `alloc` returning a frame it has already given away looks correct
    /// from the call site every time.
    #[test]
    fn every_frame_handed_out_is_distinct() {
        let map = map_of(
            &[(RAM, 0x10000), (RAM + 0x100_0000, 0x10000)],
            &[(RAM + 0x5000, 1)],
        );
        let mut a = allocator(&map);
        let frames = drain(&mut a);

        let mut seen_index: Vec<usize> = frames.iter().map(|f| f.index).collect();
        let count = seen_index.len();
        seen_index.sort_unstable();
        seen_index.dedup();
        assert_eq!(seen_index.len(), count, "an index was handed out twice");

        let mut seen_base: Vec<u64> = frames.iter().map(|f| a.frame_base(f)).collect();
        seen_base.sort_unstable();
        seen_base.dedup();
        assert_eq!(seen_base.len(), count, "an address was handed out twice");
    }

    /// Freeing clears the bit, which is what makes a second free detectable.
    ///
    /// The panic itself cannot be tested here: `[profile.dev]` sets
    /// `panic = "abort"`, so a `#[should_panic]` test aborts the runner rather
    /// than passing. What is testable is the state the panic branch reads —
    /// after a free the bit is clear, so a second free with the same frame
    /// takes that branch. Fabricating that second frame needs this module's
    /// private field, which is exactly the property being demonstrated: safe
    /// code outside the module cannot do it.
    #[test]
    fn freeing_clears_the_bit_the_double_free_branch_reads() {
        let map = map_of(&[(RAM, 0x4000)], &[]);
        let mut a = allocator(&map);
        let f = a.alloc().unwrap();
        assert!(a.is_set(0));
        a.free(f);
        assert!(!a.is_set(0), "the bit survived the free");
    }

    /// The count and the bitmap still agree after a long unusual sequence.
    ///
    /// Exhaustion and recovery is one path through the state space. This walks
    /// twenty thousand steps of a different one — allocate and free
    /// interleaved, from a deterministic generator, with the pool passing
    /// through full, empty and everything between — and re-derives `available`
    /// from the bitmap at every step rather than trusting the counter that is
    /// under test.
    ///
    /// The generator is a plain LCG written here because invariant 7 forbids
    /// reaching for one, and a fixed seed because a test that fails on some
    /// runs is a test nobody can act on.
    #[test]
    fn the_count_and_the_bitmap_agree_after_twenty_thousand_operations() {
        let map = map_of(
            &[(RAM, 0x20000), (RAM + 0x100_0000, 0x10000)],
            &[(RAM + 0x1000, 0x1001), (RAM + 0x100_0000, 1)],
        );
        let mut a = allocator(&map);
        let reserved = a.total() - a.available();
        // Frames 1 and 2 of the lower region, and frame 32 — the first of the
        // upper one.
        assert_eq!(a.total(), 48);
        assert_eq!(reserved, 3);

        let mut held: Vec<Frame> = Vec::new();
        let mut state: u64 = 0x2545_f491_4f6c_dd1d;
        for step in 0..20_000u32 {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let take = !(state >> 33).is_multiple_of(3) || held.is_empty();

            if take {
                if let Some(f) = a.alloc() {
                    held.push(f);
                }
            } else {
                let victim = ((state >> 17) as usize) % held.len();
                a.free(held.swap_remove(victim));
            }

            // Re-derive the free count from the bits, and check the frames
            // still held are exactly the ones the bitmap calls used.
            let free_bits = (0..a.total()).filter(|i| !a.is_set(*i)).count();
            assert_eq!(a.available(), free_bits, "counts diverged at step {step}");
            assert_eq!(
                held.len() + reserved,
                a.total() - free_bits,
                "held frames and set bits diverged at step {step}"
            );
        }

        // And it recovers: everything back, then the pool is whole again.
        for f in held {
            a.free(f);
        }
        assert_eq!(a.available(), a.total() - reserved);
    }

    // -----------------------------------------------------------------------
    // The bitmap's own storage
    // -----------------------------------------------------------------------

    /// The placement is the first frame boundary at or above the floor, and is
    /// a whole number of frames long.
    #[test]
    fn the_bitmap_lands_on_the_first_frame_boundary_above_the_floor() {
        // 32768 frames needs 4096 bytes of bitmap: exactly one frame.
        let map = map_of(&[(RAM, 0x0800_0000)], &[]);
        let place = bitmap_placement(&map, FS, RAM + 0x1_3360).unwrap();
        assert_eq!(place.base, RAM + 0x1_4000);
        assert_eq!(place.len, 4096);

        // 2048 frames needs 256 bytes, rounded up to one whole frame.
        let small = map_of(&[(RAM, 0x0080_0000)], &[]);
        let place = bitmap_placement(&small, FS, RAM + 0x1_4000).unwrap();
        assert_eq!(place.base, RAM + 0x1_4000, "an aligned floor was moved");
        assert_eq!(place.len, 4096);
    }

    /// A bitmap that would not fit inside a region is a typed error.
    ///
    /// Not a truncated bitmap. The failure mode being refused is an allocator
    /// whose `total` describes a machine and whose storage describes part of
    /// one, which nothing downstream can detect.
    #[test]
    fn a_placement_outside_every_region_is_an_error() {
        let map = map_of(&[(RAM, 0x10_0000)], &[]);
        // A floor beyond the end of the only region.
        assert_eq!(
            bitmap_placement(&map, FS, RAM + 0x20_0000).unwrap_err(),
            Error::BitmapOutsideRegions
        );
        // A floor near enough the end that the bitmap starts strictly inside the
        // region and ends past it — the case a check on the base alone lets
        // through. 65,536 frames need two frames of bitmap, so the placement is
        // longer than the one frame left above the floor.
        let big = map_of(&[(RAM, 0x1000_0000)], &[]);
        assert_eq!(
            bitmap_placement(&big, FS, RAM + 0x0FFF_F000).unwrap_err(),
            Error::BitmapOutsideRegions
        );
        // One frame lower, the same bitmap fits.
        assert_eq!(
            bitmap_placement(&big, FS, RAM + 0x0FFF_E000).unwrap().len,
            8192
        );
    }

    /// A bitmap that would land on memory already spoken for is a typed error.
    #[test]
    fn a_placement_overlapping_a_reservation_is_an_error() {
        let map = map_of(&[(RAM, 0x10_0000)], &[(RAM + 0x1_4800, 8)]);
        assert_eq!(
            bitmap_placement(&map, FS, RAM + 0x1_3360).unwrap_err(),
            Error::BitmapOverlapsReservation
        );
        // One byte lower and it fits: the check is an overlap and not a
        // proximity rule.
        let map = map_of(&[(RAM, 0x10_0000)], &[(RAM + 0x1_3fff, 1)]);
        assert_eq!(bitmap_placement(&map, FS, RAM + 0x1_3360).unwrap().base, RAM + 0x1_4000);
    }

    /// A bitmap too short for the frame count is refused.
    #[test]
    fn a_bitmap_shorter_than_the_frame_count_is_an_error() {
        let map = map_of(&[(RAM, 0x0080_0000)], &[]); // 2048 frames, 256 bytes
        // SAFETY: fresh leaked storage this test owns; see `allocator`.
        let err = unsafe { FrameAllocator::new(&map, bitmap(255), FS) }.err().unwrap();
        assert_eq!(err, Error::BitmapTooSmall);
        // SAFETY: as above.
        let a = unsafe { FrameAllocator::new(&map, bitmap(256), FS) }.unwrap();
        assert_eq!(a.total(), 2048);
    }

    /// The bitmap's own frames are never handed out.
    ///
    /// This is the boot path's sequence in miniature: size the bitmap, add it to
    /// the reservations, then construct. Skipping the middle step is the
    /// mistake — the allocator hands out its own storage, corrupts itself on the
    /// first write, and raises no fault on the way.
    #[test]
    fn the_bitmap_is_not_handed_out() {
        let regions = [(RAM, 0x0080_0000)];
        let mut map = map_of(&regions, &[(RAM, 0x1_4000)]); // a stand-in kernel image
        let place = bitmap_placement(&map, FS, RAM + 0x1_4000).unwrap();
        map.push_reserved(place).unwrap();

        // SAFETY: fresh leaked storage this test owns; see `allocator`.
        let mut a = unsafe { FrameAllocator::new(&map, bitmap(place.len as usize), FS) }.unwrap();
        for f in drain(&mut a) {
            let base = a.frame_base(&f);
            assert!(
                base < place.base || base >= place.base + place.len,
                "frame at {base:#x} is inside the bitmap"
            );
        }
    }

    /// A frame size that is not a usable one is refused at the door.
    #[test]
    fn a_frame_size_that_is_not_a_power_of_two_is_an_error() {
        let map = map_of(&[(RAM, 0x10000)], &[]);
        assert_eq!(
            bitmap_placement(&map, 3000, 0).unwrap_err(),
            Error::BadFrameSize
        );
        assert_eq!(bitmap_placement(&map, 0, 0).unwrap_err(), Error::BadFrameSize);
        // SAFETY: fresh leaked storage this test owns; see `allocator`.
        let err = unsafe { FrameAllocator::new(&map, bitmap(16), 0) }.err().unwrap();
        assert_eq!(err, Error::BadFrameSize);
    }

    // -----------------------------------------------------------------------
    // End to end, from bytes a compiler produced
    // -----------------------------------------------------------------------

    /// The reservation block's terminator never becomes a reservation.
    ///
    /// The second half of `a_zero_length_reservation_reserves_nothing`, taken
    /// through the whole pipeline instead of a hand-built map: real blob bytes,
    /// `fdt::parse`, then an allocator over what came out. The blob's
    /// reservation block is exactly one `(0, 0)` pair, and what the allocator
    /// must see is *no* entries — not one entry of length zero that it then has
    /// to skip.
    ///
    /// The bytes are `dtc` 1.7.2's output (`dtc -I dts -O dtb`) for the source
    /// quoted below, the same fixture `crate::fdt`'s tests are anchored to. It
    /// is duplicated here rather than shared because that module's fixtures are
    /// private to it and this task may not widen them; the assertions below pin
    /// what these bytes mean, so a drift shows up as a failure here and not as a
    /// silently different tree.
    ///
    /// // /dts-v1/;
    /// // / {
    /// //     #address-cells = <1>;
    /// //     #size-cells = <1>;
    /// //     memory@40000000 {
    /// //         device_type = "memory";
    /// //         reg = <0x40000000 0x08000000>;
    /// //     };
    /// // };
    #[test]
    fn the_terminator_never_reaches_the_allocator() {
        const BLOB: [u8; 211] = [
            0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x00, 0xd3, 0x00, 0x00, 0x00, 0x38,
            0x00, 0x00, 0x00, 0xa8, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11,
            0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2b,
            0x00, 0x00, 0x00, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03,
            0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x40, 0x34,
            0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00, 0x03,
            0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x1b, 0x6d, 0x65, 0x6d, 0x6f,
            0x72, 0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x08,
            0x00, 0x00, 0x00, 0x27, 0x40, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x09,
            0x23, 0x61, 0x64, 0x64, 0x72, 0x65, 0x73, 0x73, 0x2d, 0x63, 0x65, 0x6c,
            0x6c, 0x73, 0x00, 0x23, 0x73, 0x69, 0x7a, 0x65, 0x2d, 0x63, 0x65, 0x6c,
            0x6c, 0x73, 0x00, 0x64, 0x65, 0x76, 0x69, 0x63, 0x65, 0x5f, 0x74, 0x79,
            0x70, 0x65, 0x00, 0x72, 0x65, 0x67, 0x00,
        ];

        let map = crate::fdt::parse(&BLOB).unwrap();
        assert_eq!(
            map.regions(),
            &[Region {
                base: 0x4000_0000,
                len: 0x0800_0000
            }]
        );
        assert!(
            map.reserved().is_empty(),
            "the terminator was recorded as an entry"
        );

        let a = allocator(&map);
        assert_eq!(a.total(), 32768);
        assert_eq!(a.available(), 32768);
    }
}
