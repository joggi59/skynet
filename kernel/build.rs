// SPDX-License-Identifier: GPL-3.0-or-later
//
// The second and last place in the kernel that names an architecture.
//
// Why a build script rather than kernel/.cargo/config.toml: cargo discovers
// .cargo/config.toml by walking up from the CURRENT DIRECTORY, not from the
// manifest. ci/build.sh runs
//
//     cd "$REPO_ROOT" && cargo build --manifest-path kernel/Cargo.toml ...
//
// so kernel/.cargo/config.toml is not read. Verified empirically: a linker key
// placed there was honoured when cargo ran inside kernel/ and silently ignored
// when it ran from the parent with --manifest-path. Putting the linker script
// there would produce a kernel that links correctly for a developer and
// differently, or not at all, in CI — from identical sources.
//
// CARGO_MANIFEST_DIR gives an absolute path regardless of where cargo was
// invoked.

use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();

    let script = match arch.as_str() {
        "aarch64" => manifest.join("src/arch/aarch64/link.ld"),
        other => panic!("no linker script for target architecture `{other}`"),
    };

    // The cargo:: double-colon form is deliberate: unknown keys are a hard
    // error, so a typo fails the build instead of becoming inert metadata.
    //
    // `-bins` and not the bare `rustc-link-arg`: the bare form applies to every
    // link this package drives, including the HOST link of `cargo test` for the
    // library target, which then fails with the bare-metal linker script named
    // in the error. All three args below are bare-metal image concerns and none
    // of them means anything to a host test binary.
    println!("cargo::rustc-link-arg-bins=-T{}", script.display());

    // --nmagic is not optional. LLD's default max-page-size for AArch64 is
    // 64 KiB and it aligns PT_LOAD segments to it; without this flag .rodata
    // and .data land on separate 64 KiB boundaries and `objcopy -O binary`
    // emits the gaps, so a kernel of a few kilobytes measures over 128 KiB
    // against nano's 192 KiB budget. The largest budget risk in M0, and
    // entirely a link-flag question.
    println!("cargo::rustc-link-arg-bins=--nmagic");
    println!("cargo::rustc-link-arg-bins=--gc-sections");

    println!("cargo::rerun-if-changed={}", script.display());
    println!("cargo::rerun-if-changed=build.rs");
}
