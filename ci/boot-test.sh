#!/usr/bin/env bash
# Boot the kernel under QEMU and verify it comes up and shuts down cleanly.
#
#   ci/boot-test.sh            boot, expect the marker, expect a clean exit
#   ci/boot-test.sh --verbose  also print the full console output
#   ci/boot-test.sh --gdb      boot halted with a gdb stub on :1234
#   ci/boot-test.sh --contract print the boot contract and exit
#
# The contract, in four parts:
#
#   1. the kernel prints SKYNET_BOOT_OK on the PL011 console
#   2. it prints neither SKYNET_PANIC nor SKYNET_FAULT
#   3. it then shuts down through PSCI SYSTEM_OFF, so QEMU exits 0
#   4. it does all of that within the timeout
#
# Part 2 is what makes this automatable. A kernel that spins forever after
# printing cannot be distinguished from one that hung, so "it printed something"
# is not evidence that it works. Shutting down deliberately is.
#
# Exit 0 on success, 1 on failure, 2 on usage or environment error.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || die "cannot enter repo root"

PROFILE="$(active_profile)"
VERBOSE=0
QEMU_RAM='128M'

print_contract() {
    heading "Boot contract"
    info "marker    $BOOT_MARKER          must be printed"
    info "panic     $PANIC_MARKER            must NOT be printed"
    info "fault     $FAULT_MARKER            must NOT be printed"
    info "machine   qemu-system-aarch64 -M $QEMU_MACHINE -cpu $QEMU_CPU -m $QEMU_RAM"
    info "shutdown  PSCI SYSTEM_OFF (hvc #0, x0 = 0x84000008) -> QEMU exits 0"
    info "timeout   ${BOOT_TIMEOUT_SECONDS}s"
    echo
    info "QEMU virt specifics the kernel may rely on:"
    detail "RAM base            0x40000000  (link at 0x40080000)"
    detail "PL011 UART0         0x09000000  (UARTDR at offset 0; usable with no init under QEMU)"
    detail "entry state         ALL general-purpose registers ZERO, EL1 (virtualization=off)"
    detail "                    x0 is NOT a device tree pointer for an ELF image — QEMU treats"
    detail "                    ELF as non-Linux and never writes the bootloader stub. RFC-0001 O-2."
    detail "PSCI conduit        HVC"
}

run_boot() {
    heading "Boot test — profile '$PROFILE'"

    if ! kernel_exists; then
        pending "no kernel yet — M0 has not landed"
        detail "this is the expected state at G0"
        return 0
    fi
    if ! have_qemu; then
        pending "qemu-system-aarch64 is not installed"
        detail "$INSTALL_HINT"
        return 0
    fi

    local bin; bin="$(kernel_binary)"
    if [ ! -f "$bin" ]; then
        pending "kernel not built — run ci/build.sh first"
        return 0
    fi

    local out; out="$REPO_ROOT/ci/.out/boot-$PROFILE.log"
    mkdir -p "$(dirname "$out")"

    info "booting $(basename "$bin") ..."

    # -display none -serial stdio rather than -nographic: -nographic
    # multiplexes the QEMU monitor onto the same stream, which corrupts console
    # output and makes marker detection unreliable.
    # -nic none: the virt machine attaches a virtio-net device by default, which
    # needs an option ROM that is packaged separately from QEMU's core. M0 has
    # no network stack and the boot contract does not mention one, so the device
    # is pure noise in this test — and a missing ROM file would fail the boot
    # for a reason that has nothing to do with the kernel.
    local rc=0
    timeout --foreground "$BOOT_TIMEOUT_SECONDS" \
        "$QEMU_BIN" \
            -M "$QEMU_MACHINE" \
            -cpu "$QEMU_CPU" \
            -m "$QEMU_RAM" \
            -display none \
            -serial stdio \
            -no-reboot \
            -nic none \
            -kernel "$bin" \
        > "$out" 2>&1 || rc=$?

    [ "$VERBOSE" -eq 1 ] && { echo; sed 's/^/           | /' "$out"; echo; }

    # 1. the boot marker
    if grep -qF "$BOOT_MARKER" "$out"; then
        pass "marker '$BOOT_MARKER' printed on the console"
    else
        fail "marker '$BOOT_MARKER' not found on the console"
        if [ -s "$out" ]; then
            detail "console output was:"
            sed 's/^/             /' "$out" | head -20
        else
            detail "console produced no output at all"
        fi
    fi

    # 1b. no panic. A panicking kernel shuts down cleanly and would otherwise
    # be indistinguishable from success by exit code alone. See ci/lib.sh.
    if grep -qF "$PANIC_MARKER" "$out"; then
        fail "kernel panicked — '$PANIC_MARKER' found on the console"
        grep -F -A3 "$PANIC_MARKER" "$out" | sed 's/^/             /' | head -8
    else
        pass "no panic"
    fi

    # 1c. no hardware fault. Same hazard, discovered one contribution later: a
    # fault used to hang and be caught by the timeout, and now reports and
    # powers off cleanly, so every other check here would pass.
    if grep -qF "$FAULT_MARKER" "$out"; then
        fail "kernel took a fault — '$FAULT_MARKER' found on the console"
        grep -F -A5 "$FAULT_MARKER" "$out" | sed 's/^/             /' | head -10
    else
        pass "no fault"
    fi

    # 2. and 3. the shutdown
    case "$rc" in
        0)
            pass "clean shutdown via PSCI (QEMU exited 0)" ;;
        124)
            fail "timed out after ${BOOT_TIMEOUT_SECONDS}s — the kernel never shut down"
            detail "a kernel that spins after printing cannot be distinguished from one that hung"
            detail "issue PSCI SYSTEM_OFF: hvc #0 with x0 = 0x84000008" ;;
        *)
            fail "QEMU exited $rc"
            detail "expected 0 (PSCI SYSTEM_OFF)" ;;
    esac

    info "console log: ${out#$REPO_ROOT/}"
}

run_gdb() {
    heading "Boot halted with gdb stub"
    kernel_exists || die "no kernel yet"
    have_qemu     || die "qemu-system-aarch64 not installed — $INSTALL_HINT"
    local bin; bin="$(kernel_binary)"
    [ -f "$bin" ] || die "kernel not built — run ci/build.sh first"

    info "stub on :1234, CPU halted. In another terminal:"
    detail "gdb $bin -ex 'target remote :1234' -ex 'break kernel_main'"
    echo
    qemu-system-aarch64 \
        -M "$QEMU_MACHINE" -cpu "$QEMU_CPU" -m "$QEMU_RAM" \
        -display none -serial stdio -no-reboot \
        -kernel "$bin" -S -s
}

main() {
    case "${1:-}" in
        "")                 run_boot; summary "boot:" ;;
        --verbose|-v)       VERBOSE=1; run_boot; summary "boot:" ;;
        --gdb|-g)           run_gdb ;;
        --contract|-c)      print_contract ;;
        --help|-h)          sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
        *)                  die "unknown option '$1' (try --help)" ;;
    esac
}

main "$@"
