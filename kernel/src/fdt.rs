// SPDX-License-Identifier: GPL-3.0-or-later

//! A reader for flattened device tree blobs, which extracts exactly two things.
//!
//! Portable, and portable on purpose rather than by accident: a flattened device
//! tree is a data format, not an architecture. Nothing here names a register, an
//! instruction, a target or a board. It takes a byte slice and returns either a
//! [`MemoryMap`] or an [`Error`], and it does neither of the two things a kernel
//! parser must never do to hostile input — it does not read outside the slice,
//! and it does not panic.
//!
//! # What it reads, and nothing else
//!
//! 1. Every entry of the memory reservation block.
//! 2. Every node whose `device_type` is `"memory"`, and that node's `reg`,
//!    decoded with the **root node's** `#address-cells` and `#size-cells` read
//!    from the blob rather than assumed.
//!
//! Paths, phandles, interrupts, clocks, `/chosen`, `/reserved-memory`, initrd,
//! any version below 17, and anything that writes are named non-goals of
//! RFC-0003. A device tree interface that grows one accessor per caller is how
//! a bootstrap parser becomes a device model.
//!
//! # Against what the format was checked
//!
//! Devicetree Specification **v0.4** (13 May 2023), sections 5.1 (`fdt_header`),
//! 5.2 (memory reservation block), 5.3 (structure block) and 5.4 (strings
//! block), plus 3.4 (`/memory` node) and 2.3.5 (`#address-cells` /
//! `#size-cells`). Every constant, field order and encoding rule below carries
//! the clause it came from. RFC-0003 section 2 had checked the same list against
//! one producer's blob — agreement with a producer is not agreement with the
//! standard, and closing that gap is this file's job.
//!
//! Independently of the specification, the two good-blob fixtures in the test
//! module are the byte-for-byte output of `dtc` 1.7.2 for the `.dts` sources
//! quoted beside them, so the encoding this parser accepts is also the encoding
//! a real compiler emits.
//!
//! # Arithmetic
//!
//! `overflow-checks = true` is on in release. An unchecked add on a malformed
//! header would therefore panic, and a panic is the marker that means the kernel
//! has a bug — which is the wrong thing to say about a bad blob. So: every value
//! this file reads out of the blob is a `u32` widened to `u64` before it is used
//! in arithmetic, which makes any sum of two of them unrepresentable-overflow-
//! free by construction, and every remaining addition is `checked_add`. Slice
//! offsets are computed in `u64` and narrowed to `usize` only after the bound
//! against the slice has been proved.

use crate::hal::{MemoryMap, Region};

/// The largest blob this kernel will read.
///
/// QEMU virt's is exactly 1 MiB at every RAM size measured; this is twice that.
/// A `totalsize` above it is rejected rather than parsed — not because a larger
/// tree is illegitimate, but because the kernel has no way to bound the blob
/// against RAM it has not discovered yet.
///
/// It lives here and not in a platform module because it is a statement about
/// how much input this parser is willing to read, not a fact about a board.
pub const MAX_BLOB_LEN: u64 = 0x0020_0000;

/// The deepest node nesting this parser will follow.
///
/// A recursive descent over external input, in a kernel whose stack has no guard
/// page, is a stack overflow with an attacker choosing the depth. This parser is
/// iterative, so depth costs it a `u32` and not a frame — but a bound is still
/// worth having, because a blob that claims a depth of four billion is a blob
/// nobody should be trying to read.
const MAX_DEPTH: u32 = 32;

/// `fdt_header.magic`. Devicetree Specification v0.4 section 5.2.
const FDT_MAGIC: u32 = 0xd00d_feed;

/// The size of `fdt_header`: ten big-endian `u32`s. Section 5.2.
const HEADER_LEN: u64 = 40;

/// The only structure-block format this parser understands. Section 5.2 makes
/// `size_dt_struct` a version 17 field, and this parser needs it, so a blob that
/// predates it is rejected rather than guessed at.
const SUPPORTED_VERSION: u32 = 17;

// Structure block tokens. Devicetree Specification v0.4 section 5.4.1, which
// gives these five values and states that any other token value in a structure
// block makes the blob invalid.
const FDT_BEGIN_NODE: u32 = 0x0000_0001;
const FDT_END_NODE: u32 = 0x0000_0002;
const FDT_PROP: u32 = 0x0000_0003;
const FDT_NOP: u32 = 0x0000_0004;
const FDT_END: u32 = 0x0000_0009;

/// A memory reservation entry: two big-endian `u64`s. Section 5.3.
const RSV_ENTRY_LEN: u64 = 16;

/// Every token is a big-endian `u32` and the structure block is 4-byte aligned
/// throughout. Section 5.4.1.
const TOKEN_LEN: u64 = 4;

/// A cell is 32 bits. Section 2.2.4.
const CELL_LEN: u64 = 4;

/// `#address-cells` where the root node does not say. Section 2.3.5 gives the
/// defaults as 2 for addresses and 1 for sizes, and notes that relying on them
/// is discouraged — which is a statement about tree authors, not about readers.
const DEFAULT_ADDRESS_CELLS: u32 = 2;
/// `#size-cells` where the root node does not say. Section 2.3.5.
const DEFAULT_SIZE_CELLS: u32 = 1;

/// The property naming a node's kind. Section 2.3.4; section 3.4 requires
/// `device_type = "memory"` on a memory node.
const PROP_DEVICE_TYPE: &[u8] = b"device_type";
/// Section 3.4: the memory node's address and size list.
const PROP_REG: &[u8] = b"reg";
/// Section 2.3.5.
const PROP_ADDRESS_CELLS: &[u8] = b"#address-cells";
/// Section 2.3.5.
const PROP_SIZE_CELLS: &[u8] = b"#size-cells";
/// The `device_type` value that marks a memory node. Section 3.4.
const DEVICE_TYPE_MEMORY: &[u8] = b"memory";

/// Why a blob could not be turned into a [`MemoryMap`].
///
/// One variant per diagnosis rather than a single `Malformed`. The boot path
/// prints a fixed string chosen from this, and "the blob is bad" sends whoever
/// reads the console looking everywhere; "the reservation block never
/// terminates" sends them to one place.
#[derive(Clone, Copy, PartialEq, Eq)]
#[cfg_attr(test, derive(Debug))]
pub enum Error {
    /// Fewer than 40 bytes were given, so there is not even a header to check.
    HeaderTruncated,
    /// `magic` is not `0xd00dfeed`.
    BadMagic,
    /// `totalsize` is smaller than the header it is part of.
    TotalSizeTooSmall,
    /// `totalsize` exceeds [`MAX_BLOB_LEN`].
    TotalSizeTooLarge,
    /// `totalsize` exceeds the slice the caller provided.
    TotalSizeBeyondBlob,
    /// `version` is below 17.
    UnsupportedVersion,
    /// `last_comp_version` is above 17, so the producer says a version 17 reader
    /// cannot read this blob.
    UnsupportedCompatibleVersion,
    /// `off_dt_struct` is not 4-byte aligned.
    MisalignedStructBlock,
    /// `off_mem_rsvmap` is not 8-byte aligned.
    MisalignedReservations,
    /// `off_dt_struct + size_dt_struct` runs past `totalsize`.
    StructBlockOutOfBounds,
    /// `off_dt_strings + size_dt_strings` runs past `totalsize`.
    StringsBlockOutOfBounds,
    /// `off_mem_rsvmap` runs past `totalsize`.
    ReservationsOutOfBounds,
    /// The reservation block reaches the end of the blob with no `(0, 0)` pair.
    ReservationsUnterminated,
    /// More reservation entries than [`crate::hal::MAX_RESERVED`].
    TooManyReservations,
    /// A node name, property header or property body runs past the structure
    /// block.
    StructTruncated,
    /// The structure block ends without an `FDT_END` token.
    StructEndMissing,
    /// A token value that is none of the five the specification defines.
    UnknownToken,
    /// A node name with no terminating NUL inside the structure block.
    NodeNameUnterminated,
    /// `FDT_END` was reached with nodes still open.
    NodeUnterminated,
    /// `FDT_END_NODE` outside any node.
    UnbalancedEndNode,
    /// Node nesting deeper than [`MAX_DEPTH`].
    TooDeep,
    /// A property's `nameoff` points outside the strings block.
    NameOffsetOutOfBounds,
    /// A property name with no terminating NUL inside the strings block.
    NameUnterminated,
    /// `#address-cells` or `#size-cells` is not a single cell.
    MalformedCellCount,
    /// `#address-cells` or `#size-cells` is zero or above two — an address or a
    /// length this kernel cannot represent. Truncating it silently is how a
    /// parser hands out memory that does not exist.
    UnsupportedCellCount,
    /// A memory node's `reg` is empty, or is not a whole number of
    /// (address, size) pairs of the root's cell widths.
    MalformedReg,
    /// More memory regions than [`crate::hal::MAX_REGIONS`].
    TooManyRegions,
}

/// Turn the bytes of a flattened device tree into a [`MemoryMap`].
///
/// `blob` may be longer than the tree; `totalsize` decides where the tree ends,
/// and nothing past it is read. The blob is not retained: everything the caller
/// gets back is copied out by value, so the memory holding the tree can be
/// reclaimed the moment this returns.
pub fn parse(blob: &[u8]) -> Result<MemoryMap, Error> {
    let header = Header::read(blob)?;
    let mut map = MemoryMap::empty();
    read_reservations(blob, &header, &mut map)?;
    Walk::new(map).run(blob, &header)
}

// ---------------------------------------------------------------------------
// Bounded reads
//
// The only three functions in this file that index the blob. Everything else
// goes through them, which is what makes "no read leaves the slice" a property
// of three functions rather than of every line.
// ---------------------------------------------------------------------------

/// `blob[off .. off + len]`, or `None` if any of that lies outside the slice.
fn slice_at(blob: &[u8], off: u64, len: u64) -> Option<&[u8]> {
    let end = off.checked_add(len)?;
    if end > blob.len() as u64 {
        return None;
    }
    // Narrowing is lossless: both are now proved to be at most `blob.len()`,
    // which came from a `usize`. This is the only place either becomes one.
    Some(&blob[off as usize..end as usize])
}

/// A big-endian `u32` at `off`, or `None` if it does not fit in the slice.
///
/// `from_be_bytes` on a copied array, never a cast to `*const u32`: the blob is
/// a byte slice with no alignment guarantee, and the target this kernel runs on
/// is `+strict-align` with the MMU off, where an unaligned load faults. A host
/// test cannot catch a violation of that, which is why it is a rule here rather
/// than something to be discovered later.
fn be_u32_at(blob: &[u8], off: u64) -> Option<u32> {
    let bytes: [u8; 4] = slice_at(blob, off, 4)?.try_into().ok()?;
    Some(u32::from_be_bytes(bytes))
}

/// A big-endian `u64` at `off`, or `None` if it does not fit in the slice.
fn be_u64_at(blob: &[u8], off: u64) -> Option<u64> {
    let bytes: [u8; 8] = slice_at(blob, off, 8)?.try_into().ok()?;
    Some(u64::from_be_bytes(bytes))
}

/// Round up to the next multiple of four.
///
/// Structure block content is padded to a 4-byte boundary after node names and
/// after property values. Section 5.4.1.
fn align_up_4(value: u64) -> Option<u64> {
    Some(value.checked_add(3)? & !3)
}

// ---------------------------------------------------------------------------
// The header
// ---------------------------------------------------------------------------

/// The five header fields this parser uses, validated.
///
/// `boot_cpuid_phys` is read past and not kept: nothing here is about which CPU
/// booted. `magic`, `version` and `last_comp_version` are checked and discarded.
struct Header {
    totalsize: u64,
    off_dt_struct: u64,
    off_dt_strings: u64,
    off_mem_rsvmap: u64,
    size_dt_strings: u64,
    size_dt_struct: u64,
}

impl Header {
    /// Field offsets, in the order Devicetree Specification v0.4 section 5.2
    /// gives them: `magic`, `totalsize`, `off_dt_struct`, `off_dt_strings`,
    /// `off_mem_rsvmap`, `version`, `last_comp_version`, `boot_cpuid_phys`,
    /// `size_dt_strings`, `size_dt_struct`. The order matters and getting it
    /// wrong produces a parser that works on one producer's blob by luck, so it
    /// is spelled out rather than counted in the head.
    fn read(blob: &[u8]) -> Result<Self, Error> {
        // One bound for the whole header, so the ten reads below cannot each be
        // a separate opportunity to get it wrong.
        let head: [u8; HEADER_LEN as usize] = match slice_at(blob, 0, HEADER_LEN) {
            Some(bytes) => match bytes.try_into() {
                Ok(array) => array,
                Err(_) => return Err(Error::HeaderTruncated),
            },
            None => return Err(Error::HeaderTruncated),
        };
        // `i` is a field index, 0 through 9, and 9 * 4 + 4 == HEADER_LEN.
        let field = |i: usize| -> u64 {
            u32::from_be_bytes([head[i * 4], head[i * 4 + 1], head[i * 4 + 2], head[i * 4 + 3]])
                as u64
        };

        let magic = field(0) as u32;
        if magic != FDT_MAGIC {
            return Err(Error::BadMagic);
        }

        let totalsize = field(1);
        if totalsize < HEADER_LEN {
            return Err(Error::TotalSizeTooSmall);
        }
        if totalsize > MAX_BLOB_LEN {
            return Err(Error::TotalSizeTooLarge);
        }
        if totalsize > blob.len() as u64 {
            return Err(Error::TotalSizeBeyondBlob);
        }

        // Checked before the offsets are used, because a version below 17 has no
        // `size_dt_struct` and whatever is at that offset is another field.
        let version = field(5) as u32;
        if version < SUPPORTED_VERSION {
            return Err(Error::UnsupportedVersion);
        }
        let last_comp_version = field(6) as u32;
        if last_comp_version > SUPPORTED_VERSION {
            return Err(Error::UnsupportedCompatibleVersion);
        }

        let off_dt_struct = field(2);
        let off_dt_strings = field(3);
        let off_mem_rsvmap = field(4);
        let size_dt_strings = field(8);
        let size_dt_struct = field(9);

        // Alignment before extent, so that an offset that is both misaligned and
        // out of range reports the misalignment — the more specific fault, and
        // the one that names a producer bug rather than a truncation.
        //
        // Section 5.2 requires the structure block to be 4-byte aligned and the
        // memory reservation block to be 8-byte aligned. Both matter to this
        // kernel beyond conformance: it reads `u64`s out of the reservation
        // block, and on the target it runs on an unaligned load faults.
        if !off_dt_struct.is_multiple_of(4) {
            return Err(Error::MisalignedStructBlock);
        }
        if !off_mem_rsvmap.is_multiple_of(8) {
            return Err(Error::MisalignedReservations);
        }

        // Neither sum can overflow: both terms are `u32`s widened to `u64`.
        if off_dt_struct + size_dt_struct > totalsize {
            return Err(Error::StructBlockOutOfBounds);
        }
        if off_dt_strings + size_dt_strings > totalsize {
            return Err(Error::StringsBlockOutOfBounds);
        }
        if off_mem_rsvmap > totalsize {
            return Err(Error::ReservationsOutOfBounds);
        }

        Ok(Self {
            totalsize,
            off_dt_struct,
            off_dt_strings,
            off_mem_rsvmap,
            size_dt_strings,
            size_dt_struct,
        })
    }

    /// One past the last byte of the structure block.
    ///
    /// Proved not to overflow and not to exceed `totalsize` by [`Header::read`].
    fn struct_end(&self) -> u64 {
        self.off_dt_struct + self.size_dt_struct
    }

    /// The NUL-terminated name at `nameoff` in the strings block. Section 5.5.
    fn name<'a>(&self, blob: &'a [u8], nameoff: u64) -> Result<&'a [u8], Error> {
        if nameoff >= self.size_dt_strings {
            return Err(Error::NameOffsetOutOfBounds);
        }
        let start = self.off_dt_strings + nameoff; // both are widened `u32`s
        let available = self.size_dt_strings - nameoff; // proved positive above
        let tail = slice_at(blob, start, available).ok_or(Error::StringsBlockOutOfBounds)?;
        match tail.iter().position(|&b| b == 0) {
            Some(n) => Ok(&tail[..n]),
            None => Err(Error::NameUnterminated),
        }
    }
}

// ---------------------------------------------------------------------------
// The memory reservation block
// ---------------------------------------------------------------------------

/// Read every reservation entry into `map`.
///
/// Section 5.3: pairs of big-endian `u64`s — address then size — terminated by a
/// pair in which both are zero. An entry whose size is zero reserves nothing and
/// is skipped; it is *not* a terminator, because the terminator is defined by
/// both fields being zero and not by the size alone. Those are two readings of
/// the same sixteen bytes and the difference is a reservation silently dropped.
///
/// Terminates: `off` rises by exactly [`RSV_ENTRY_LEN`] each iteration and the
/// loop exits as soon as it can no longer fit an entry below `totalsize`.
fn read_reservations(blob: &[u8], header: &Header, map: &mut MemoryMap) -> Result<(), Error> {
    let mut off = header.off_mem_rsvmap;
    loop {
        let next = off
            .checked_add(RSV_ENTRY_LEN)
            .ok_or(Error::ReservationsUnterminated)?;
        if next > header.totalsize {
            return Err(Error::ReservationsUnterminated);
        }
        let base = be_u64_at(blob, off).ok_or(Error::ReservationsOutOfBounds)?;
        let len = be_u64_at(blob, off + 8).ok_or(Error::ReservationsOutOfBounds)?;
        off = next;

        if base == 0 && len == 0 {
            return Ok(());
        }
        if len == 0 {
            continue;
        }
        map.push_reserved(Region { base, len })
            .map_err(|_| Error::TooManyReservations)?;
    }
}

// ---------------------------------------------------------------------------
// The structure block
// ---------------------------------------------------------------------------

/// The whole of the parser's state while it walks the structure block.
///
/// A struct rather than seven locals so that the two places a node has to be
/// closed out can share one piece of code without either of them being a
/// recursive call. Nothing here holds a reference to the blob.
struct Walk {
    /// How many nodes are open. The root is depth 1.
    depth: u32,
    /// `#address-cells` as the root node stated it, if it did.
    root_address_cells: Option<u32>,
    /// `#size-cells` as the root node stated it, if it did.
    root_size_cells: Option<u32>,
    /// The widths every `reg` is decoded with, fixed when the root node's
    /// property list ends and never revisited.
    cells: Option<(u64, u64)>,
    /// Whether the innermost node's property list is still being read.
    node_open: bool,
    /// Whether that node said `device_type = "memory"`.
    node_is_memory: bool,
    /// Where that node's `reg` body is, as (offset, length) into the blob.
    node_reg: Option<(u64, u64)>,
    map: MemoryMap,
}

impl Walk {
    fn new(map: MemoryMap) -> Self {
        Self {
            depth: 0,
            root_address_cells: None,
            root_size_cells: None,
            cells: None,
            // Nothing is open before the first token, so the first close is a
            // no-op rather than a special case in the loop.
            node_open: false,
            node_is_memory: false,
            node_reg: None,
            map,
        }
    }

    /// Walk the structure block from `off_dt_struct` to `FDT_END`.
    ///
    /// Iterative, and terminating for the same reason in every branch: each turn
    /// of the loop consumes at least one four-byte token, `off` never decreases,
    /// and the loop stops the moment `off` cannot fit another token below
    /// `struct_end`. A malformed blob therefore cannot produce a hang, which is
    /// the one failure CI cannot tell apart from a hardware fault.
    fn run(mut self, blob: &[u8], header: &Header) -> Result<MemoryMap, Error> {
        let end = header.struct_end();
        let mut off = header.off_dt_struct;

        loop {
            if off + TOKEN_LEN > end {
                // `off` is bounded by `end`, itself bounded by `totalsize`, so
                // the add cannot overflow.
                return Err(Error::StructEndMissing);
            }
            let token = be_u32_at(blob, off).ok_or(Error::StructTruncated)?;
            off += TOKEN_LEN;

            match token {
                // Section 5.4.1: the token is followed by the node's name as a
                // NUL-terminated string, padded with zeroes to a 4-byte
                // boundary.
                FDT_BEGIN_NODE => {
                    self.close_node(blob)?;
                    self.depth += 1; // bounded below, and by `end` regardless
                    if self.depth > MAX_DEPTH {
                        return Err(Error::TooDeep);
                    }
                    self.node_open = true;
                    self.node_is_memory = false;
                    self.node_reg = None;
                    off = skip_node_name(blob, off, end)?;
                }

                // Section 5.4.1: `len` then `nameoff`, in that order, then `len`
                // bytes of value padded to a 4-byte boundary. The order of those
                // two words is the one thing here that a reader cannot recover
                // from getting backwards, because both are plausible.
                FDT_PROP => {
                    if off + 8 > end {
                        return Err(Error::StructTruncated);
                    }
                    let len = be_u32_at(blob, off).ok_or(Error::StructTruncated)? as u64;
                    let nameoff = be_u32_at(blob, off + 4).ok_or(Error::StructTruncated)? as u64;
                    off += 8;

                    // Bound the body against the structure block, not merely
                    // against the slice: a `len` that reaches into the strings
                    // block is malformed even though the bytes exist.
                    //
                    // This bound and the one after the padding below are
                    // redundant — removing either alone leaves the other
                    // rejecting the same blobs with the same error, which a
                    // mutation run confirmed. Both are kept because they are not
                    // redundant in what they permit in between: without this
                    // one, `body` would be handed to `take_property` containing
                    // strings-block bytes, and a later reader who moves the
                    // padding check would inherit that quietly.
                    let body_end = off + len; // widened `u32`s, cannot overflow
                    if body_end > end {
                        return Err(Error::StructTruncated);
                    }
                    let body = slice_at(blob, off, len).ok_or(Error::StructTruncated)?;
                    self.take_property(header.name(blob, nameoff)?, off, len, body)?;
                    off = align_up_4(body_end).ok_or(Error::StructTruncated)?;
                    if off > end {
                        return Err(Error::StructTruncated);
                    }
                }

                FDT_END_NODE => {
                    self.close_node(blob)?;
                    if self.depth == 0 {
                        return Err(Error::UnbalancedEndNode);
                    }
                    self.depth -= 1;
                    // The enclosing node's property list ended when this one
                    // began, so there is nothing of it left to close.
                    self.node_open = false;
                    self.node_is_memory = false;
                    self.node_reg = None;
                }

                FDT_NOP => {}

                FDT_END => {
                    if self.depth != 0 {
                        return Err(Error::NodeUnterminated);
                    }
                    return Ok(self.map);
                }

                _ => return Err(Error::UnknownToken),
            }
        }
    }

    /// Record one property of the node currently being read.
    fn take_property(
        &mut self,
        name: &[u8],
        body_off: u64,
        body_len: u64,
        body: &[u8],
    ) -> Result<(), Error> {
        match name {
            PROP_DEVICE_TYPE => {
                // Section 2.3.4 makes this a `string`, so the value includes its
                // NUL. Accepting the value without one as well costs nothing and
                // means a producer that omits it is read rather than ignored.
                let value = match body.split_last() {
                    Some((0, head)) => head,
                    _ => body,
                };
                self.node_is_memory = value == DEVICE_TYPE_MEMORY;
            }
            PROP_REG => self.node_reg = Some((body_off, body_len)),
            PROP_ADDRESS_CELLS if self.depth == 1 => {
                self.root_address_cells = Some(single_cell(body)?);
            }
            PROP_SIZE_CELLS if self.depth == 1 => {
                self.root_size_cells = Some(single_cell(body)?);
            }
            _ => {}
        }
        Ok(())
    }

    /// End the innermost node's property list, and emit its region if it had one.
    ///
    /// Called from exactly two places — a child node beginning, and this node
    /// ending — which between them are every way a node's property list can end.
    /// That is what makes it safe to decode `reg` here rather than the moment the
    /// property is seen: the root node's `#address-cells` and `#size-cells` are
    /// final by the time any node's list closes, including the root's own, so no
    /// `reg` is ever decoded with a width the blob had not yet stated.
    ///
    /// It is also why the parser needs no per-depth stack. The only state a
    /// closed node leaves behind is in `self.map`.
    fn close_node(&mut self, blob: &[u8]) -> Result<(), Error> {
        if !self.node_open {
            return Ok(());
        }
        self.node_open = false;

        if self.depth == 1 && self.cells.is_none() {
            let address_cells = self.root_address_cells.unwrap_or(DEFAULT_ADDRESS_CELLS);
            let size_cells = self.root_size_cells.unwrap_or(DEFAULT_SIZE_CELLS);
            // Zero is rejected alongside "above two" for the same reason: a
            // width of zero describes an address or a length that is not there,
            // and a memory region missing either is not a memory region.
            if address_cells == 0 || address_cells > 2 || size_cells == 0 || size_cells > 2 {
                return Err(Error::UnsupportedCellCount);
            }
            self.cells = Some((address_cells as u64, size_cells as u64));
        }

        if !self.node_is_memory {
            return Ok(());
        }
        let (off, len) = match self.node_reg {
            Some(reg) => reg,
            // A memory node with no `reg` describes nothing. Section 3.4 requires
            // one, but a tree that omits it is simply silent about memory rather
            // than wrong about it, so it is skipped and not an error.
            None => return Ok(()),
        };
        let (address_cells, size_cells) = match self.cells {
            Some(cells) => cells,
            // Unreachable: `cells` is set above before this point is reached for
            // any node at depth 1 or deeper, and there is no depth 0 node. An
            // error rather than an `unwrap`, because "unreachable" is a claim
            // about today's control flow and a panic is a kernel bug marker.
            None => return Err(Error::MalformedReg),
        };

        // At most (2 + 2) * 4 == 16, so no overflow and no division by zero.
        let entry_len = (address_cells + size_cells) * CELL_LEN;
        if len == 0 || !len.is_multiple_of(entry_len) {
            return Err(Error::MalformedReg);
        }

        let mut at = off;
        let stop = off + len; // bounded by the structure block
        while at < stop {
            let base = read_cells(blob, at, address_cells)?;
            let size = read_cells(blob, at + address_cells * CELL_LEN, size_cells)?;
            at += entry_len;
            self.map
                .push_region(Region { base, len: size })
                .map_err(|_| Error::TooManyRegions)?;
        }
        Ok(())
    }
}

/// The value of a `#address-cells` or `#size-cells` property.
///
/// Section 2.3.5 makes both a single `u32`. A property of any other length is a
/// producer bug, and reading the first four bytes of it anyway would be a reader
/// deciding what the producer meant.
fn single_cell(body: &[u8]) -> Result<u32, Error> {
    let bytes: [u8; 4] = body.try_into().map_err(|_| Error::MalformedCellCount)?;
    Ok(u32::from_be_bytes(bytes))
}

/// One address or one size out of a `reg`, `cells` cells wide.
fn read_cells(blob: &[u8], off: u64, cells: u64) -> Result<u64, Error> {
    match cells {
        1 => be_u32_at(blob, off)
            .map(u64::from)
            .ok_or(Error::MalformedReg),
        2 => be_u64_at(blob, off).ok_or(Error::MalformedReg),
        // Unreachable: `close_node` rejects anything else before calling this.
        _ => Err(Error::UnsupportedCellCount),
    }
}

/// Step over the NUL-terminated, 4-byte-padded node name at `off`.
///
/// Section 5.4.1. Returns the offset of the next token.
fn skip_node_name(blob: &[u8], off: u64, end: u64) -> Result<u64, Error> {
    let available = end.checked_sub(off).ok_or(Error::StructTruncated)?;
    let tail = slice_at(blob, off, available).ok_or(Error::StructTruncated)?;
    let nul = tail
        .iter()
        .position(|&b| b == 0)
        .ok_or(Error::NodeNameUnterminated)?;
    // `nul` indexes into a slice shorter than the structure block, so widening
    // it and adding one cannot overflow.
    let next = align_up_4(off + nul as u64 + 1).ok_or(Error::StructTruncated)?;
    if next > end {
        return Err(Error::StructTruncated);
    }
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hal::{MAX_REGIONS, MAX_RESERVED};

    /// The region both fixtures below describe, whatever the cell widths.
    const EXPECTED: Region = Region {
        base: 0x4000_0000,
        len: 0x0800_0000,
    };

    // -----------------------------------------------------------------------
    // Bytes a real tool produced
    //
    // `dtc` 1.7.2 (Fedora 44, dtc-1.7.2-9.fc44), `dtc -I dts -O dtb`, on the two
    // sources quoted below. They are literals rather than files so that a
    // fixture cannot drift without the diff showing it, and so that a test run
    // needs nothing on disk.
    //
    // Testing against a compiler's output, and not only against the builder
    // further down, is the point: a parser checked solely against its author's
    // own encoder is a parser checked against itself. The builder is then pinned
    // to these bytes by `builder_reproduces_dtc_output`, which is what lets every
    // other fixture in this module inherit the same anchor.
    // -----------------------------------------------------------------------

    // /dts-v1/;
    // / {
    //     #address-cells = <1>;
    //     #size-cells = <1>;
    //     memory@40000000 {
    //         device_type = "memory";
    //         reg = <0x40000000 0x08000000>;
    //     };
    // };
    const DTC_CELLS_1_1: [u8; 211] = [
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

    // The same tree with two-cell addresses and two-cell sizes.
    //
    // /dts-v1/;
    // / {
    //     #address-cells = <2>;
    //     #size-cells = <2>;
    //     memory@40000000 {
    //         device_type = "memory";
    //         reg = <0x0 0x40000000 0x0 0x08000000>;
    //     };
    // };
    const DTC_CELLS_2_2: [u8; 219] = [
        0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x00, 0xdb, 0x00, 0x00, 0x00, 0x38,
        0x00, 0x00, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11,
        0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2b,
        0x00, 0x00, 0x00, 0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x01, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x40, 0x34,
        0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x1b, 0x6d, 0x65, 0x6d, 0x6f,
        0x72, 0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x10,
        0x00, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x09, 0x23, 0x61, 0x64, 0x64,
        0x72, 0x65, 0x73, 0x73, 0x2d, 0x63, 0x65, 0x6c, 0x6c, 0x73, 0x00, 0x23,
        0x73, 0x69, 0x7a, 0x65, 0x2d, 0x63, 0x65, 0x6c, 0x6c, 0x73, 0x00, 0x64,
        0x65, 0x76, 0x69, 0x63, 0x65, 0x5f, 0x74, 0x79, 0x70, 0x65, 0x00, 0x72,
        0x65, 0x67, 0x00,
    ];

    // -----------------------------------------------------------------------
    // A blob assembler
    //
    // Deliberately low level: it emits the tokens it is told to emit and checks
    // none of them, because most of what it is used for below is emitting blobs
    // no conforming producer would.
    // -----------------------------------------------------------------------

    struct Builder {
        reservations: Vec<(u64, u64)>,
        terminate_reservations: bool,
        structure: Vec<u8>,
        strings: Vec<u8>,
        interned: Vec<(String, u32)>,
    }

    impl Builder {
        fn new() -> Self {
            Self {
                reservations: Vec::new(),
                terminate_reservations: true,
                structure: Vec::new(),
                strings: Vec::new(),
                interned: Vec::new(),
            }
        }

        fn reserve(&mut self, base: u64, len: u64) -> &mut Self {
            self.reservations.push((base, len));
            self
        }

        fn token(&mut self, token: u32) -> &mut Self {
            self.structure.extend_from_slice(&token.to_be_bytes());
            self
        }

        fn begin_node(&mut self, name: &str) -> &mut Self {
            self.token(FDT_BEGIN_NODE);
            self.structure.extend_from_slice(name.as_bytes());
            self.structure.push(0);
            while !self.structure.len().is_multiple_of(4) {
                self.structure.push(0);
            }
            self
        }

        fn end_node(&mut self) -> &mut Self {
            self.token(FDT_END_NODE)
        }

        fn end(&mut self) -> &mut Self {
            self.token(FDT_END)
        }

        /// Intern a property name, first use first, which is the order dtc lays
        /// the strings block out in.
        fn intern(&mut self, name: &str) -> u32 {
            if let Some((_, off)) = self.interned.iter().find(|(n, _)| n == name) {
                return *off;
            }
            let off = self.strings.len() as u32;
            self.strings.extend_from_slice(name.as_bytes());
            self.strings.push(0);
            self.interned.push((name.to_string(), off));
            off
        }

        fn prop(&mut self, name: &str, body: &[u8]) -> &mut Self {
            let nameoff = self.intern(name);
            self.prop_raw(body.len() as u32, nameoff, body)
        }

        fn prop_u32(&mut self, name: &str, value: u32) -> &mut Self {
            self.prop(name, &value.to_be_bytes())
        }

        /// A property whose declared `len` and `nameoff` are whatever the caller
        /// says, however little sense that makes.
        fn prop_raw(&mut self, len: u32, nameoff: u32, body: &[u8]) -> &mut Self {
            self.token(FDT_PROP);
            self.structure.extend_from_slice(&len.to_be_bytes());
            self.structure.extend_from_slice(&nameoff.to_be_bytes());
            self.structure.extend_from_slice(body);
            while !self.structure.len().is_multiple_of(4) {
                self.structure.push(0);
            }
            self
        }

        fn build(&self) -> Vec<u8> {
            let mut rsv = Vec::new();
            for (base, len) in &self.reservations {
                rsv.extend_from_slice(&base.to_be_bytes());
                rsv.extend_from_slice(&len.to_be_bytes());
            }
            if self.terminate_reservations {
                rsv.extend_from_slice(&[0u8; RSV_ENTRY_LEN as usize]);
            }

            // 40 is 8-aligned and every entry is 16 bytes, so the structure
            // block lands 4-byte aligned whatever the reservation count.
            let off_mem_rsvmap = HEADER_LEN as u32;
            let off_dt_struct = off_mem_rsvmap + rsv.len() as u32;
            let size_dt_struct = self.structure.len() as u32;
            let off_dt_strings = off_dt_struct + size_dt_struct;
            let size_dt_strings = self.strings.len() as u32;
            let totalsize = off_dt_strings + size_dt_strings;

            let header = [
                FDT_MAGIC,
                totalsize,
                off_dt_struct,
                off_dt_strings,
                off_mem_rsvmap,
                SUPPORTED_VERSION,
                16, // last_comp_version, as dtc emits it
                0,  // boot_cpuid_phys
                size_dt_strings,
                size_dt_struct,
            ];

            let mut out = Vec::new();
            for word in header {
                out.extend_from_slice(&word.to_be_bytes());
            }
            out.extend_from_slice(&rsv);
            out.extend_from_slice(&self.structure);
            out.extend_from_slice(&self.strings);
            out
        }
    }

    /// `base` and `len` as a `reg` body of the given cell widths.
    fn reg_body(address_cells: u32, size_cells: u32, base: u64, len: u64) -> Vec<u8> {
        let mut out = Vec::new();
        let mut push = |cells: u32, value: u64| {
            if cells == 1 {
                out.extend_from_slice(&(value as u32).to_be_bytes());
            } else {
                out.extend_from_slice(&value.to_be_bytes());
            }
        };
        push(address_cells, base);
        push(size_cells, len);
        out
    }

    /// The tree the two dtc fixtures encode, at whatever cell widths.
    fn minimal(address_cells: u32, size_cells: u32) -> Builder {
        let mut b = Builder::new();
        b.begin_node("");
        b.prop_u32("#address-cells", address_cells);
        b.prop_u32("#size-cells", size_cells);
        b.begin_node("memory@40000000");
        b.prop("device_type", b"memory\0");
        b.prop(
            "reg",
            &reg_body(address_cells, size_cells, EXPECTED.base, EXPECTED.len),
        );
        b.end_node();
        b.end_node();
        b.end();
        b
    }

    /// Overwrite header field `index`, counting from `magic` at zero.
    fn set_field(blob: &mut [u8], index: usize, value: u32) {
        blob[index * 4..index * 4 + 4].copy_from_slice(&value.to_be_bytes());
    }

    fn field(blob: &[u8], index: usize) -> u32 {
        be_u32_at(blob, index as u64 * 4).unwrap()
    }

    fn err(blob: &[u8]) -> Error {
        parse(blob).err().expect("expected a typed error")
    }

    // -----------------------------------------------------------------------
    // The fixtures agree with a real tool
    // -----------------------------------------------------------------------

    #[test]
    fn builder_reproduces_dtc_output() {
        assert_eq!(minimal(1, 1).build(), DTC_CELLS_1_1.to_vec());
        assert_eq!(minimal(2, 2).build(), DTC_CELLS_2_2.to_vec());
    }

    // -----------------------------------------------------------------------
    // Well-formed input
    // -----------------------------------------------------------------------

    #[test]
    fn cell_widths_come_from_the_root_node() {
        // The same region, encoded two ways. A parser that assumed 2/2 would
        // read the 1/1 blob's four address bytes and four size bytes as the one
        // 64-bit address 0x40000000_08000000; a parser that assumed 1/1 would
        // read the 2/2 blob's address as 0. Neither assumption survives both.
        let one = parse(&DTC_CELLS_1_1).expect("1/1 blob must parse");
        assert_eq!(one.regions(), &[EXPECTED]);
        let two = parse(&DTC_CELLS_2_2).expect("2/2 blob must parse");
        assert_eq!(two.regions(), &[EXPECTED]);
    }

    #[test]
    fn cell_widths_may_be_mixed() {
        let blob = minimal(2, 1).build();
        assert_eq!(parse(&blob).unwrap().regions(), &[EXPECTED]);
    }

    #[test]
    fn absent_root_cells_take_the_specification_defaults() {
        // Devicetree Specification v0.4 section 2.3.5: two address cells, one
        // size cell. Encoded that way, with no property saying so.
        let mut b = Builder::new();
        b.begin_node("");
        b.begin_node("memory@40000000");
        b.prop("device_type", b"memory\0");
        b.prop("reg", &reg_body(2, 1, EXPECTED.base, EXPECTED.len));
        b.end_node();
        b.end_node();
        b.end();
        assert_eq!(parse(&b.build()).unwrap().regions(), &[EXPECTED]);
    }

    #[test]
    fn several_pairs_in_one_reg_become_several_regions() {
        let mut body = reg_body(1, 1, 0x4000_0000, 0x0800_0000);
        body.extend(reg_body(1, 1, 0x9000_0000, 0x1000_0000));
        let mut b = Builder::new();
        b.begin_node("");
        b.prop_u32("#address-cells", 1);
        b.prop_u32("#size-cells", 1);
        b.begin_node("memory@40000000");
        b.prop("device_type", b"memory\0");
        b.prop("reg", &body);
        b.end_node();
        b.end_node();
        b.end();
        assert_eq!(
            parse(&b.build()).unwrap().regions(),
            &[
                Region {
                    base: 0x4000_0000,
                    len: 0x0800_0000
                },
                Region {
                    base: 0x9000_0000,
                    len: 0x1000_0000
                },
            ]
        );
    }

    #[test]
    fn a_memory_node_nested_below_the_root_is_still_found() {
        let mut b = Builder::new();
        b.begin_node("");
        b.prop_u32("#address-cells", 1);
        b.prop_u32("#size-cells", 1);
        b.begin_node("soc");
        b.prop("compatible", b"simple-bus\0");
        b.begin_node("memory@40000000");
        b.prop("device_type", b"memory\0");
        b.prop("reg", &reg_body(1, 1, EXPECTED.base, EXPECTED.len));
        b.end_node();
        b.end_node();
        b.end_node();
        b.end();
        assert_eq!(parse(&b.build()).unwrap().regions(), &[EXPECTED]);
    }

    #[test]
    fn a_memory_node_with_a_child_still_reports_its_own_reg() {
        // The case that decides whether the parser needs a per-depth stack:
        // properties precede subnodes, so the node's own reg is decoded when its
        // property list ends, and a child cannot overwrite what was already read.
        let mut b = Builder::new();
        b.begin_node("");
        b.prop_u32("#address-cells", 1);
        b.prop_u32("#size-cells", 1);
        b.begin_node("memory@40000000");
        b.prop("device_type", b"memory\0");
        b.prop("reg", &reg_body(1, 1, EXPECTED.base, EXPECTED.len));
        b.begin_node("child");
        b.prop("compatible", b"nothing\0");
        b.end_node();
        b.end_node();
        b.end_node();
        b.end();
        assert_eq!(parse(&b.build()).unwrap().regions(), &[EXPECTED]);
    }

    #[test]
    fn a_tree_with_no_memory_node_yields_an_empty_map() {
        let mut b = Builder::new();
        b.begin_node("");
        b.prop_u32("#address-cells", 2);
        b.prop_u32("#size-cells", 2);
        b.begin_node("chosen");
        b.prop("bootargs", b"console=ttyAMA0\0");
        b.end_node();
        b.end_node();
        b.end();
        let map = parse(&b.build()).unwrap();
        assert!(map.regions().is_empty());
        assert!(map.reserved().is_empty());
    }

    #[test]
    fn nop_tokens_are_skipped() {
        let mut b = Builder::new();
        b.token(FDT_NOP);
        b.begin_node("");
        b.token(FDT_NOP);
        b.prop_u32("#address-cells", 1);
        b.prop_u32("#size-cells", 1);
        b.token(FDT_NOP);
        b.begin_node("memory@40000000");
        b.prop("device_type", b"memory\0");
        b.prop("reg", &reg_body(1, 1, EXPECTED.base, EXPECTED.len));
        b.token(FDT_NOP);
        b.end_node();
        b.end_node();
        b.token(FDT_NOP);
        b.end();
        assert_eq!(parse(&b.build()).unwrap().regions(), &[EXPECTED]);
    }

    #[test]
    fn nesting_of_exactly_thirty_two_is_accepted() {
        let mut b = Builder::new();
        for i in 0..MAX_DEPTH {
            b.begin_node(&format!("n{i}"));
        }
        for _ in 0..MAX_DEPTH {
            b.end_node();
        }
        b.end();
        assert!(parse(&b.build()).is_ok());
    }

    // -----------------------------------------------------------------------
    // The reservation block: two readings of the same sixteen bytes
    // -----------------------------------------------------------------------

    #[test]
    fn a_zero_length_entry_is_skipped_and_does_not_terminate_the_block() {
        let mut b = minimal(1, 1);
        b.reserve(0x8000_0000, 0);
        b.reserve(0x9000_0000, 0x1000);
        let map = parse(&b.build()).unwrap();
        // The second entry proves the first did not terminate the walk; the
        // first is absent because a zero-length reservation reserves nothing.
        assert_eq!(
            map.reserved(),
            &[Region {
                base: 0x9000_0000,
                len: 0x1000
            }]
        );
        assert_eq!(map.regions(), &[EXPECTED]);
    }

    #[test]
    fn the_zero_pair_terminates_the_block() {
        let mut b = minimal(1, 1);
        // A terminator, and behind it an entry that must never be seen.
        b.reserve(0, 0);
        b.reserve(0x9000_0000, 0x1000);
        assert!(parse(&b.build()).unwrap().reserved().is_empty());
    }

    #[test]
    fn reservations_are_reported() {
        let mut b = minimal(2, 2);
        b.reserve(0x4400_0000, 0x0010_0000);
        let map = parse(&b.build()).unwrap();
        assert_eq!(
            map.reserved(),
            &[Region {
                base: 0x4400_0000,
                len: 0x0010_0000
            }]
        );
    }

    // -----------------------------------------------------------------------
    // Malformed input. One typed error each, and no panic anywhere.
    // -----------------------------------------------------------------------

    #[test]
    fn truncated_blob() {
        assert_eq!(err(&[]), Error::HeaderTruncated);
        assert_eq!(
            err(&DTC_CELLS_1_1[..HEADER_LEN as usize - 1]),
            Error::HeaderTruncated
        );
    }

    #[test]
    fn bad_magic() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        set_field(&mut blob, 0, 0xdead_beef);
        assert_eq!(err(&blob), Error::BadMagic);
    }

    #[test]
    fn totalsize_below_the_header() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        set_field(&mut blob, 1, HEADER_LEN as u32 - 1);
        assert_eq!(err(&blob), Error::TotalSizeTooSmall);
    }

    #[test]
    fn totalsize_above_the_appetite_bound() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        set_field(&mut blob, 1, MAX_BLOB_LEN as u32 + 1);
        assert_eq!(err(&blob), Error::TotalSizeTooLarge);
    }

    #[test]
    fn totalsize_beyond_the_slice() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        let past_the_end = blob.len() as u32 + 1;
        set_field(&mut blob, 1, past_the_end);
        assert_eq!(err(&blob), Error::TotalSizeBeyondBlob);
    }

    #[test]
    fn version_below_seventeen() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        set_field(&mut blob, 5, SUPPORTED_VERSION - 1);
        assert_eq!(err(&blob), Error::UnsupportedVersion);
    }

    #[test]
    fn last_compatible_version_above_seventeen() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        set_field(&mut blob, 6, SUPPORTED_VERSION + 1);
        assert_eq!(err(&blob), Error::UnsupportedCompatibleVersion);
    }

    #[test]
    fn structure_block_past_totalsize() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        // Four bytes more structure block than there is room for between
        // off_dt_struct and the end of the blob.
        let grown = field(&blob, 1) - field(&blob, 2) + 4;
        set_field(&mut blob, 9, grown);
        assert_eq!(err(&blob), Error::StructBlockOutOfBounds);
    }

    #[test]
    fn strings_block_past_totalsize() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        let grown = field(&blob, 8) + 4;
        set_field(&mut blob, 8, grown);
        assert_eq!(err(&blob), Error::StringsBlockOutOfBounds);
    }

    #[test]
    fn reservation_block_past_totalsize() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        // Rounded up to eight, so it is the extent and not the alignment that
        // this blob gets wrong.
        let past_totalsize = (field(&blob, 1) + 8) & !7;
        set_field(&mut blob, 4, past_totalsize);
        assert_eq!(err(&blob), Error::ReservationsOutOfBounds);
    }

    #[test]
    fn misaligned_structure_offset() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        let misaligned = field(&blob, 2) + 1;
        set_field(&mut blob, 2, misaligned);
        assert_eq!(err(&blob), Error::MisalignedStructBlock);
    }

    #[test]
    fn misaligned_reservation_offset() {
        let mut blob = DTC_CELLS_1_1.to_vec();
        let misaligned = field(&blob, 4) + 4;
        set_field(&mut blob, 4, misaligned);
        assert_eq!(err(&blob), Error::MisalignedReservations);
    }

    #[test]
    fn a_property_whose_len_runs_past_the_whole_blob() {
        let mut b = Builder::new();
        b.begin_node("");
        let nameoff = b.intern("reg");
        b.prop_raw(0xffff, nameoff, &[0u8; 4]);
        b.end_node();
        b.end();
        assert_eq!(err(&b.build()), Error::StructTruncated);
    }

    #[test]
    fn a_property_whose_len_runs_past_the_structure_block_but_not_past_the_blob() {
        // The bound that matters is the structure block and not the slice: the
        // bytes a 40-byte body would cover here do exist, they are just the
        // strings block. A parser bounded only by the slice reads them as a
        // property value and reports something else, or nothing at all — which
        // is why the strings block below is padded out to be longer than the
        // overrun rather than left at four bytes.
        let mut b = Builder::new();
        b.begin_node("");
        let nameoff = b.intern("a-name-long-enough-that-the-strings-block-outruns-the-overrun");
        b.prop_raw(40, nameoff, &[0u8; 4]);
        let blob = b.build();
        assert!(
            u64::from(field(&blob, 1)) > 40 + 16 + 24,
            "the fixture must have a strings block past the overrun"
        );
        assert_eq!(err(&blob), Error::StructTruncated);
    }

    #[test]
    fn an_unterminated_node() {
        let mut b = Builder::new();
        b.begin_node("");
        b.begin_node("memory@40000000");
        b.end(); // FDT_END with two nodes still open
        assert_eq!(err(&b.build()), Error::NodeUnterminated);
    }

    #[test]
    fn a_structure_block_with_no_end_token() {
        let mut b = Builder::new();
        b.begin_node("");
        b.end_node();
        assert_eq!(err(&b.build()), Error::StructEndMissing);
    }

    #[test]
    fn an_end_node_outside_any_node() {
        let mut b = Builder::new();
        b.end_node();
        b.end();
        assert_eq!(err(&b.build()), Error::UnbalancedEndNode);
    }

    #[test]
    fn an_unknown_token() {
        let mut b = Builder::new();
        b.begin_node("");
        b.token(0x0000_0007);
        b.end_node();
        b.end();
        assert_eq!(err(&b.build()), Error::UnknownToken);
    }

    #[test]
    fn a_node_name_with_no_terminator() {
        let mut b = Builder::new();
        b.token(FDT_BEGIN_NODE);
        b.structure.extend_from_slice(b"soc!");
        assert_eq!(err(&b.build()), Error::NodeNameUnterminated);
    }

    #[test]
    fn a_reservation_block_with_no_terminator() {
        // off_mem_rsvmap moved to within sixteen bytes of the end, so no
        // complete entry — and therefore no terminator — can be there.
        let mut blob = DTC_CELLS_1_1.to_vec();
        let totalsize = field(&blob, 1);
        set_field(&mut blob, 4, (totalsize - 8) & !7);
        assert_eq!(err(&blob), Error::ReservationsUnterminated);
    }

    #[test]
    fn a_reservation_block_that_runs_into_the_rest_of_the_blob() {
        // The other shape of the same fault: a real entry with nothing after it,
        // so the walk reads the structure and strings blocks as entries and
        // reaches the end of the blob still looking for the zero pair.
        let mut b = Builder::new();
        b.terminate_reservations = false;
        b.reserve(0x9000_0000, 0x1000);
        b.begin_node("");
        b.end_node();
        b.end();
        assert_eq!(err(&b.build()), Error::ReservationsUnterminated);
    }

    #[test]
    fn nesting_of_thirty_three() {
        let mut b = Builder::new();
        for i in 0..=MAX_DEPTH {
            b.begin_node(&format!("n{i}"));
        }
        for _ in 0..=MAX_DEPTH {
            b.end_node();
        }
        b.end();
        assert_eq!(err(&b.build()), Error::TooDeep);
    }

    #[test]
    fn a_nameoff_past_the_strings_block() {
        let mut b = Builder::new();
        b.begin_node("");
        b.prop("#address-cells", &1u32.to_be_bytes());
        let past = b.strings.len() as u32;
        b.prop_raw(4, past, &2u32.to_be_bytes());
        b.end_node();
        b.end();
        assert_eq!(err(&b.build()), Error::NameOffsetOutOfBounds);
    }

    #[test]
    fn a_strings_block_whose_last_name_has_no_terminator() {
        let mut blob = minimal(1, 1).build();
        // Overwrite the final NUL, which leaves the last name running to the end
        // of the block with nothing closing it.
        let last = blob.len() - 1;
        blob[last] = b'!';
        assert_eq!(err(&blob), Error::NameUnterminated);
    }

    #[test]
    fn a_cell_count_above_two() {
        let blob = minimal(3, 1).build();
        assert_eq!(err(&blob), Error::UnsupportedCellCount);
    }

    #[test]
    fn a_zero_cell_count() {
        let blob = minimal(1, 0).build();
        assert_eq!(err(&blob), Error::UnsupportedCellCount);
    }

    #[test]
    fn a_cell_count_that_is_not_one_cell_wide() {
        let mut b = Builder::new();
        b.begin_node("");
        b.prop("#address-cells", &1u64.to_be_bytes());
        b.end_node();
        b.end();
        assert_eq!(err(&b.build()), Error::MalformedCellCount);
    }

    #[test]
    fn a_reg_that_is_not_a_whole_number_of_pairs() {
        let mut b = Builder::new();
        b.begin_node("");
        b.prop_u32("#address-cells", 1);
        b.prop_u32("#size-cells", 1);
        b.begin_node("memory@40000000");
        b.prop("device_type", b"memory\0");
        b.prop("reg", &[0u8; 12]); // one and a half pairs
        b.end_node();
        b.end_node();
        b.end();
        assert_eq!(err(&b.build()), Error::MalformedReg);
    }

    #[test]
    fn an_empty_reg() {
        let mut b = Builder::new();
        b.begin_node("");
        b.prop_u32("#address-cells", 1);
        b.prop_u32("#size-cells", 1);
        b.begin_node("memory@40000000");
        b.prop("device_type", b"memory\0");
        b.prop("reg", &[]);
        b.end_node();
        b.end_node();
        b.end();
        assert_eq!(err(&b.build()), Error::MalformedReg);
    }

    #[test]
    fn more_memory_regions_than_the_map_holds() {
        let over = many_memory_nodes(MAX_REGIONS + 1);
        assert_eq!(err(&over), Error::TooManyRegions);

        // And one fewer is accepted, which is what makes the bound the thing
        // under test rather than the loop.
        let exact = many_memory_nodes(MAX_REGIONS);
        assert_eq!(parse(&exact).unwrap().regions().len(), MAX_REGIONS);
    }

    fn many_memory_nodes(count: usize) -> Vec<u8> {
        let mut b = Builder::new();
        b.begin_node("");
        b.prop_u32("#address-cells", 1);
        b.prop_u32("#size-cells", 1);
        for i in 0..count {
            b.begin_node(&format!("memory@{i}"));
            b.prop("device_type", b"memory\0");
            let body = reg_body(1, 1, 0x4000_0000 + i as u64 * 0x1000, 0x1000);
            b.prop("reg", &body);
            b.end_node();
        }
        b.end_node();
        b.end();
        b.build()
    }

    #[test]
    fn more_reservations_than_the_map_holds() {
        let mut over = minimal(1, 1);
        for i in 0..MAX_RESERVED + 1 {
            over.reserve(0x8000_0000 + i as u64 * 0x1000, 0x1000);
        }
        assert_eq!(err(&over.build()), Error::TooManyReservations);

        let mut exact = minimal(1, 1);
        for i in 0..MAX_RESERVED {
            exact.reserve(0x8000_0000 + i as u64 * 0x1000, 0x1000);
        }
        assert_eq!(
            parse(&exact.build()).unwrap().reserved().len(),
            MAX_RESERVED
        );
    }

    // -----------------------------------------------------------------------
    // No input reaches a panic
    //
    // `#[should_panic]` is unusable here — `[profile.dev]` sets
    // `panic = "abort"`, so a panic takes the whole runner down. That is what
    // makes these sweeps meaningful rather than decorative: any index this
    // parser failed to bound shows up as an aborted test run, not as a quiet
    // pass.
    // -----------------------------------------------------------------------

    #[test]
    fn every_truncation_of_a_good_blob_is_an_error_and_not_a_panic() {
        for n in 0..DTC_CELLS_1_1.len() {
            assert!(parse(&DTC_CELLS_1_1[..n]).is_err(), "prefix of {n} parsed");
        }
        assert_eq!(parse(&DTC_CELLS_1_1).unwrap().regions(), &[EXPECTED]);
    }

    #[test]
    fn every_single_bit_corruption_of_the_header_is_an_error_and_not_a_panic() {
        for byte in 0..HEADER_LEN as usize {
            for bit in 0..8 {
                let mut blob = DTC_CELLS_2_2.to_vec();
                blob[byte] ^= 1 << bit;
                let _ = parse(&blob);
            }
        }
    }

    #[test]
    fn every_single_bit_corruption_of_the_body_is_an_error_and_not_a_panic() {
        // The header still carries the true `totalsize`, so these flips cannot
        // change where the parser believes the blob ends — which is what makes
        // this the sweep that exercises the structure and strings walks rather
        // than the header checks. Bit flips and not random bytes, so the set is
        // exhaustive and the run is reproducible.
        for byte in HEADER_LEN as usize..DTC_CELLS_2_2.len() {
            for bit in 0..8 {
                let mut blob = DTC_CELLS_2_2.to_vec();
                blob[byte] ^= 1 << bit;
                let _ = parse(&blob);
            }
        }
    }
}
