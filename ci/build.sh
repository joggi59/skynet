#!/usr/bin/env bash
# Build the kernel.
#
#   ci/build.sh              build for the active profile: the ELF, and the
#                            flat Linux-format Image derived from it
#   ci/build.sh --lint       clippy, zero warnings tolerated
#   ci/build.sh --test       unit tests, on the host
#   ci/build.sh --size       report the image size against the profile budget
#   ci/build.sh --all        build, lint, test, size
#
# Profile selection: SKYNET_PROFILE=nano ci/build.sh    (default: standard)
# CARGO_TARGET_DIR is honoured wherever it points.
#
# Exit 0 on success, 1 on failure, 2 on usage or environment error, 3 if
# nothing was measured at all (every check PENDING or SKIP). See ci/lib.sh.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || die "cannot enter repo root"

PROFILE="$(active_profile)"
TARGET="$(profile_target)"

# The requirement, split in two, because the two halves are not the same claim.
#
# `require_toolchain` used to open do_build, do_lint AND do_test alike, so the
# host tests were gated on the bare-metal target being reachable. They do not
# need it: kernel/src/lib.rs lifts no_std under cfg(test) and `cargo test` builds
# for the HOST, which is the entire point of the library split, and the 54 tests
# behind it are the whole deliverable of the merged parser. On a machine with
# cargo and no aarch64 sysroot the deliverable went unrun and the line printed
# was PENDING — an unrun check reported as an unreachable one.
require_host_toolchain() {
    if ! kernel_exists; then
        pending "no kernel yet — M0 has not landed"
        detail "this is the expected state at G0; the forge produces the kernel's first commit"
        return 1
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        fail "cargo not found"
        return 1
    fi
    return 0
}

require_toolchain() {
    require_host_toolchain || return 1
    # Delegated to lib.sh rather than re-tested here: duplicating the check meant
    # fixing it in one place and leaving it wrong in the other.
    if ! have_rust_target "$TARGET"; then
        pending "bare-metal Rust target '$TARGET' is not reachable"
        detail "$INSTALL_HINT"
        detail "or supply a sysroot containing it via RUSTFLAGS --sysroot"
        return 1
    fi
    return 0
}

do_build() {
    heading "Build — profile '$PROFILE', target '$TARGET'"
    require_toolchain || return 0

    if ! cargo build --release \
            --manifest-path kernel/Cargo.toml \
            --target "$TARGET" 2>&1 | sed 's/^/           /'; then
        fail "kernel build failed"
        return 0
    fi

    local bin; bin="$(kernel_binary)"
    if [ ! -f "$bin" ]; then
        fail "cargo reported success but $bin does not exist"
        detail "CARGO_TARGET_DIR is honoured; if it is set, that is where this looked"
        return 0
    fi
    pass "kernel built: $(basename "$bin")"

    # The flat image, produced HERE and not as a side effect of measuring it.
    #
    # RFC-0003 section 8, change 1. This objcopy used to live in do_size, so the
    # artefact QEMU is now handed existed only because something had decided to
    # weigh it. `--size` does not rebuild and neither does boot-test, so a boot
    # test reading this path would have booted whatever the last `--size` left
    # there — an image from an older tree, and nothing in the output would have
    # differed. Deriving it in the step that produced the ELF is what makes the
    # path safe to depend on.
    #
    # Removed before it is written: a failed objcopy that leaves the previous
    # image in place is the same stale-artefact hazard wearing a red line.
    local img; img="$(kernel_image)"
    mkdir -p "$(dirname "$img")"
    rm -f "$img"
    if ! objcopy -O binary "$bin" "$img" 2>&1 | sed 's/^/           /'; then
        fail "objcopy failed — the flat image was not produced"
        detail "the boot test and the size budget both read $(basename "$img")"
        return 0
    fi
    pass "flat image produced: ${img#$REPO_ROOT/} ($(stat -c%s "$img") bytes)"
    detail "Linux-format Image for -kernel; the ELF stays for gdb, nm and readelf"
}

do_lint() {
    heading "Lint — clippy, zero warnings"
    require_toolchain || return 0

    if ! cargo clippy --version >/dev/null 2>&1; then
        pending "clippy not installed"
        detail "sudo dnf install clippy"
        return 0
    fi

    if cargo clippy --release \
            --manifest-path kernel/Cargo.toml \
            --target "$TARGET" \
            -- -D warnings 2>&1 | sed 's/^/           /'; then
        pass "clippy clean"
    else
        fail "clippy reported warnings (treated as errors)"
    fi
}

do_test() {
    heading "Unit tests"
    # The HOST compiler, and nothing more. `cargo test` here passes no --target,
    # so a missing bare-metal sysroot has no bearing on whether these can run.
    require_host_toolchain || return 0

    # A no_std kernel cannot run the ordinary test harness against a bare-metal
    # target. Host-runnable logic tests live behind a feature and build for the
    # host; anything needing the machine is exercised by ci/boot-test.sh.
    if ! grep -q '\[\[test\]\]\|#\[cfg(test)\]' -r kernel/src kernel/tests 2>/dev/null; then
        skip "no unit tests defined yet"
        return 0
    fi

    if cargo test --manifest-path kernel/Cargo.toml 2>&1 | sed 's/^/           /'; then
        pass "unit tests passed"
    else
        fail "unit tests failed"
    fi
}

do_size() {
    heading "Image size — invariant 4, profile '$PROFILE'"
    if ! kernel_exists; then
        pending "no kernel yet; enforced from M0"
        return 0
    fi

    # The loadable image, not the ELF: debug info and symbol tables are not
    # shipped to the device, so measuring them would flatter the number.
    #
    # It is now read rather than produced. This step used to run the objcopy
    # itself, which meant `--size` measured the tree in front of it while
    # everything else that wanted a flat image got whatever `--size` had last
    # left behind. Producing it in do_build and consuming it everywhere gives
    # one artefact with one provenance — and makes staleness a question that can
    # be asked, which is the next two lines.
    local raw; raw="$(kernel_image)"
    if [ ! -f "$raw" ]; then
        pending "flat image not built — run ci/build.sh first"
        return 0
    fi
    if kernel_image_stale; then
        pending "flat image is older than the ELF — run ci/build.sh"
        detail "measuring it would report the size of a previous build"
        return 0
    fi

    local budget
    budget=$(toml_get "$(profile_file)" "d['budget']['kernel_image']['max_bytes']") || {
        fail "profile '$PROFILE' declares no kernel_image budget"; return 0; }

    local size pct
    size=$(stat -c%s "$raw")
    pct=$(( size * 100 / budget ))

    info "image  $size bytes"
    info "budget $budget bytes  (profile '$PROFILE')"
    if [ "$size" -le "$budget" ]; then
        pass "within budget — ${pct}% used"
    else
        fail "over budget by $(( size - budget )) bytes — ${pct}% of allowance"
        detail "invariant 4 is not negotiable; shrink it or amend the profile by vote"
    fi
}

main() {
    case "${1:-}" in
        "")            do_build ;;
        --lint|-l)     do_lint ;;
        --test|-t)     do_test ;;
        --size|-s)     do_size ;;
        --all|-a)      do_build; do_lint; do_test; do_size ;;
        --help|-h)     sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)             die "unknown option '$1' (try --help)" ;;
    esac
    summary "build:"
}

main "$@"
