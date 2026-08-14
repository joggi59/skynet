#!/usr/bin/env bash
# Shared helpers for the CI scripts.
#
# Sourced, never executed directly.
#
# Reporting vocabulary, used consistently everywhere:
#
#   PASS     the check ran and succeeded
#   FAIL     the check ran and failed
#   PENDING  the check cannot run yet — the milestone it needs has not landed
#   SKIP     the check does not apply to this contribution
#
# PENDING is never reported as PASS. An invariant we cannot enforce yet is an
# invariant we are not enforcing, and saying otherwise would make the whole
# apparatus a decoration. See CONSTITUTION.md.
#
# Exit codes, which are the same statement made to a caller that reads no text:
#
#   0  something was measured and nothing failed
#   1  something was measured and something failed
#   2  usage or environment error (`die`)
#   3  NOTHING WAS MEASURED — every check reported PENDING or SKIP
#
# 3 exists because 0 was answering two different questions. `ci/build.sh --all`
# with no bare-metal target, and `ci/boot-test.sh` on an unbuilt tree, both
# printed only PENDING and exited 0; two judges reported runs that looked clean
# and had measured nothing at all. The gate is unaffected either way — it counts
# PASS/FAIL/PENDING lines and refuses on PENDING, it does not read exit codes —
# so this is entirely about a standalone run being honest to a human or a shell.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Where the forge's STATE lives, which is not the same question as where this
# checkout lives.
#
# REPO_ROOT is derived from this script's own path, so inside a git worktree it
# is the worktree — correct for building and checking, since that is the tree
# under test. It is wrong for contribution records and the ledger, which belong
# to the repository as a whole: a worktree has no `.forge/`, so `forge
# contribution_submit` run from one counted zero existing contributions and
# allocated C-0001, an identifier eight contributions old. It created the
# directory rather than failing.
#
# `--git-common-dir` resolves to the MAIN checkout's `.git` from anywhere,
# including inside a worktree. If it cannot be resolved there is no repository
# and no honest fallback, so this fails rather than guessing.
if _common=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null); then
    case "$_common" in
        /*) ;;
        *)  _common="$REPO_ROOT/$_common" ;;
    esac
    FORGE_ROOT="$(cd "$_common/.." && pwd)"
    unset _common
else
    FORGE_ROOT=""
fi
export FORGE_ROOT
export REPO_ROOT

# Colour only when attached to a terminal, so logs and evidence files stay clean.
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'
    C_PEND=$'\033[33m'; C_SKIP=$'\033[90m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_PASS=''; C_FAIL=''; C_PEND=''; C_SKIP=''; C_BOLD=''
fi

# Tallies for the summary line.
CHECKS_PASS=0
CHECKS_FAIL=0
CHECKS_PENDING=0
CHECKS_SKIP=0

pass()    { CHECKS_PASS=$((CHECKS_PASS+1));       printf '%sPASS%s     %s\n'    "$C_PASS" "$C_RESET" "$*"; }
fail()    { CHECKS_FAIL=$((CHECKS_FAIL+1));       printf '%sFAIL%s     %s\n'    "$C_FAIL" "$C_RESET" "$*"; }
pending() { CHECKS_PENDING=$((CHECKS_PENDING+1)); printf '%sPENDING%s  %s\n'    "$C_PEND" "$C_RESET" "$*"; }
skip()    { CHECKS_SKIP=$((CHECKS_SKIP+1));       printf '%sSKIP%s     %s\n'    "$C_SKIP" "$C_RESET" "$*"; }
info()    { printf '         %s\n' "$*"; }
detail()  { printf '           %s\n' "$*"; }
heading() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

die() { printf '%sERROR%s    %s\n' "$C_FAIL" "$C_RESET" "$*" >&2; exit 2; }

# Summary line. Returns 1 if anything failed, 3 if nothing was measured, else 0.
#
# PENDING never fails a run on its own — but the gate refuses to merge a
# contribution whose milestone-relevant checks are pending, which is where that
# distinction is enforced.
#
# "Nothing was measured" is zero PASS and zero FAIL. Not "some check is
# pending": ci/constitution-check.sh has four permanently pending invariants by
# design and must keep exiting 0 while the rest of it passes. The distinction
# that matters is between a run that produced evidence and a run that produced
# none, and only the second is a run whose green cannot be believed.
summary() {
    printf '\n%s%s%s\n' "$C_BOLD" "──────────────────────────────────────────" "$C_RESET"
    printf '%s %d passed' "${1:-checks}" "$CHECKS_PASS"
    [ "$CHECKS_FAIL"    -gt 0 ] && printf ', %s%d failed%s'    "$C_FAIL" "$CHECKS_FAIL" "$C_RESET"
    [ "$CHECKS_PENDING" -gt 0 ] && printf ', %s%d pending%s'   "$C_PEND" "$CHECKS_PENDING" "$C_RESET"
    [ "$CHECKS_SKIP"    -gt 0 ] && printf ', %s%d skipped%s'   "$C_SKIP" "$CHECKS_SKIP" "$C_RESET"
    printf '\n'
    [ "$CHECKS_FAIL" -eq 0 ] || return 1
    if [ "$CHECKS_PASS" -eq 0 ]; then
        printf '%sNOTHING MEASURED%s  no check produced evidence; exit 3, not 0\n' \
            "$C_PEND" "$C_RESET"
        return 3
    fi
    return 0
}

# --- TOML access -----------------------------------------------------------
# python3 stdlib tomllib. No dependency, no parser of our own to get wrong.

have_python() { command -v python3 >/dev/null 2>&1; }

# toml_get <file> <python-expression-over-`d`>
# Example: toml_get profiles/standard.toml "d['budget']['kernel_image']['max_bytes']"
toml_get() {
    local file="$1" expr="$2"
    python3 -c "
import tomllib,sys
try:
    d = tomllib.load(open('$file','rb'))
    v = $expr
    if isinstance(v,(list,tuple)): print('\n'.join(str(x) for x in v))
    elif isinstance(v,bool): print('true' if v else 'false')
    else: print(v)
except (KeyError, IndexError):
    sys.exit(3)
" 2>/dev/null
}

# --- Milestones ------------------------------------------------------------

milestone_reached() {
    local m="$1"
    toml_get "$REPO_ROOT/constitution.toml" "d['milestones']['reached']" 2>/dev/null \
        | grep -qx "$m"
}

# --- Profiles --------------------------------------------------------------

active_profile() { echo "${SKYNET_PROFILE:-standard}"; }

profile_file() {
    local p; p="$(active_profile)"
    local f="$REPO_ROOT/profiles/$p.toml"
    [ -f "$f" ] || die "unknown profile '$p' (no $f)"
    echo "$f"
}

profile_target() { toml_get "$(profile_file)" "d['profile']['target']"; }

# --- Toolchain -------------------------------------------------------------
# Reported as PENDING rather than FAIL when missing: an uninstalled toolchain is
# an unrun check, not a failing one, and conflating the two teaches people to
# ignore red.

# Named a linker only after two Guardians independently graded its absence a
# provenance finding: the target's default is rust-lld, which Fedora does not
# ship, so a machine provisioned by following this hint passed the reachability
# check and then could not link. See .cargo/config.toml.
INSTALL_HINT='sudo dnf install qemu-system-aarch64 rust-std-static-aarch64-unknown-none-softfloat lld clippy dtc'

# Is the target's `core` actually reachable?
#
# Not "does /usr/lib/rustlib/<target> exist" — that answers where the libraries
# came from, which is not the question. A sysroot supplied through RUSTFLAGS is
# as valid as one installed by the distribution, and hard-coding the system path
# made a working toolchain report PENDING.
effective_sysroots() {
    echo "/usr"
    # --sysroot=/path or --sysroot /path, anywhere in RUSTFLAGS.
    echo "${RUSTFLAGS:-}" | grep -oE -- '--sysroot[= ][^ ]+' | sed -E 's/^--sysroot[= ]//'
}

have_rust_target() {
    local t="${1:-$(profile_target)}" sr
    while IFS= read -r sr; do
        [ -n "$sr" ] || continue
        [ -d "$sr/lib/rustlib/$t/lib" ] && return 0
    done < <(effective_sysroots)
    return 1
}

# The emulator. Overridable so a machine that has QEMU somewhere other than the
# system path can still run the boot test — the check is what matters, not where
# the binary came from. Provenance records the digest of what ran, not its path.
QEMU_BIN="${SKYNET_QEMU:-qemu-system-aarch64}"
export QEMU_BIN

have_qemu() { command -v "$QEMU_BIN" >/dev/null 2>&1 || [ -x "$QEMU_BIN" ]; }

kernel_exists() { [ -f "$REPO_ROOT/kernel/Cargo.toml" ]; }

# --- The boot contract -----------------------------------------------------
# The single string the kernel must print on the boot console to be considered
# alive, and the QEMU machine it must print it on.
#
# This is a contract, not a preference: task acceptance criteria reference it,
# the implementer prints it, and ci/boot-test.sh looks for it. Changing it
# changes what "the kernel boots" means, so it lives in one place.

BOOT_MARKER='SKYNET_BOOT_OK'
PANIC_MARKER='SKYNET_PANIC'
FAULT_MARKER='SKYNET_FAULT'
REFAULT_MARKER='SKYNET_REFAULT'
QEMU_MACHINE='virt'
QEMU_CPU='cortex-a72'
BOOT_TIMEOUT_SECONDS=30
export BOOT_MARKER PANIC_MARKER FAULT_MARKER REFAULT_MARKER QEMU_MACHINE QEMU_CPU BOOT_TIMEOUT_SECONDS

# On PANIC_MARKER, per RFC-0001:
#
# A panic that halts is caught by the timeout — correctly, but thirty seconds
# later, on every panic, forever. A panic that shuts down cleanly exits 0 and is
# indistinguishable from success to a test checking only the exit code.
#
# So the panic must be visible in the output. The kernel prints PANIC_MARKER and
# then shuts down; the boot test requires BOOT_MARKER present AND PANIC_MARKER
# absent. This fails closed in both directions: a panic before the marker fails
# on the missing marker, a panic after it fails on the panic marker.
#
# FAULT_MARKER exists for the same reason, and was missing for one contribution.
# Before exception vectors, a hardware fault hung the machine and the timeout
# caught it. After them, a fault prints a report and shuts down cleanly through
# PSCI — so the boot test saw its marker, no panic, and exit 0, and reported
# three passes on a kernel that had just taken a data abort.
#
# Adding fault reporting made CI blind to faults. Found by reviewer-constitution,
# which ran this script against a faulting kernel rather than reasoning about it.
#
# REFAULT_MARKER is the third instance of the same shape, added before it could
# bite rather than after. The vector table now stops the machine when it is
# re-entered during a failure — deliberately, because the alternative was a `wfi`
# loop and a thirty-second timeout. That makes a fault storm exit 0 as well, so
# it needs its own marker for exactly the reason FAULT_MARKER does.
#
# The three markers must stay mutually distinguishable by plain substring match.
# SKYNET_REFAULT does not contain SKYNET_FAULT, which is true and is luck; the
# check below turns it into a property. A future marker that nests inside another
# would make one of them permanently unreportable.
_marker_check() {
    local a b
    for a in "$BOOT_MARKER" "$PANIC_MARKER" "$FAULT_MARKER" "$REFAULT_MARKER"; do
        for b in "$BOOT_MARKER" "$PANIC_MARKER" "$FAULT_MARKER" "$REFAULT_MARKER"; do
            [ "$a" = "$b" ] && continue
            case "$b" in *"$a"*)
                echo "ci/lib.sh: marker '$a' is a substring of '$b' —" \
                     "grep for '$a' will match '$b' and one of them can never be reported" >&2
                exit 70 ;;
            esac
        done
    done
}
_marker_check

# --- The two artefacts ------------------------------------------------------
#
# One build produces two files and they are not interchangeable:
#
#   kernel_binary()  the ELF. Symbols, sections, debug info. What gdb, nm and
#                    readelf need, and what objcopy reads FROM.
#   kernel_image()   the flat Linux-format `Image`. What QEMU is given at
#                    -kernel, and what the size budget is measured against —
#                    debug info and symbol tables are not shipped to a device,
#                    so measuring them would flatter the number.
#
# Which one goes where is load-bearing rather than a detail. QEMU treats an ELF
# as non-Linux: it never writes the bootloader stub, so every register is zero
# at entry and no device tree is placed anywhere in RAM. Given the flat image it
# does write the stub, and `x0` is a device tree pointer. RFC-0003 section 1a
# measured both, from the same source, and section 8 assigns this split.

# Where cargo actually put it.
#
# Not a constant `kernel/target`: CARGO_TARGET_DIR in the environment moves the
# output and this function used to ignore it, so on a clean tree build.sh
# reported "cargo reported success but <path> does not exist" — and on a tree
# that had been built once before, something worse, a PASS naming a stale ELF
# from an earlier build while the one just produced sat elsewhere unexamined.
#
# A relative CARGO_TARGET_DIR resolves against the directory cargo is invoked
# from, and every script here `cd`s to REPO_ROOT first. Measured, not assumed.
kernel_target_dir() {
    local d="${CARGO_TARGET_DIR:-}"
    case "$d" in
        "") echo "$REPO_ROOT/kernel/target" ;;
        /*) echo "$d" ;;
        *)  echo "$REPO_ROOT/$d" ;;
    esac
}

kernel_binary() {
    local target; target="$(profile_target)"
    echo "$(kernel_target_dir)/$target/release/skynet-kernel"
}

# The flat image, at the path ci/build.sh writes it to.
#
# Per profile, because the budget it is measured against is per profile and two
# profiles must not overwrite each other's artefact.
kernel_image() {
    echo "$REPO_ROOT/ci/.out/kernel-$(active_profile).bin"
}

# Is the flat image older than the ELF it is derived from?
#
# True also when it does not exist. This is the hazard the RFC names for the
# path itself — "a boot test that read that path today would boot whatever the
# last --size left there" — and moving the objcopy into the build step does not
# by itself close it: a tree built before this change, or a `cargo build` run by
# hand, leaves an ELF newer than the .bin and nothing would say so. Anything
# that consumes the flat image asks this first and reports rather than measures.
kernel_image_stale() {
    local elf img
    elf="$(kernel_binary)"; img="$(kernel_image)"
    [ -f "$img" ] || return 0
    [ -f "$elf" ] || return 1
    [ "$elf" -nt "$img" ]
}
