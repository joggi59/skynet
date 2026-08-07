// SPDX-License-Identifier: GPL-3.0-or-later

//! The failure path, and the only place outside `boot_rust` that mints a device.

use core::sync::atomic::{AtomicU32, Ordering};

use crate::hal::{self, Console, Power};

use super::exception::{class_name, elr_is_indicative_only, far_is_meaningful, Slot};
use super::hex;
use super::pl011::BootConsole;
use super::platform;
use super::psci::PowerControl;

/// The kernel's only `static`, and the one piece of state it carries.
///
/// # Why it exists
///
/// Without it, `fail_stop` can re-enter itself without limit. This was reproduced
/// this rather than arguing it: one overflowing addition in the console write
/// path, with `overflow-checks = true`, sends the panic handler into `fail_stop`,
/// whose write overflows, which panics, which calls `fail_stop` again. The
/// 64 KiB stack has no guard page and the MMU is off at M0, so it runs into
/// `.text` 192 bytes below and executes an undefined instruction, vectoring
/// through an uninitialised `VBAR_EL1` — 55.9 million exception entries in
/// twenty seconds, no console output at all, and CI sees nothing but a timeout.
///
/// The path is panic-free today. "Panic-free today" is exactly the class of
/// assumption this project refuses everywhere else.
///
/// # What it costs
///
/// Zero statics was a property this project had and valued: the evidence that ownership is doing at M0 what a capability will do
/// at M4. This spends it, deliberately, and the claim narrows honestly to "one
/// static, in the failure path, and here is why it earns its place".
///
/// # What it is now, which is not what this comment used to say
///
/// It used to read: "its only reachable effect is to halt instead of recurse; it
/// carries no information, cannot be read outside this module, and cannot be
/// reached outside the panic path." All three clauses were made false by the
/// lines directly beneath them, in the patch that wrote them.
///
/// It is `pub(super)`, not module-private. It is an `AtomicU32` holding one of
/// four values, not a flag. All sixteen vector entries read it on every
/// exception and advance it on three of their four paths — the fourth is the
/// terminal rung, which has nothing left to advance to. `exception.rs` takes it
/// by `sym`.
///
/// That sentence has now been wrong twice in opposite directions: first "read it
/// and write it on every exception", then "advances it on exactly one of four
/// paths", written in the commit that moved the advance INTO the entry and made
/// three of them write. Counted in the disassembly this time, not remembered. And its effect is no longer to halt: it selects between reporting the fault,
/// printing a sixteen-byte marker and stopping the machine, and stopping dead
/// without touching a device.
///
/// It still grants no authority, and that clause was true. The rest was
/// bookkeeping that outlived what it described.
///
/// # Where it lives, and why that is a link-time property
///
/// Its own `.guard` section, placed below `.text` at the bottom of the image.
/// It used to be the only thing in `.bss`, directly beneath the stack, so a
/// stack overflow destroyed it before it destroyed anything else — and the
/// overflow kept going into the vector table itself. Review measured 1,495,553
/// exceptions in three seconds with an empty console, the trace showing an
/// undefined instruction taken AT vector entry 4. `link.ld` now asserts the
/// order rather than describing it.
#[unsafe(link_section = ".guard")]
pub(super) static IN_FAILURE: AtomicU32 = AtomicU32::new(0);

// What `Relaxed` assumes here, since it is not obvious and is not free.
//
// This word is read and written from two places the compiler cannot relate: one
// relaxed atomic load in Rust, and plain `ldr`/`str` in the vector table's naked
// assembly, which LLVM does not see at all. `Relaxed` orders nothing, and no
// stronger ordering would help — an acquire on the Rust side has nothing to
// synchronise with, because the assembly side issues no release.
//
// What makes it correct is not ordering, it is that there is one observer. M1 is
// a single core with interrupts masked, and the only way control reaches the
// assembly reader is a synchronous exception on the same core — which cannot
// interleave with a load, only follow it. The word is naturally aligned and the
// accesses are single-copy atomic by the architecture, so no reader can see a
// half-written value.
//
// Every clause of that expires at the second core, and it expires in the unsafe
// direction: two cores failing at once would race here with nothing to stop
// them. Whoever brings up the second core owns this comment.

// Why a word of pattern rather than a byte.
//
// The byte version cost one value in 256 total silence. The vector entry tests
// the most degraded state first, and that test was `cmp w1, #0x5a` — so a guard
// corrupted to exactly `0x5a` sent the FIRST genuine fault to the dead stop.
// Review measured it: one exception, no console output at all, no PSCI, exit
// 124. The three-state ladder bought a bound and sold a chance of silence, and
// nothing recorded the trade.
//
// Four bytes with the halves inverted means no single-byte corruption can
// produce any state, and a random word hits one with probability 3 in 2^32.
// That is not a guarantee — nothing here is, without an MMU — but it moves the
// failure from "plausible" to "not worth the arithmetic".

/// A failure is in progress and its report has not finished.
pub(super) const FAILING: u32 = 0xa5a5_5a5a;

/// The failure path faulted. Print a fixed marker, stop the machine.
///
/// [`FAILING`] bounds re-entry into the fault report; this bounds re-entry into
/// the path that prints the marker, which ends in an unconditional `hvc`.
pub(super) const STOPPING: u32 = 0x5a5a_a5a5;

/// The marker path faulted too. Stop the machine without touching a device.
///
/// The rung that was missing. With three states the dead stop was a bare `wfi`,
/// so a machine that got there exited 124 and looked exactly like a hang; and if
/// it had instead tried PSCI, a fault in the `hvc` would have come back to the
/// same state and tried again forever. A fourth value lets each rung do strictly
/// less than the one above and still say something, with a two-instruction stop
/// as the end that touches nothing at all.
pub(super) const SILENT: u32 = 0x3c3c_c3c3;

/// Stop the machine. The failure path's only PSCI constructor call.
///
/// Three places in this module end by powering off, and each used to construct
/// its own `PowerControl`. Three identical constructions with three copies of
/// the same safety argument is three chances for one of them to drift, and it
/// makes the minting count grow every time the failure path gains a branch —
/// a count `ci/constitution-check.sh` reads as a ratchet.
///
/// # Safety
/// Reachable only after the kernel has failed, on a path that never returns, at
/// EL1 where the HVC conduit is valid.
unsafe fn stop() -> ! {
    // SAFETY: `PowerControl::new`'s precondition is EL1, where the HVC conduit
    // is valid; `boot.rs` parks the core anywhere else, so reaching this line at
    // all establishes it. The constructor's "at most once" clause is met because
    // every caller has already failed and none of them returns.
    unsafe { PowerControl::new() }.off()
}

/// The failure path's console. Its only PL011 constructor call.
///
/// # Safety
/// As for [`stop`], and additionally: this aliases the console `boot.rs` handed
/// to `kernel_main`.
unsafe fn console() -> BootConsole {
    // SAFETY: `UART0_BASE` is the platform console's base, which is
    // `BootConsole::new`'s precondition. The aliasing is sound because every
    // caller has already failed and none returns, so the other holder is
    // provably dead and no race is possible.
    unsafe { BootConsole::new(platform::UART0_BASE) }
}

/// The platform's fail-stop.
///
/// The single MODULE in the kernel where authority is created outside the boot
/// path. Two functions now: [`hal::FailStop::fail_stop`] for panics, which
/// writes a compile-time constant, and [`Failure::fault_stop`] for hardware
/// faults, which writes register values.
///
/// # Neither function is contained, and this comment has claimed otherwise
/// three times
///
/// The record, because the pattern matters more than any one sentence:
///
///   - "one function, one caller, one compile-time constant" — written when
///     there was one, still there when there were two.
///   - "both are `pub(super)` or narrower" — false; `fail_stop` is a public
///     trait method, because `#[panic_handler]` must reach it and the language
///     offers nothing else.
///   - "`fault_stop` is unreachable from portable Rust" — false, and the
///     counter-example was booted: a file with no `asm!`, no `core::arch`, no
///     `target_arch` and no constructor call declares
///     `extern "C" { #[link_name = "<the v0-mangled symbol>"] fn f(..); }` and
///     puts 160 bits of its own choosing on the operator's console, then powers
///     the machine off. Build, clippy `-D warnings` and the full constitution
///     check all pass.
///
/// Each correction was careful and each was replaced by a narrower claim that
/// was also false. So the claim is withdrawn rather than narrowed again:
///
/// **No visibility modifier in Rust contains anything.** `#[link_name]` reaches
/// any symbol present in the binary, whatever `pub` says about it, and there is
/// no attribute, lint or CI grep that closes that. `pub(super)` stops an
/// accident and an idiom. It has never stopped an intent, and a comment that
/// implies it does is worse than no comment — it invites the next reader to rely
/// on it.
///
/// What would actually contain these: capabilities at M4, where reaching a
/// device requires holding something rather than naming something. Until then
/// the containment is the review, and the review is these paragraphs being wrong
/// in public rather than right in private.
///
/// Both are behind the same re-entrancy guard, and neither returns.
///
/// What would turn it into a global console: returning instead of diverging,
/// gaining a receiver, acquiring a second call site, or being handed anything
/// other than a compile-time constant.
///
/// The `'static` bound narrows the last of those and does not enforce it — an
/// earlier version of this sentence said "now enforces", which is the same
/// mistake as the containment claim above. A `#[link_name]` extern declares
/// whatever signature it likes and the bound is not there to be checked.
pub struct Failure;

impl hal::FailStop for Failure {
    unsafe fn fail_stop(bytes: &'static [u8]) -> ! {
        // Load and store, not `swap`; compare before storing; store only on
        // the path that continues.
        //
        // `swap` compiles to `ldxr`/`stxr`, an exclusive-monitor pair. The MMU
        // is off, so this is Device-nGnRnE memory, and the architecture does not
        // guarantee exclusive monitors work there. A `stxr` that never succeeds
        // is an infinite retry loop in the first instructions of the handler
        // whose entire purpose is to stop an infinite loop.
        //
        // The observer that matters is not a second core. It is THIS core taking
        // a synchronous exception, which DAIF does not mask — so the hazard is
        // re-entrancy, not concurrency, and an earlier justification here
        // ("single-core, no interrupts") was the wrong argument for the right
        // code. Anything faultable placed between the load and the store widens
        // the window: one revision let the compiler put stack traffic there and
        // a fault injected into the gap gave 2,733,246 exceptions.
        //
        // Comparing rather than testing non-zero is what keeps a corrupted word
        // from reading as re-entry and costing a genuine fault its report.
        // Storing only on the continuing path is what stops this function
        // demoting a lower rung back to a higher one — see the ladder above.
        let already = IN_FAILURE.load(Ordering::Relaxed);
        if already == FAILING || already == STOPPING || already == SILENT {
            // Already failing. Do not touch the console: the previous entry may
            // have been interrupted mid-write, and whatever panicked will panic
            // again if asked to do the same work.
            //
            // Stop the machine rather than halt it. `Processor::halt()` here was
            // a `wfi` loop, so a panic raised inside `fault_stop` produced a
            // truncated report and then thirty seconds of silence and exit 124 —
            // measured. The vector table's equivalent path was changed to stop
            // the machine and this one was not, which left the two ends of the
            // same guard behaving differently for no reason anyone chose.
            //
            // SAFETY: the kernel has failed, this never returns, and EL1 is where
            // the HVC conduit is valid. Same constructor, same module, no new
            // site.
            unsafe { stop() }
        }
        IN_FAILURE.store(FAILING, Ordering::Relaxed);

        // SAFETY: the kernel has already failed and this function never returns,
        // so no other owner of the PL011 or of PSCI will run again and the
        // aliasing cannot race with anything. `UART0_BASE` is the platform
        // console's base, which satisfies `BootConsole::new`'s precondition; the
        // "at most once" clause is met in substance because the other holder is
        // provably dead, and the guard above makes it true of this function too.
        let mut console = unsafe { console() };
        console.write(bytes);
        // SAFETY: as above — reached only after the kernel has failed, from a
        // path that never returns, at EL1 where the HVC conduit is valid.
        unsafe { stop() }
    }
}

impl Failure {
    /// Report a hardware fault, then stop. Does not return.
    ///
    /// Behind the same [`IN_FAILURE`] guard as [`hal::FailStop::fail_stop`], and
    /// minting through the same call. This is deliberate and is the reason the
    /// fault path lives in this module rather than in `exception.rs`: review
    /// found that closing the constructor reach-around left `fail_stop` itself
    /// reachable — the hole moved rather than closing. A second constructor call
    /// would move it again. One module CONSTRUCTS devices, and that stays true.
    ///
    /// It is not the same claim as "one module reaches devices", and that one is
    /// now false. The vector table's emergency path writes the PL011 and issues
    /// PSCI directly, holding neither, because it has no stack to hold them with
    /// — see RFC-0002, "The third device-access site". An earlier version of this
    /// comment said "one module mints devices, and that claim stays true" while
    /// the file two directories away said "it writes the UART directly", in the
    /// same patch.
    ///
    /// The guard covers a fault raised from inside this function, which is the
    /// storm review measured at 10,262,934 exceptions in four seconds and the
    /// gap it flagged in the panic-only guard.
    ///
    /// # Why this writes runtime data when `fail_stop` may not
    ///
    /// `fail_stop` takes `&'static [u8]` because a panic message is program text
    /// that could contain anything a future author puts there. This takes
    /// register values.
    ///
    /// An earlier version added that those values are "facts about the machine,
    /// chosen by this code and not by a caller". That is false in the same way
    /// the containment claim above was false: `#[link_name]` reaches this
    /// function from portable code and the caller chooses all four arguments.
    /// The difference between the two functions is what the TYPE permits, and
    /// that is the whole of it — one takes a `'static` slice, this one takes
    /// four integers. Neither is a statement about who calls.
    ///
    /// # Safety
    /// Callable only from an exception vector, which has already advanced the
    /// ladder. Aliases a console owned elsewhere, sound only because the kernel
    /// has already failed and no other code will run again.
    /// `pub(super)`, not `pub`. The counter-example was compiled against
    /// the previous revision: `Failure` is re-exported at crate scope, `Slot`
    /// being private does not help because `None` needs no name, and portable
    /// code could therefore put 160 bits of its own choosing on the operator's
    /// console and power the machine off — with the HAL check passing.
    ///
    /// The same idiom two files away, for the same reason, from the review
    /// cycle before this one. It was applied to the constructors and not to
    /// this function.
    pub(super) unsafe fn fault_stop(slot: Option<Slot>, esr: u64, far: u64, elr: u64) -> ! {
        // NO guard check here, and no guard write. The vector entry advanced the
        // ladder before any stack was touched; checking again would see what
        // this fault's own entry just wrote and stop before printing anything.

        // SAFETY: as for `fail_stop` — the kernel has failed and this never
        // returns, so the console's other owner is provably dead. There is no
        // "guard above" in this function; the earlier wording said there was,
        // three lines under the comment saying this function checks no guard.
        // What makes the "at most once" clause true is the vector entry, which
        // advanced the ladder before branching here.
        let mut console = unsafe { console() };
        let mut put = |b: u8| console.write(&[b]);

        put(b'\n');
        for &b in b"SKYNET_FAULT\r\n  slot  " {
            put(b);
        }
        match slot {
            Some(s) => {
                for &b in s.name() {
                    put(b);
                }
            }
            // The index came from the vector table's own immediate, so this is
            // unreachable — and it is reported rather than assumed away.
            None => {
                for &b in b"unknown index " {
                    put(b);
                }
            }
        }

        for &b in b"\r\n  esr   " {
            put(b);
        }
        hex::write_u32(&mut put, esr);
        if let Some(name) = class_name(esr) {
            for &b in b"  " {
                put(b);
            }
            for &b in name {
                put(b);
            }
        } else {
            for &b in b"  unrecognised class ec=" {
                put(b);
            }
            hex::write_hex(&mut put, (esr >> 26) & 0x3f, 2);
        }

        for &b in b"\r\n  far   " {
            put(b);
        }
        hex::write_u64(&mut put, far);
        if !far_is_meaningful(esr) {
            for &b in b"  (stale: no address for this class)" {
                put(b);
            }
        }

        for &b in b"\r\n  elr   " {
            put(b);
        }
        hex::write_u64(&mut put, elr);
        if elr_is_indicative_only(esr) {
            // RFC-0002, O-2. SError is asynchronous: it may be raised long after
            // whatever caused it, so this address says where execution was, not
            // what went wrong.
            for &b in b"  (asynchronous: where execution was, not the cause)" {
                put(b);
            }
        }
        put(b'\r');
        put(b'\n');

        // SAFETY: as above — after a failure, on a path that never returns, at
        // EL1 where the HVC conduit is valid.
        unsafe { stop() }
    }
}
