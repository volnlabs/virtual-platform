# Prebuilt-image boot adapter verification

Date: 2026-09-28. Reference source: `/home/utkarsh/Work/axiomOS`,
`main` at `b8953b59`. The reference checkout was inspected read-only; no kernel
builds or patches were performed. Existing binaries are older, unqualified
inputs and are not established as builds of that commit.

## Results

| Check | Result |
|---|---|
| Rust CLI tests | 19 passed |
| Adapter regression tests | 12 passed; stand-in emulators, not guest qualification |
| Existing Renode peripheral/platform tests | 5 passed |
| `doctor`, shell syntax, whitespace checks | Passed |
| Renode Pi 5 live boot | Fails with guest rootfs allocation panic; exit 1 |
| QEMU x86_64 live boot | Fails with `BOOT_FATAL code=root-filesystem-invalid`; exit 1 |
| QEMU AArch64 live boot | Not validated: no identified compatible `virt` image |
| QEMU RISC-V live boot | Not validated: expected prebuilt demo ELF absent |

Adapter tests cover actual adapter dispatch to stand-in executables, all three
QEMU command configurations, snapshots, preserved input files, fresh captures,
spaces, fragmented UART markers, fixed test markers, premature exit, emulator
status propagation, panic/boot-fatal detection, Monitor errors, timeout, and
signal cleanup of emulator/helper processes, surviving helpers after launcher
exit, and failed/interrupted version queries. A fake `cargo` executable fails
the suite if any adapter attempts to build a guest.

Before the change, QEMU `test` exited zero even with nonexistent kernel/source
paths and an unsupported architecture. The regression suite failed against
that implementation; it now passes. No mocked success is a guest boot PASS.

## Renode Pi 5

Renode `1.16.1.16973`, Cortex-A78, one core, EL1 entry, bundled 8 GiB DTB.
The canonical model still uses real MMU translation, with no high-address alias.

```sh
AXIOMOS_KERNEL=/home/utkarsh/Work/axiomOS/target/aarch64-unknown-none/release/kernel \
VOLN_VP_ARTIFACT_DIR='/tmp/voln-vp live checks' VOLN_VP_TIMEOUT=15s \
backends/renode/adapters/test.sh
```

Observed UART:

```text
PI5_BENCH_FAIL stage=rp1_irq_route error=PcieLinkDown(0)
V04_PANIC kind=panic
memory allocation of 10485760 bytes failed
```

Input hashes:

```text
kernel  aa529d547c8e868c20cbf469bae02bc53b259e417b5cf943d0bf3d12cccc3130
DTB     8a811a4d1ecb124eab6a8ce46ebfe1113874a6ce034a881bdc6f2fe316582324
```

The source tree's old `rpi5-artifacts.sha256` names a different kernel hash
(`136262dd...`), demonstrating why the adapter cannot infer image provenance
from its filename. The current file contains a 10 MiB embedded image; the July
probe used a different 20 MiB image.

Retained run: `/tmp/voln-vp live checks/voln-vp-renode.rhxYA0`.
The real run also verifies Renode's two levels of path parsing: the positional
script needs escaped spaces, while paths inside the script use quoted strings.
The original unescaped script path failed to tokenize.

## QEMU x86_64

QEMU `11.1.1`, TCG, one CPU, 4 GiB RAM. ISO and disk were selected together
from the explicit build output `target/release/build/axiomos-ca9300463660b388/output`,
not from a newest-file search.

```sh
VOLN_VP_ARCH=x86_64 \
AXIOMOS_ISO=/home/utkarsh/Work/axiomOS/target/release/build/axiomos-ca9300463660b388/out/axiomos.iso \
AXIOMOS_DISK_IMAGE=/home/utkarsh/Work/axiomOS/target/release/build/axiomos-ca9300463660b388/out/disk.img \
AXIOMOS_OVMF_CODE=/home/utkarsh/Work/axiomOS/target/ovmf/x64/code.fd \
AXIOMOS_OVMF_VARS=/home/utkarsh/Work/axiomOS/target/ovmf/x64/vars.fd \
VOLN_VP_ARTIFACT_DIR='/tmp/voln-vp live checks' VOLN_VP_TIMEOUT=35s \
cargo run --offline --quiet -- test --board virt
```

The guest enters its kernel and prints `AXIOM KERNEL METRICS`, then reports
`BOOT_FATAL code=root-filesystem-invalid`. It never emits the required
userspace marker. QEMU also logs `Guest says index 65535 is available`.
This evidence does not diagnose or fix the underlying guest/rootfs problem.

```text
ISO        8807c6a201e5c700e1585983b1f372e9941a336ef9ae6dc135ee82601d0a9168
disk       b05ce666523cf4a3f830e7ddcc1c56a40c6b306c87593c9572002de9b19506d4
OVMF code  5133670d3b2f587ad91cf4ccc3b93a0d3dd14ef177d6a23adc81371fd6c1e7b5
OVMF vars  5d2ac383371b408398accee7ec27c8c09ea5b74a0de0ceea6513388b15be5d1e
```

Hashes were checked again after the live run and were unchanged. Disk and
firmware writes go to temporary QEMU snapshots. Run metadata records the exact
resolved paths, command, timeout, and emulator version.

The full diagnostic was first captured at
`/tmp/voln-vp live checks/voln-vp-qemu-x86_64-j3g2ge8y`. The final live check at
`/tmp/voln-vp live checks/voln-vp-qemu-x86_64-c2v6f6kg` exits 1 on boot-fatal
detection, retaining the full reason after a 0.1-second diagnostic drain.

## Next guest validation

Provide matching prebuilt images with known source/features for each target,
then rerun the documented commands. Pi 5 PASS still requires
`=== axiomos eBPF init ===`; the RISC-V demo has a separate boot-only gate.
The adapters neither build a replacement kernel nor weaken these gates.
