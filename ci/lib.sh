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

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Summary line. Returns 1 if anything failed, 0 otherwise.
# PENDING never fails a run on its own — but the gate refuses to merge a
# contribution whose milestone-relevant checks are pending, which is where that
# distinction is enforced.
summary() {
    printf '\n%s%s%s\n' "$C_BOLD" "──────────────────────────────────────────" "$C_RESET"
    printf '%s %d passed' "${1:-checks}" "$CHECKS_PASS"
    [ "$CHECKS_FAIL"    -gt 0 ] && printf ', %s%d failed%s'    "$C_FAIL" "$CHECKS_FAIL" "$C_RESET"
    [ "$CHECKS_PENDING" -gt 0 ] && printf ', %s%d pending%s'   "$C_PEND" "$CHECKS_PENDING" "$C_RESET"
    [ "$CHECKS_SKIP"    -gt 0 ] && printf ', %s%d skipped%s'   "$C_SKIP" "$CHECKS_SKIP" "$C_RESET"
    printf '\n'
    [ "$CHECKS_FAIL" -eq 0 ]
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

INSTALL_HINT='sudo dnf install qemu-system-aarch64 rust-std-static-aarch64-unknown-none-softfloat dtc'

have_rust_target() {
    local t="${1:-$(profile_target)}"
    [ -d "/usr/lib/rustlib/$t" ] || rustc --print target-list 2>/dev/null | grep -qx "$t" && \
        [ -d "/usr/lib/rustlib/$t" ]
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
QEMU_MACHINE='virt'
QEMU_CPU='cortex-a72'
BOOT_TIMEOUT_SECONDS=30
export BOOT_MARKER PANIC_MARKER QEMU_MACHINE QEMU_CPU BOOT_TIMEOUT_SECONDS

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

kernel_binary() {
    local target; target="$(profile_target)"
    echo "$REPO_ROOT/kernel/target/$target/release/skynet-kernel"
}
