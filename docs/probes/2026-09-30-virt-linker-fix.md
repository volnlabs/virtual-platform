# Identified virt build and three failed boot attempts

The linker blocker is fixed in [AxiomOS PR #196](https://github.com/pro-utkarshM/axiomOS/pull/196),
commit `a6f48d167437f94807899c53e2f2b1c92abd8b24`. A clean isolated rebuild
produced the matching release kernel/rootfs and a validated manifest. The
reference AxiomOS checkout remained unchanged. `__kernel_end` is defined at
`0x40130000`; both producer build commands exited 0.

AxiomOS hosted [run 36651265304](https://github.com/pro-utkarshM/axiomOS/actions/runs/36651265304)
could not start its jobs: GitHub reports an account payment/spending-limit
block. No hosted source validation is claimed; the build evidence below is local.

**Boot qualification failed:** three fresh launches each timed out after 30
host seconds, returned 124, and retained empty UART captures. There was no
userspace milestone. All three terminal results have empty qualification claims.

The [bundle archive](2026-09-30-virt-linker-fix-evidence/bundle.tar.gz) retains
the exact kernel, rootfs, public CI trust fixture, manifest, build record/logs,
feature tree and execution profile. Its SHA-256 is
`8bb65e5ecbc6aa086d2aafb34c4a08c14d77560beea34ccc49f92d06b745d21b`.
The [evidence index](2026-09-30-virt-linker-fix-evidence/evidence-sha256.json)
hashes the archive and checked-in run/debug records. Original absolute paths
in those records describe the attempt; extract the archive to reproduce inputs.

## Execution and reproduction

QEMU 11.1.1, executable SHA-256
`9913597c7e6ff3443c5c788bc2ae1281bd98223401b99547878c403c9f458bc3`;
TCG, `virt-11.1,gic-version=2,virtualization=off,secure=off`, Cortex-A57,
one core, 1 GiB RAM, direct ELF boot without firmware, QEMU-generated DTB,
semihosting off and networking disabled. Each launch used private artifact
copies and a disposable rootfs snapshot. The adapter completed cleanup; no
QEMU process from these attempts remained.

These are diagnostic `run` invocations because the pinned machine options use
raw overrides. `execution.argv` and `execution.diagnostic_overrides` retain the
actual command; the existing `execution.machine` field still describes the
base `virt` argument. This is a recorded attempted profile, not an accepted
qualification profile.

After extracting the bundle to an absolute path, repeat three times with a
fresh evidence directory allocated automatically on each invocation:

```sh
VOLN_VP_ARTIFACT_MANIFEST=/absolute/bundle/build.json \
VOLN_VP_TIMEOUT=30s VOLN_VP_SEMIHOSTING=off \
python3 backends/qemu/runner.py aarch64 run -- \
  -machine virt-11.1,gic-version=2,virtualization=off,secure=off \
  -nic none -no-user-config
```

## Immediate startup blocker

A separate paused-entry GDB run reached `_start_asm` at `0x40080000`, with
`x0=0` and EL1. Its first four instructions load the Pi UART address and byte;
the fifth is `str w10, [x9]` with `x9=0x107d001000`. After that instruction,
the PC is `0x200`, before the boot code installs its vector table or enters
Rust. The [GDB transcript](2026-09-30-virt-linker-fix-evidence/entry-debug/gdb.txt)
and exact debugger/QEMU commands are retained. This localizes the immediate
failure to the Pi-specific early UART store on the virt machine.

The entry value `x0=0` also means the assembly's later assumption that x0
contains a DTB pointer needs separate treatment for this ELF boot path.
Neither startup behavior is changed by the one-symbol linker fix. The next
AxiomOS change must handle the virt boot-entry UART and DTB contract, then
repeat this gate. Pi drivers and managed-runtime behavior remain unqualified.
