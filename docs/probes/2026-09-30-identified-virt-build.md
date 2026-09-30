# Identified AArch64 virt build attempt

The first identified generic-boot gate is **blocked at guest linking**. No guest
was launched, no execution profile was qualified, and no boot/runtime pass is
claimed. This is a new source-attributable build failure, separate from the
September 28 binaries' boot failures.

## Producer and inputs

An isolated clean clone of AxiomOS commit
`b8953b593d5f3be2a15960aef24ccef0fc507ca3` was built with its pinned
`nightly-2026-07-02` toolchain. The existing AxiomOS reference checkout was
read-only and remained clean. Both commands used `--locked --offline`, a fresh
external target directory, two build jobs, and the public RFC 8032 trust fixture
already used by AxiomOS CI. The fixture is not a production trust root.

```sh
cargo build --locked --offline --release --target aarch64-unknown-none \
  --no-default-features -p axiomos --features aarch64_deps
cargo build --locked --offline --release --target aarch64-unknown-none \
  --no-default-features -p kernel --features virt,cloud-profile
```

The [build record](2026-09-30-virt-build-evidence/build-record.json) retains exact
commands, toolchain, explicit build environment, start/end timestamps, exit
codes, trust-key hash, rootfs hash, and evidence digests. The logs and resolved
kernel feature tree are checked in alongside it. Absolute `/tmp` paths identify
the original attempt; those paths and the rootfs bytes are not durable fixtures.

The existing [CI artifact producer](https://github.com/pro-utkarshM/axiomOS/actions/runs/34916821645)
at the same commit also builds AArch64, but its upload selects only the x86 ISO.
Downloaded artifact `10376773098`, `axiomos-boot-images`, contained
`axiomos-2bcc31378c9970f2/out/axiomos.iso`; it cannot supply the virt pair.

## Observed result

| Step | Result |
|---|---|
| AArch64 root package / rootfs | Exit 0; 20 MiB ext2 image |
| Standalone virt kernel | Exit 101; linker reports undefined `__kernel_end` |
| Manifest packaging | Not performed: no matching virt kernel exists |
| Three fresh QEMU launches | Not performed: prerequisite failed |

Rootfs SHA-256:
`b91d956007415e50962605c6104a9228abf45a942e5fdd237874ca9bf84dafd6`.
The dependency kernel reported by the root package is **not** the standalone
virt kernel and was not substituted for it.

`kernel/src/lib.rs:220–229` references `__kernel_end` for boot metrics.
`kernel/linker-aarch64.ld:54` defines the symbol after `.bss`, but
`kernel/linker-virt.ld` does not. The failed link explicitly selects the latter.
This establishes the missing-symbol cause; it says nothing about subsequent
guest boot behavior.

The resolved virt kernel features are `aarch64_arch`, `cloud-profile`, `virt`.
The consumer contract now includes implied kernel features rather than only
command-line aliases. Rootfs features and the dependency feature graph remain
part of the producer build record.

## Next gate

Fix and validate the linker contract in separately owned AxiomOS work, then
publish a clean identified kernel/rootfs bundle with its build record. Only
then pin the QEMU profile and run the three fresh userspace-boot checks. Pi
rootfs, RP1 behavior, managed runtime, and replay remain separate later gates.
