#!/usr/bin/env bash
# Build the kernel.
#
#   ci/build.sh              build for the active profile
#   ci/build.sh --lint       clippy, zero warnings tolerated
#   ci/build.sh --test       unit tests
#   ci/build.sh --size       report the image size against the profile budget
#   ci/build.sh --all        build, lint, test, size
#
# Profile selection: SKYNET_PROFILE=nano ci/build.sh    (default: standard)
#
# Exit 0 on success, 1 on failure, 2 on usage or environment error.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || die "cannot enter repo root"

PROFILE="$(active_profile)"
TARGET="$(profile_target)"

require_toolchain() {
    if ! kernel_exists; then
        pending "no kernel yet — M0 has not landed"
        detail "this is the expected state at G0; the forge produces the kernel's first commit"
        return 1
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        fail "cargo not found"
        return 1
    fi
    if [ ! -d "/usr/lib/rustlib/$TARGET" ]; then
        pending "bare-metal Rust target '$TARGET' is not installed"
        detail "$INSTALL_HINT"
        return 1
    fi
    return 0
}

do_build() {
    heading "Build — profile '$PROFILE', target '$TARGET'"
    require_toolchain || return 0

    if cargo build --release \
            --manifest-path kernel/Cargo.toml \
            --target "$TARGET" 2>&1 | sed 's/^/           /'; then
        local bin; bin="$(kernel_binary)"
        if [ -f "$bin" ]; then
            pass "kernel built: $(basename "$bin")"
        else
            fail "cargo reported success but $bin does not exist"
        fi
    else
        fail "kernel build failed"
    fi
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
    require_toolchain || return 0

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

    local bin; bin="$(kernel_binary)"
    if [ ! -f "$bin" ]; then
        pending "kernel not built — run ci/build.sh first"
        return 0
    fi

    local budget
    budget=$(toml_get "$(profile_file)" "d['budget']['kernel_image']['max_bytes']") || {
        fail "profile '$PROFILE' declares no kernel_image budget"; return 0; }

    # The loadable image, not the ELF: debug info and symbol tables are not
    # shipped to the device, so measuring them would flatter the number.
    local raw="$REPO_ROOT/ci/.out/kernel-$PROFILE.bin"
    mkdir -p "$(dirname "$raw")"
    if ! objcopy -O binary "$bin" "$raw" 2>/dev/null; then
        fail "objcopy failed — cannot measure the loadable image"
        return 0
    fi

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
        --help|-h)     sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)             die "unknown option '$1' (try --help)" ;;
    esac
    summary "build:"
}

main "$@"
