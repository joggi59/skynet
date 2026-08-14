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
# What is booted, and RFC-0001 O-2 — CLOSED.
#
# O-2 asked which of three things to do about a kernel that cannot reach a
# device tree: change the artefact, read the blob from an observed placement, or
# correct the contract to say there is none. It was answered the third way and
# that was the wrong variable to settle — the contract was made true about an
# artefact that could itself change. RFC-0003's amendment changes the artefact.
#
# `-kernel` is given the flat Linux-format Image (kernel_image), not the ELF.
# QEMU treats an ELF as non-Linux, never writes the bootloader stub, and places
# no device tree anywhere in RAM; given an Image it writes the stub, places the
# blob and enters with `x0` holding its address. `--gdb` still hands the ELF to
# gdb, which is where the symbols are. Both halves are measured in RFC-0003
# section 1a, and `--contract` below states the result.
#
# O-2 is closed by that change. It needs no further decision and should not be
# cited again as open.
#
# Exit 0 on success, 1 on failure, 2 on usage or environment error, 3 if
# nothing was measured at all (every check PENDING or SKIP). See ci/lib.sh.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || die "cannot enter repo root"

PROFILE="$(active_profile)"
VERBOSE=0
QEMU_RAM='128M'

print_contract() {
    heading "Boot contract"
    info "artefact  flat Linux-format Image (objcopy -O binary of the release ELF)"
    info "marker    $BOOT_MARKER          must be printed"
    info "panic     $PANIC_MARKER            must NOT be printed"
    info "fault     $FAULT_MARKER            must NOT be printed"
    info "re-fault  $REFAULT_MARKER          must NOT be printed"
    info "machine   qemu-system-aarch64 -M $QEMU_MACHINE -cpu $QEMU_CPU -m $QEMU_RAM"
    info "          -kernel ci/.out/kernel-<profile>.bin   (the Image, never the ELF)"
    info "shutdown  PSCI SYSTEM_OFF (hvc #0, x0 = 0x84000008) -> QEMU exits 0"
    info "timeout   ${BOOT_TIMEOUT_SECONDS}s"
    echo
    info "QEMU virt specifics the kernel may rely on:"
    detail "RAM base            0x40000000  (link at 0x40080000 = RAM base + text_offset)"
    detail "PL011 UART0         0x09000000  (UARTDR at offset 0; usable with no init under QEMU)"
    detail "entry state         x0 = physical address of a device tree blob"
    detail "                    x1 = x2 = x3 = 0, sp = 0, EL1 (virtualization=off)"
    detail "                    the blob's first big-endian word is 0xd00dfeed, totalsize 0x100000"
    detail "PSCI conduit        HVC"
    echo
    info "x0 IS NOT A CONSTANT. No kernel may hardcode it:"
    detail "    x0 = 0x40000000 + round_up_2MiB(min(ram_size / 2, 128 MiB))"
    detail "measured on this machine, one binary, -M virt -cpu cortex-a72, halted at"
    detail "*0x40080000 before the first instruction:"
    detail "      -m 4M -> 0x40200000     -m 100M -> 0x43200000"
    detail "      -m 6M -> 0x40400000     -m 128M -> 0x44000000"
    detail "      -m 8M -> 0x40400000     -m 200M -> 0x46400000"
    detail "     -m 16M -> 0x40800000     -m 512M -> 0x48000000   (capped at +128 MiB)"
    detail "     -m 32M -> 0x41000000       -m 1G -> 0x48000000   (capped)"
    detail "     -m 64M -> 0x42000000       -m 3G -> 0x48000000   (capped)"
    detail "x1-x3 were zero at every one of those sizes, and the word at x0 was d0 0d fe ed."
    detail "4 MiB is the smallest size measured working. At -m 2M QEMU refuses the machine"
    detail "outright — 'Not enough space for DTB after kernel/initrd', exit 1, before any"
    detail "instruction runs. Sizes between 2 and 4 MiB were not measured."
    echo
    info "x0 = 0 means the kernel was booted as an ELF, which this script no longer does."
    detail "It is a legible configuration failure, not a mode and not a licence to guess"
    detail "an address. RFC-0001 O-2 is closed by changing the artefact; see the header"
    detail "of this file. RFC-0003 sections 1, 1a and 8."
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

    # The flat image, not the ELF. See the header: this is what makes `x0` a
    # device tree pointer rather than zero.
    local bin; bin="$(kernel_image)"
    if [ ! -f "$bin" ]; then
        pending "flat image not built — run ci/build.sh first"
        detail "ci/build.sh derives ${bin#$REPO_ROOT/} from the ELF in the build step"
        return 0
    fi
    # Booting an image older than the ELF beside it is booting a previous build
    # and reporting on this one. The output of the two is indistinguishable,
    # which is the entire reason this is checked rather than assumed.
    if kernel_image_stale; then
        pending "flat image is older than the ELF — run ci/build.sh"
        detail "booting it would report on a previous build"
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

    # 1d. no fault taken while the kernel was ALREADY failing. The vector table
    # stops the machine when that happens, deliberately — a `wfi` loop there
    # would be a thirty-second timeout on every occurrence — and stopping means
    # PSCI, which means exit 0 and a console that looks like a clean boot except
    # for this marker.
    #
    # Its own top-level block, and that is the whole point. The first version of
    # this check was nested inside the FAULT_MARKER branch above, where it could
    # only ever run once the other check had already failed: a re-fault with no
    # preceding fault report — which is the interesting case, because it means
    # the first report never got far enough to print — would have been passed
    # over in silence. Same defect as the two above it, caught before it shipped
    # rather than after.
    if grep -qF "$REFAULT_MARKER" "$out"; then
        fail "kernel faulted inside its own failure path — '$REFAULT_MARKER' found"
        detail "the first fault's report did not complete; the vector table stopped the machine"
    else
        pass "no fault inside the failure path"
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

    # The two artefacts, deliberately not the same one.
    #
    # QEMU is loaded from the flat image, so the machine under the debugger is
    # the machine the boot test runs — with the bootloader stub written and a
    # device tree placed. gdb is given the ELF, because that is where the
    # symbols are; the flat image has none. Measured: `break *0x40080000` hits,
    # reports `_start in section .text.boot`, and `$x0` reads the blob address.
    local elf img; elf="$(kernel_binary)"; img="$(kernel_image)"
    [ -f "$img" ] || die "flat image not built — run ci/build.sh first"
    [ -f "$elf" ] || die "kernel ELF not built — run ci/build.sh first"
    kernel_image_stale && die "flat image is older than the ELF — run ci/build.sh"

    info "stub on :1234, CPU halted. In another terminal:"
    detail "gdb $elf -ex 'target remote :1234' -ex 'break *0x40080000' -ex continue"
    detail "then: info registers x0 x1 x2 x3    and    x/1xw \$x0   (expect d0 0d fe ed)"
    echo
    # -nic none and $QEMU_BIN, for the same reasons run_boot gives and this
    # branch did not have. Measured while verifying the artefact split: without
    # -nic none QEMU exits immediately with `failed to find romfile
    # "efi-virtio.rom"` and never opens the stub, so --gdb was unusable on any
    # machine whose QEMU ships without that ROM — and the hardcoded
    # `qemu-system-aarch64` ignored SKYNET_QEMU, which is the whole point of
    # having the override. The debugging path must run the same machine the boot
    # test runs, or what it shows is not what was measured.
    "$QEMU_BIN" \
        -M "$QEMU_MACHINE" -cpu "$QEMU_CPU" -m "$QEMU_RAM" \
        -display none -serial stdio -no-reboot -nic none \
        -kernel "$img" -S -s
}

main() {
    case "${1:-}" in
        "")                 run_boot; summary "boot:" ;;
        --verbose|-v)       VERBOSE=1; run_boot; summary "boot:" ;;
        --gdb|-g)           run_gdb ;;
        --contract|-c)      print_contract ;;
        --help|-h)          sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
        *)                  die "unknown option '$1' (try --help)" ;;
    esac
}

main "$@"
