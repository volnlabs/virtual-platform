# voln-vp

Boot and test prebuilt axiomOS images using QEMU or Renode. Adapters never
build axiomOS or write into its source tree. Run these commands from this
checkout; the CLI discovers the existing `boards/` and `backends/` directories.

## Quick start

Install Rust, Python 3.9+, QEMU, Renode, Bash, and GNU coreutils through your usual
package manager. `doctor` checks backend tools; it does not boot a guest.

```sh
cargo run -- doctor

# QEMU virt: the AArch64 ELF must be built for virt,cloud-profile,
# with a matching ext2 rootfs containing /bin/init.
AXIOMOS_KERNEL=/path/to/virt/kernel \
AXIOMOS_DISK_IMAGE=/path/to/disk.img \
cargo run -- test --board virt

# Renode Pi 5: embedded-rpi5 ELF with a populated embedded rootfs.
AXIOMOS_KERNEL=/path/to/pi5/kernel \
cargo run -- test --board virt-pi5
```

No kernel path is guessed from an AxiomOS checkout. Supply artifacts from a
known build; do not assume a shared `target/.../kernel` still has the intended
profile. Input hashes identify the files used, not their source commit or build
features. The newer v0.5 runtime worktree is not qualified by these boot checks.

## Identified prebuilt bundles

Prefer a manifest emitted by the AxiomOS build producer:

```sh
cargo run -- test --board virt --artifact-manifest /path/to/bundle/build.json
cargo run -- test --board virt-pi5 --artifact-manifest /path/to/pi5/build.json
```

Direct adapters accept `VOLN_VP_ARTIFACT_MANIFEST`. Unset manual artifact
variables when using a manifest; conflicting selections are rejected before
launch. Initial manifest profiles support AArch64 `virt` and `virt-pi5` only.
See the [artifact contract](docs/contracts/artifacts-v1.md) for exact fields,
feature sets and embedded-rootfs requirements. A dry-run prints the selection
without validating artifacts or launching an adapter.

Both manifest and manual inputs are copied into a fresh evidence directory;
manifest copies are revalidated before launch. Every run writes an atomic
[result](docs/contracts/results-v1.md), including failures and unsupported
profiles. Manual boots remain available but are unqualified. Manifest identity
alone also makes **no qualification claim**: producer provenance and a pinned,
validated execution profile still require real guest qualification.

## Inputs and controls

| Board / architecture | Required environment variables |
|---|---|
| `virt`, AArch64 (default) | `AXIOMOS_KERNEL`, `AXIOMOS_DISK_IMAGE` |
| `virt`, x86_64 | `AXIOMOS_ISO`, `AXIOMOS_DISK_IMAGE`, `AXIOMOS_OVMF_CODE`, `AXIOMOS_OVMF_VARS` |
| `virt`, RISC-V | `AXIOMOS_KERNEL` pointing to the RISC-V demo ELF |
| `virt-pi5`, AArch64 | `AXIOMOS_KERNEL`; optional `VOLN_VP_DTB` (bundled DTB by default) |

Select QEMU architecture with `VOLN_VP_ARCH=aarch64|x86_64|riscv64`. For example:

```sh
VOLN_VP_ARCH=x86_64 \
AXIOMOS_ISO=/path/to/axiomos.iso AXIOMOS_DISK_IMAGE=/path/to/disk.img \
AXIOMOS_OVMF_CODE=/path/to/code.fd AXIOMOS_OVMF_VARS=/path/to/vars.fd \
cargo run -- test --board virt

VOLN_VP_ARCH=riscv64 AXIOMOS_KERNEL=/path/to/riscv-kernel-demo \
cargo run -- test --board virt
```

- `VOLN_VP_TIMEOUT`: positive wall-clock duration, default `90s`; suffixes
  `s`, `m`, `h`, `d` are accepted. Expiration fails with status 124.
- `VOLN_VP_ARTIFACT_DIR`: parent directory for a **new** run directory on every
  invocation; defaults to `/tmp`. Old captures cannot satisfy a new boot check.
- `VOLN_VP_VIRTUAL_TIME`: Renode virtual seconds, default `0.1`.
- `run` is a bounded diagnostic boot run. QEMU mirrors UART live, accepts stdin,
  and stops after its marker; Renode finishes its configured virtual interval.
  `VOLN_VP_BOOT_MARKER` changes the diagnostic marker only for `run`.
- `test` always requires the userspace banner `=== axiomos eBPF init ===` for
  x86_64/AArch64. RISC-V requires its demo and OpenSBI messages: this proves
  demo boot, not userspace. QEMU observes another 0.1 seconds after the markers
  before stopping the live guest; this is a boot smoke check, not a soak test.
- Emulator failure, observed kernel panic/boot fatal, premature QEMU exit, or
  missing markers fails the test. Renode Monitor errors also fail even when
  Renode exits zero. Emulator nonzero exits propagate through the CLI.

QEMU uses TCG, headless serial, and no debug or monitor listener by default.
Its supplied disk and writable firmware images use disposable snapshots.
AArch64 semihosting defaults to off. Diagnostic runs of trusted artifacts can
explicitly set `VOLN_VP_SEMIHOSTING=on`; semihosting permits host filesystem
access and requires an isolated execution environment. Manifest tests reject it.

Arguments after `--` go directly to the emulator for manual boots or diagnostic
`run`; manifest `test` rejects them. For example
`cargo run -- run --board virt -- -smp 2`; old xtask runner options such as
`--headless` no longer apply. `AXIOMOS_ROOT` is no longer used.

Paths with spaces work. QEMU evidence-directory paths containing commas are rejected
because commas delimit its drive options. Renode's artifact-directory path supports
letters, digits, spaces, and `_./-`; input images are staged as private copies.
Renode path syntax is described in the [Monitor documentation](https://renode.readthedocs.io/en/latest/basic/monitor-syntax.html).

Each invocation prints its artifact directory and retains staged inputs plus
`inputs.json` and `result.json`; manifest runs also retain `manifest.json`. QEMU retains `uart.log`,
`qemu.log`, `version.log`, and `metadata.json` (inputs/hashes, version, command, working directory,
timeout). Renode retains `uart.log`, `renode.log`, `inputs.sha256`, `version.log`,
`command.txt`, and its generated script. Failures print the captured log tails.

## Verification and guest readiness

```sh
cargo test --workspace --offline
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s backends/tests -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s backends/renode/tests -v
```

The `Adapter and CLI checks` workflow runs on pull requests and pushes to
`main`. It runs these same Rust/Python suites with locked Cargo dependencies
and retains adapter test evidence on failure. Set `VOLN_VP_TEST_ARTIFACT_DIR`
locally to retain stand-in test directories as well. Hosted CI status must be
checked after a push; adding a workflow is not evidence that it passed.

Adapter tests use stand-in emulators and do not establish guest compatibility.
The [current boot evidence](docs/probes/2026-09-28-prebuilt-boot.md) records the
available images' failures separately: Pi 5 allocation panic and x86_64 invalid
root filesystem. Compatible QEMU AArch64 and RISC-V images still need live
validation. No target is declared boot-ready from mocked tests.

See the [implementation checklist](TODO_NOW.md),
[original risk gate](docs/probes/2026-07-30-armv8a-risk-gate.md), and
[design](docs/superpowers/specs/2026-07-14-voln-vp-design.md).
